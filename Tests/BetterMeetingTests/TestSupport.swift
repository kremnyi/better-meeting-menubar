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
