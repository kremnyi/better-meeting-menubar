import ServiceManagement
import SwiftUI

struct CaptureOptionsView: View {
    @EnvironmentObject private var model: AppModel
    @State var advancedPresented = false
    @State var launchAtLoginStatus = SMAppService.mainApp.status
    @State var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if advancedPresented {
                Button { advancedPresented = false } label: {
                    Label("Options", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                AdvancedTranscriptionView(
                    settings: $model.speechSettings, hints: $model.transcriptionHints,
                    modelSelectionDisabled: model.modelPreparationTask != nil
                )
                .disabled(model.updates.meetingInProgress)
            } else {
                basicOptions
                    .disabled(model.updates.meetingInProgress)
                    .tint(model.updates.meetingInProgress ? .secondary : .accentColor)
                if model.updates.meetingInProgress {
                    Text("Meeting settings are unavailable while recording or processing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
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
                    Toggle("Download updates automatically", isOn: $model.automaticUpdateChecks)
                        .help("Checks GitHub and downloads updates in the background. Installs when you restart or quit.")
                }
                .toggleStyle(.checkbox)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .onChange(of: model.speechSettings.model) { model.speechModelChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginStatus = SMAppService.mainApp.status
            launchAtLoginError = nil
        }
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
            }
            GridRow {
                Text("Microphone")
                Picker("Microphone", selection: $model.selectedMicrophoneID) {
                    Text("System default").tag("")
                    ForEach(model.microphones, id: \.uniqueID) { microphone in
                        Text(microphone.localizedName).tag(microphone.uniqueID)
                    }
                    if !model.selectedMicrophoneID.isEmpty && !model.microphones.contains(where: { $0.uniqueID == model.selectedMicrophoneID }) {
                        Text("Unavailable microphone").tag(model.selectedMicrophoneID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            GridRow {
                Text("Resolution")
                Picker("Resolution", selection: $model.captureResolution) {
                    ForEach(CaptureResolution.allCases, id: \.self) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
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
                .help("Smoother motion uses more storage")
            }
            Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 2)
            GridRow {
                HStack {
                    Text("Transcription").font(.headline)
                    Spacer()
                    Button("Advanced…") { advancedPresented = true }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Advanced transcription")
                }
                .gridCellColumns(2)
            }
            TranscriptionOptionsView(
                languages: $model.transcriptionLanguages, settings: $model.speechSettings
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
        launchAtLoginStatus = service.status
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
        .help(model.outputRoot.path)
        .accessibilityLabel("Save recordings to \(model.outputRoot.path)")
        .accessibilityHint("Choose a different folder")
    }

}

struct TranscriptionOptionsView: View {
    @Binding var languages: [String]
    @Binding var settings: SpeechSettings

    private var languageNames: String {
        languages.compactMap { TranscriptionLanguage(rawValue: $0)?.label }.joined(separator: ", ")
    }

    var body: some View {
        Group {
            GridRow {
                Text("Languages")
                Menu(languageNames) {
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
                .accessibilityLabel("Spoken languages")
                .accessibilityValue(languageNames)
                .help(languageNames + ". Select the languages you expect. At least one is required.")
            }
            GridRow {
                Text("Speakers")
                Toggle("Add labels", isOn: Binding(
                    get: { settings.speakerLabels == true },
                    set: { settings.speakerLabels = $0 }
                ))
                .toggleStyle(.checkbox)
                .accessibilityLabel("Add speaker labels")
                .help("Adds Speaker 1, Speaker 2… Downloads about 11 MB once. Labels may need correction.")
            }
            GridRow {
                Text("Extra languages and speaker labels take longer.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button { advancedPresented = false } label: {
                    Label("Transcription options", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                AdvancedTranscriptionView(settings: $settings, hints: $hints)
            } else {
                HStack {
                    Text("Re-transcribe meeting").font(.headline)
                    Spacer()
                    Button("Advanced…") { advancedPresented = true }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Advanced transcription")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced transcription").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Model")
                    Picker("Whisper model", selection: $settings.model) {
                        ForEach(SpeechModel.allCases, id: \.self) { model in
                            Text(model.label).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(modelSelectionDisabled)
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
            Divider()
            Text("Retries and filtering").font(.headline)
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
            Button("Reset decoding defaults") {
                settings = SpeechSettings(model: settings.model, speakerLabels: settings.speakerLabels)
            }
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
