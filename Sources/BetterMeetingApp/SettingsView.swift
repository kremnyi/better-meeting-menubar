import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case general, recording, transcription, models, calendars
}

/// The Settings window. The menu's Options popover keeps the per-meeting choices;
/// quality, engine, models, calendars, and updates live here.
struct SettingsView: View {
    static let paneWidth: CGFloat = 460

    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettingsView()
                .settingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            RecordingSettingsView()
                .settingsPane()
                .tabItem { Label("Recording", systemImage: "record.circle") }
                .tag(SettingsTab.recording)
            TranscriptionSettingsView()
                .settingsPane()
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(SettingsTab.transcription)
            ModelStorageView()
                .settingsPane()
                .tabItem { Label("Models", systemImage: "externaldrive") }
                .tag(SettingsTab.models)
            CalendarOptionsView(calendar: model.calendar)
                .settingsPane()
                .tabItem { Label("Calendars", systemImage: "calendar") }
                .tag(SettingsTab.calendars)
        }
        .background(WindowReader { window in
            model.settingsWindow = window
            // A menu bar app is never frontmost, so Settings would otherwise open behind the current app.
            window.makeKeyAndOrderFront(nil)
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true))
    }
}

extension View {
    /// Pads a Settings tab to the window's width; its height follows the content.
    func settingsPane() -> some View {
        padding(20)
            .frame(width: SettingsView.paneWidth, alignment: .topLeading)
    }
}

extension AppModel {
    /// Opens Settings on `tab`, activating first so the window comes to the front.
    func showSettings(_ tab: SettingsTab, using openSettings: OpenSettingsAction) {
        settingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State var launchAtLoginStatus = SMAppService.mainApp.status
    @State var launchAtLoginError: String?
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLoginStatus == .enabled },
                set: setLaunchAtLogin
            ))
            if launchAtLoginStatus == .requiresApproval || launchAtLoginError != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if launchAtLoginStatus == .requiresApproval {
                        Text("Allow Better Meeting to open at login in System Settings.")
                    } else if launchAtLoginStatus == .notFound {
                        Text("Open Better Meeting from Applications and try again.")
                    } else {
                        Text("Couldn’t change launch at login. Try again or check Login Items.")
                    }
                    if launchAtLoginStatus != .notFound {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(.link)
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
                .help(launchAtLoginError ?? "")
            }
            Divider()
            Text("Updates").font(.headline)
            Toggle("Download updates automatically", isOn: $model.automaticUpdateChecks)
                .help("Checks GitHub on launch and periodically. Downloads in the background; installs when you restart or quit.")
            Toggle("Include beta releases", isOn: $model.betaUpdates)
                .help("Offers beta builds ahead of the next release. Stable releases arrive either way.")
            UpdateOptionsView(updates: model.updates, version: version)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginStatus = SMAppService.mainApp.status
            launchAtLoginError = nil
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        launchAtLoginError = nil
        do {
            if enabled && service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLoginStatus = service.status
    }
}

struct RecordingSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                CaptureDeviceRows()
                GridRow {
                    Text("Resolution")
                    Picker("Resolution", selection: $model.captureResolution) {
                        ForEach(CaptureResolution.allCases, id: \.self) { resolution in
                            Text(resolution.label).tag(resolution)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(model.captureSettingsLocked)
                    .help("Limits the video's longest edge without upscaling")
                }
                GridRow {
                    Text("Frame rate")
                    Picker("Frame rate", selection: $model.captureQuality) {
                        ForEach(CaptureQuality.allCases, id: \.self) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(model.captureSettingsLocked)
                    .help("Smoother motion uses more storage")
                }
                Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 2)
                FileSettingsRows()
            }
            SettingsLockNotice()
        }
    }
}

struct TranscriptionSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdvancedTranscriptionView(
                settings: $model.speechSettings, hints: $model.transcriptionHints,
                languages: $model.transcriptionLanguages, title: nil,
                modelSelectionDisabled: model.modelPreparationTask != nil
            )
            .disabled(model.transcriptionSettingsLocked)
            SettingsLockNotice()
        }
        .onChange(of: model.speechSettings.model) { model.speechModelChanged() }
        .onChange(of: model.speechSettings.engine) { model.speechModelChanged() }
    }
}
