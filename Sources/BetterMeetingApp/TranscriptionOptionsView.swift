import SwiftUI

/// The menu's Options popover: the choices people change per meeting. Quality,
/// engine, models, calendars, and updates live in the Settings window.
struct CaptureOptionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Recording").font(.headline).gridCellColumns(2)
                }
                CaptureDeviceRows()
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
                FileSettingsRows()
            }
            SettingsLockNotice()
            Divider()
            HStack {
                Spacer()
                Button {
                    dismiss()
                    model.showSettings(.general, using: openSettings)
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .help("Resolution, frame rate, transcription engine and models, calendars, launch at login, and updates")
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

/// Display and microphone rows for a two-column Grid. They apply when a recording
/// starts, so only a running capture locks them.
struct CaptureDeviceRows: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
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
                .disabled(model.captureSettingsLocked)
                .help("Recorded along with system audio")
            }
        }
    }
}

/// Save folder and automatic export rows for a two-column Grid.
struct FileSettingsRows: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
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

/// Explains which settings a running recording or transcription has locked.
struct SettingsLockNotice: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let notice = model.settingsLockNotice {
            Text(notice)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                Menu(settings.usesWhisperOptions ? languageNames : "Whisper only") {
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
                .accessibilityValue(settings.usesWhisperOptions ? languageNames : "Whisper only")
                .help(settings.usesWhisperOptions
                    ? languageNames + ". One transcription pass per language; at least one is required."
                    : "Whisper only. Parakeet detects each language automatically.")
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
                OptionsBackButton(title: "Transcription options") { advancedPresented = false }
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
    /// Settings shows languages and speaker labels in the same grid; Re-transcribe keeps them on its first page.
    var languages: Binding<[String]>?
    var title: String? = "Advanced transcription"
    var modelSelectionDisabled = false
    @State var decodingExpanded = false

    private var engineBinding: Binding<TranscriptionEngine> {
        Binding(get: { settings.selectedEngine }, set: { settings.engine = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                if let languages {
                    TranscriptionOptionsView(languages: languages, settings: $settings)
                    Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 2)
                }
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
        }
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

private struct OptionsBackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}
