import ServiceManagement
import SwiftUI

struct CaptureOptionsView: View {
    /// The login item status as last read. SwiftUI rebuilds this view on every menu redraw and each read
    /// is a round trip to the login items service, so it is read when the menu opens and after changes.
    private(set) static var knownLaunchAtLoginStatus = SMAppService.mainApp.status

    static func refreshLaunchAtLoginStatus() {
        knownLaunchAtLoginStatus = SMAppService.mainApp.status
    }

    /// The menu calls this on every open; the status read can block for seconds, so it lands after.
    /// Pass the toggle's binding where the caller also shows the value.
    static func refreshLaunchAtLoginStatusInBackground(updating state: Binding<SMAppService.Status>? = nil) {
        Task.detached(priority: .utility) {
            let status = SMAppService.mainApp.status
            await MainActor.run {
                knownLaunchAtLoginStatus = status
                state?.wrappedValue = status
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State var advancedPresented = false
    @State var meetingsPresented = false
    @State var appSettingsPresented = false
    @State var aboutPresented = false
    @State var launchAtLoginStatus = Self.knownLaunchAtLoginStatus
    @State var launchAtLoginError: String?
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if meetingsPresented {
                OptionsPageHeader(title: "Meetings") { meetingsPresented = false }
                MeetingOptionsView(calendar: model.calendar, detectsMeetings: $model.detectsMeetings)
            } else if advancedPresented {
                OptionsPageHeader(title: "Advanced transcription") { advancedPresented = false }
                AdvancedTranscriptionView(
                    settings: $model.speechSettings, hints: $model.transcriptionHints,
                    modelSelectionDisabled: model.modelPreparationTask != nil
                )
                .disabled(model.transcriptionSettingsLocked)
            } else if appSettingsPresented && aboutPresented {
                OptionsPageHeader(title: "About", backTo: "App & updates") { aboutPresented = false }
                AboutView(version: version)
            } else if appSettingsPresented {
                OptionsPageHeader(title: "App & updates") { appSettingsPresented = false }
                appSettings
            } else {
                basicOptions
                if let notice = model.settingsLockNotice {
                    Text(notice)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    OptionsNavigationRow(title: "Meetings", systemImage: "calendar.badge.clock",
                                         help: "Calendars, and when to suggest a recording") {
                        meetingsPresented = true
                    }
                    OptionsNavigationRow(title: "Advanced transcription", systemImage: "waveform",
                                         help: "Engine, model, vocabulary, decoding, and downloaded models") {
                        advancedPresented = true
                    }
                    OptionsNavigationRow(title: "App & updates", systemImage: "gearshape",
                                         help: "Launch at login, menu bar recording time, updates, and the installed version") {
                        appSettingsPresented = true
                    }
                }
                // Hover highlights extend past the content edge while titles stay aligned with the rows above.
                .padding(.horizontal, -6)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(16)
        // Fixed so long strings wrap instead of stretching the panel; layout tests pin this width.
        .frame(width: 360, alignment: .leading)
        .onChange(of: model.speechSettings.model) { model.speechModelChanged() }
        .onChange(of: model.speechSettings.engine) { model.speechModelChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Self.refreshLaunchAtLoginStatusInBackground(updating: $launchAtLoginStatus)
            launchAtLoginError = nil
        }
    }

    private var appSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General").font(.headline)
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
            Toggle("Show recording time in the menu bar", isOn: $model.menuBarRecordingTime)
                .help("Shows the elapsed time beside the menu bar icon while recording")
            Text("Updates").font(.headline)
            Toggle("Download updates automatically", isOn: $model.automaticUpdateChecks)
                .help("Checks GitHub on launch and periodically. Downloads in the background; installs when you restart or quit.")
            Toggle("Include beta releases", isOn: $model.betaUpdates)
                .help("Offers beta builds ahead of the next release. Stable releases arrive either way.")
            UpdateOptionsView(updates: model.updates, version: version)
            Divider()
            OptionsNavigationRow(title: "About Better Meeting", systemImage: "info.circle",
                                 help: "Version, author, links, and license") {
                aboutPresented = true
            }
            .padding(.horizontal, -6)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var videoQualityLabel: String {
        model.captureResolution.label + " · \(model.captureQuality.rawValue) fps"
    }

    private var basicOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Recording").font(.headline).gridCellColumns(2)
            }
            GridRow {
                Text("Display")
                Picker("Display", selection: $model.selectedDisplayID) {
                    Text("Main display").tag(UInt32(0))
                    ForEach(model.displays, id: \.id) { display in
                        Text(display.name).tag(display.id)
                    }
                    if model.selectedDisplayID != 0 && !model.displays.contains(where: { $0.id == model.selectedDisplayID }) {
                        Text("Unavailable display").tag(model.selectedDisplayID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(model.captureSettingsLocked)
                .help("The entire selected display is recorded")
                .accessibilityLabel("Display")
            }
            GridRow {
                Text("Microphone")
                Picker("Microphone", selection: $model.selectedMicrophoneID) {
                    Text("System default").tag("")
                    ForEach(model.microphones, id: \.id) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                    if !model.selectedMicrophoneID.isEmpty && !model.microphones.contains(where: { $0.id == model.selectedMicrophoneID }) {
                        Text("Unavailable microphone").tag(model.selectedMicrophoneID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(model.captureSettingsLocked)
                .help("Recorded along with system audio")
                .accessibilityLabel("Microphone")
            }
            GridRow {
                Text("Video")
                Menu(videoQualityLabel) {
                    Section("Resolution") {
                        Picker("Resolution", selection: $model.captureResolution) {
                            ForEach(CaptureResolution.allCases, id: \.self) { resolution in
                                Text(resolution.label).tag(resolution)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    Section("Frame rate") {
                        Picker("Frame rate", selection: $model.captureQuality) {
                            ForEach(CaptureQuality.allCases, id: \.self) { quality in
                                Text(quality.label).tag(quality)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity)
                .disabled(model.captureSettingsLocked)
                .accessibilityLabel("Video quality")
                .accessibilityValue(videoQualityLabel)
                .help("Resolution limits the video's longest edge without upscaling. Smoother motion uses more storage.")
            }
            Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 2)
            GridRow {
                Text("Transcription").font(.headline).gridCellColumns(2)
            }
            TranscriptionOptionsView(
                languages: $model.transcriptionLanguages, settings: $model.speechSettings,
                locked: model.transcriptionSettingsLocked
            )
            Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 2)
            GridRow {
                Text("Files").font(.headline).gridCellColumns(2)
            }
            GridRow {
                Text("Save to")
                destinationButton
            }
            GridRow {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Include screenshots and screen text", isOn: $model.exportAfterRecording)
                        .disabled(model.fileSettingsLocked)
                        .help("After saving each transcript, export a bundle with screenshots and screen text into an artifacts folder.")
                    if model.exportAfterRecording {
                        Text("Saves extra files beside the transcript.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 18)
                    }
                }
                .gridCellColumns(2)
            }
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
        Self.refreshLaunchAtLoginStatus()
        launchAtLoginStatus = Self.knownLaunchAtLoginStatus
    }

    private var destinationButton: some View {
        Button {
            model.chooseOutputFolder()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")

                Text(model.outputRoot.lastPathComponent)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(model.fileSettingsLocked)
        .help(model.outputRoot.path)
        .accessibilityLabel("Save recordings to \(model.outputRoot.path)")
        .accessibilityHint("Choose a different folder")
    }

}

struct TranscriptionOptionsView: View {
    @Binding var languages: [String]
    @Binding var settings: SpeechSettings
    var locked = false

    private var languageNames: String {
        languages.compactMap { TranscriptionLanguage(rawValue: $0)?.label }.joined(separator: ", ")
    }

    var body: some View {
        Group {
            GridRow {
                Text("Languages")
                Menu(settings.usesWhisperOptions ? languageNames : "Detected automatically") {
                    ForEach(TranscriptionLanguage.allCases, id: \.self) { language in
                        Toggle(language.label, isOn: Binding(
                            get: { languages.contains(language.rawValue) },
                            set: { selected in
                                if selected { languages.append(language.rawValue) }
                                else if languages.count > 1 { languages.removeAll { $0 == language.rawValue } }
                            }
                        ))
                        .disabled(languages == [language.rawValue])
                    }
                }
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity)
                .disabled(locked || !settings.usesWhisperOptions)
                .accessibilityLabel("Spoken languages")
                .accessibilityValue(settings.usesWhisperOptions ? languageNames : "Detected automatically")
                .help(settings.usesWhisperOptions
                    ? languageNames + ". One transcription pass per language; at least one is required."
                    : "Parakeet detects each language automatically. To choose languages, switch to Whisper in Advanced transcription.")
            }
            GridRow {
                Toggle("Add speaker labels", isOn: Binding(
                    get: { settings.speakerLabels == true },
                    set: { settings.speakerLabels = $0 }
                ))
                .toggleStyle(.checkbox)
                .disabled(locked)
                .help("Adds Speaker 1, Speaker 2… after transcription. Downloads about 11 MB once, takes longer, and needs review.")
                .gridCellColumns(2)
            }
        }
    }
}

struct RetranscriptionView: View {
    let meeting: MeetingHistoryItem
    @State var languages: [String]
    @State var hints: String
    @State var settings: SpeechSettings
    @State var advancedPresented = false
    let start: ([String], String, SpeechSettings) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if advancedPresented {
                OptionsPageHeader(title: "Advanced transcription", backTo: "Re-transcribe meeting") {
                    advancedPresented = false
                }
                AdvancedTranscriptionView(settings: $settings, hints: $hints)
            } else {
                HStack {
                    Text("Re-transcribe meeting").font(.headline)
                    Spacer()
                    Button { advancedPresented = true } label: {
                        Label("Advanced…", systemImage: "waveform")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Advanced transcription")
                    .help("Engine, model, vocabulary, and decoding options")
                }
                Text(meeting.title).lineLimit(2)
                Text("Replaces the saved transcript, including edits, only after processing succeeds. The meeting name stays the same.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    TranscriptionOptionsView(
                        languages: $languages, settings: $settings
                    )
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Re-transcribe") {
                    dismiss()
                    start(languages, hints, settings)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(20)
        .frame(width: 360)
    }
}

struct AdvancedTranscriptionView: View {
    @Binding var settings: SpeechSettings
    @Binding var hints: String
    var modelSelectionDisabled = false
    @State var decodingExpanded = false

    private var engineBinding: Binding<TranscriptionEngine> {
        Binding(get: { settings.selectedEngine }, set: { settings.engine = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Applies to future transcriptions.")
                    .font(.caption).foregroundStyle(.secondary)
                HelpPopover(text: "The engine picks speed or accuracy; the model trades memory for quality; vocabulary and decoding help Whisper with names and noisy audio. Defaults suit most meetings.")
                Spacer(minLength: 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Engine")
                    Picker("Engine", selection: engineBinding) {
                        ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(modelSelectionDisabled)
                    .accessibilityLabel("Engine")
                }
                GridRow {
                    Text("")
                    Text(settings.selectedEngine.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.usesWhisperOptions {
                    GridRow {
                        Text("Model")
                        Picker("Whisper model", selection: $settings.model) {
                            ForEach(SpeechModel.allCases, id: \.self) { model in
                                Text(model == .turbo ? "\(model.label) (default)" : model.label).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .disabled(modelSelectionDisabled)
                        .accessibilityLabel("Whisper model")
                    }
                    GridRow {
                        Text("")
                        Text(settings.model.detail + " Downloads once, then works offline.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    GridRow {
                        Text("Vocabulary")
                        TextField("Names and terms (optional)", text: $hints)
                            .textFieldStyle(.roundedBorder)
                            .help("Comma-separated names, companies, or technical terms to help Whisper recognize them")
                    }
                }
            }
            if settings.usesWhisperOptions {
                DisclosureGroup("Decoding", isExpanded: $decodingExpanded) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        option("Temperature", value: $settings.temperature, range: 0...1,
                               help: "Higher values allow more varied wording; zero uses greedy decoding.")
                        GridRow {
                            Text("Fallback attempts")
                            Stepper(value: $settings.fallbackCount, in: 0...10) {
                                Text("\(settings.fallbackCount)").monospacedDigit()
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                                .frame(width: 76)
                                .accessibilityLabel("Fallback attempts")
                                .help("Retries when decoding fails the quality thresholds. Zero disables retries.")
                        }
                        option("Temperature increase", value: $settings.fallbackIncrement, range: 0...1,
                               help: "Temperature increase for each retry.")
                        option("No-speech threshold", value: $settings.noSpeechThreshold, range: 0...1,
                               help: "A segment is treated as silence when its no-speech probability exceeds this and its log probability is below the threshold.")
                        option("Log probability threshold", value: $settings.logProbThreshold, range: -5...0,
                               help: "Average token log probability below this triggers a retry, or silence removal when the no-speech threshold is also exceeded.")
                        option("Repetition threshold", value: $settings.compressionRatioThreshold, range: 1...5,
                               help: "Compression ratio above this triggers a retry for repetitive output.")
                    }
                    .padding(.top, 8)
                    HStack {
                        Button("Reset decoding defaults") {
                            settings = SpeechSettings(
                                engine: settings.engine, model: settings.model, speakerLabels: settings.speakerLabels
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
            } else {
                Text("Vocabulary and decoding options apply to Whisper only.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Models").font(.headline)
            ModelStorageView()
        }
        .controlSize(.small)
    }

    private func option(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, help: String) -> some View {
        GridRow {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Stepper(value: value, in: range, step: 0.1) {
                Text(value.wrappedValue, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: 76)
            .accessibilityLabel(title)
            .help(help)
        }
    }
}

/// A visible ? beside advanced controls; `.help()` tooltips alone stay hidden until hover.
private struct HelpPopover: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help")
        .popover(isPresented: $showing) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: 260)
                .padding(12)
        }
    }
}

/// The title row of an Options page, with the back arrow beside the title.
private struct OptionsPageHeader: View {
    let title: String
    var backTo = "Options"
    let back: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.callout.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Back to \(backTo)")
            .help("Back to \(backTo)")
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.leading, -4)
    }
}

/// A row that opens an Options page; its arrow mirrors the back arrow in each page header.
private struct OptionsNavigationRow: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: systemImage)
                        .frame(width: 18)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help(help)
    }
}
