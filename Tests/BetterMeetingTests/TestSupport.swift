import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import BetterMeetingApp

/// A menu bar or options view with the app environment applied, sized and laid out for assertions.
@MainActor
func hostingView(
    _ content: some View, model: AppModel, updates: AppUpdater? = nil, scheme: ColorScheme = .light
) -> NSHostingView<some View> {
    let view = NSHostingView(rootView: content
        .environmentObject(model)
        .environmentObject(updates ?? model.updates)
        .environment(\.colorScheme, scheme)
        .background(Color(nsColor: .windowBackgroundColor)))
    view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    return view
}

/// Writes a panel to `BETTER_MEETING_PANELS_PREVIEW_PATH/<name>.png`; without that variable the view is never built.
@MainActor
func writePanelPreview(_ view: @autoclosure () -> NSView, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] else { return }
    try writePreview(view(), to: URL(fileURLWithPath: path).appendingPathComponent("\(name).png"))
}

/// Resizes a view to its current content and writes it as a PNG.
@MainActor
func writePreview(_ view: NSView, to output: URL) throws {
    if view.appearance == nil { view.appearance = NSAppearance(named: .aqua) }
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try writePNG(bitmap, to: output)
}

func writePNG(_ bitmap: NSBitmapImageRep, to output: URL) throws {
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
}

/// A unique temporary directory for one test, created up front so writers can nest into it.
func makeTempRoot(_ label: String = "BetterMeeting") -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A temporary UserDefaults suite whose outputFolder points at a fresh temp root.
func makeTempDefaults(_ label: String) throws -> (defaults: UserDefaults, suite: String, root: URL) {
    let suite = "\(label).\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let root = makeTempRoot(label)
    defaults.set(root, forKey: "outputFolder")
    return (defaults, suite, root)
}

func removeTempRoot(_ root: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    try? FileManager.default.removeItem(at: root)
}

func removeTempDefaults(_ defaults: UserDefaults, suite: String, root: URL) {
    defaults.removePersistentDomain(forName: suite)
    removeTempRoot(root)
}
