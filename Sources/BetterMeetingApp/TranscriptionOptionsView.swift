import ServiceManagement
import SwiftUI

struct CaptureOptionsView: View {
    enum Page {
        case options, meetings, advanced, appSettings, about
    }

    /// The login item status as last read. SwiftUI rebuilds this view on every menu redraw and each read
    /// is a round trip to the login items service, so it is read when the menu opens and after changes.
    /// `nil` until the first background read lands, so no view ever performs that read on the main thread.
    private(set) static var knownLaunchAtLoginStatus: SMAppService.Status?

    /// The menu calls this on every open; the status read can block for seconds, so it lands after.
    /// Pass the toggle's binding where the caller also shows the value.
    static func refreshLaunchAtLoginStatusInBackground(updating state: Binding<SMAppService.Status?>? = nil) {
        Task.detached(priority: .utility) {
            let status = SMAppService.mainApp.status
            await MainActor.run {
                knownLaunchAtLoginStatus = status
                state?.wrappedValue = status
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State var page: Page = .options
    @State var launchAtLoginStatus: SMAppService.Status? = Self.knownLaunchAtLoginStatus
    @State var launchAtLoginError: String?
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch page {
            case .meetings:
                OptionsPageHeader(title: "Meetings") { page = .options }
                MeetingOptionsView(calendar: model.calendar, detectsMeetings: $model.detectsMeetings)
            case .advanced:
                OptionsPageHeader(title: "Advanced transcription") { page = .options }
                AdvancedTranscriptionView(
                    settings: $model.speechSettings, languages: $model.transcriptionLanguages, hints: $model.transcriptionHints,
                    modelSelectionDisabled: model.modelPreparationTask != nil || model.modelDownloadTask != nil
                )
                .disabled(model.isProcessing)
            case .about:
                OptionsPageHeader(title: "About", backTo: "App & updates") { page = .appSettings }
                AboutView(version: version)
            case .appSettings:
                OptionsPageHeader(title: "App & updates") { page = .options }
                appSettings
            case .options:
                basicOptions
                if let notice = model.settingsLockNotice {
                    Text(notice).wrappingCaption()
                }
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    OptionsNavigationRow(title: "Meetings", systemImage: "calendar.badge.clock",
                                         help: "Calendars, and when to suggest a recording") {
                        page = .meetings
                    }
                    OptionsNavigationRow(title: "Advanced transcription", systemImage: "waveform",
                                         help: "Engine, languages, speaker labels, model, vocabulary, decoding, and downloaded models") {
                        page = .advanced
                    }
                    OptionsNavigationRow(title: "App & updates", systemImage: "gearshape",
                                         help: "Launch at login, menu bar recording time, updates, and the installed version") {
                        page = .appSettings
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
        // Sections sit further apart than their rows, so each heading reads with the rows below it
        // in the same height as the even spacing it replaces; the layout tests cap this page.
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 5) {
                Text("General").font(.headline)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginStatus == .enabled },
                    set: setLaunchAtLogin
                ))
                // Unknown only until the background status read lands, moments after the menu opens.
                .disabled(launchAtLoginStatus == nil)
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
                    .fixedSize(horizontal: false, vertical: true)
                    .toggleCaption()
                    .help(launchAtLoginError ?? "")
                }
                Toggle("Show recording time in the menu bar", isOn: $model.menuBarRecordingTime)
                    .setting(help: "Shows the elapsed time beside the menu bar icon while recording")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Updates").font(.headline)
                Toggle("Download updates automatically", isOn: $model.automaticUpdateChecks)
                    .setting(help: "Checks GitHub on launch and periodically. Downloads in the background; installs when you restart or quit.")
                Toggle("Include beta releases", isOn: $model.betaUpdates)
                    .setting(help: "Offers beta builds ahead of the next release. Stable releases arrive either way.")
                UpdateOptionsView(updates: model.updates, version: version)
            }
            Divider()
            OptionsNavigationRow(title: "About Better Meeting", systemImage: "info.circle",
                                 help: "Version, author, links, and license") {
                page = .about
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
                .gridPicker("Display", disabled: model.isCapturing)
                .help("The entire selected display is recorded")
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
                .gridPicker("Microphone", disabled: model.isCapturing)
                .help("Recorded along with system audio")
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
                .disabled(model.isCapturing)
                .accessibilityLabel("Video quality")
                .accessibilityValue(videoQualityLabel)
                .help("Resolution limits the video's longest edge without upscaling. Smoother motion uses more storage.")
            }
            Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 2)
            GridRow {
                Text("Files").font(.headline).gridCellColumns(2)
            }
            GridRow {
                Text("Save to")
                destinationButton
            }
            GridRow {
                Toggle("Include screenshots and screen text", isOn: $model.exportAfterRecording)
                    .disabled(model.fileSettingsLocked)
                    .setting(help: "After saving each transcript, export a bundle with screenshots and screen text into an artifacts folder.",
                             caption: model.exportAfterRecording ? "Saves extra files beside the transcript." : nil)
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
        Self.knownLaunchAtLoginStatus = service.status
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

struct TranscriptionLanguagePicker: View {
    @Binding var languages: [String]
    @State private var query = ""

    private static let commonCodes = ["uk", "ru", "en", "de", "fr", "es", "pt"]

    private var selectedLanguages: [TranscriptionLanguage] {
        languages.compactMap(TranscriptionLanguage.init(rawValue:))
    }

    private var commonLanguages: [TranscriptionLanguage] {
        Self.commonCodes.compactMap(TranscriptionLanguage.init(rawValue:))
            .filter { !languages.contains($0.rawValue) }
    }

    private var remainingLanguages: [TranscriptionLanguage] {
        let excluded = Set(languages + Self.commonCodes)
        return TranscriptionLanguage.allCases.filter { !excluded.contains($0.rawValue) }
    }

    private var results: [TranscriptionLanguage] {
        Self.orderedLanguages(query: query, selected: languages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spoken languages")
                .font(.headline)
            TextField("Search languages", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search languages")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !selectedLanguages.isEmpty {
                            sectionHeader("Selected")
                            ForEach(selectedLanguages, id: \.rawValue) { languageRow($0) }
                        }
                        if !commonLanguages.isEmpty {
                            sectionHeader("Common")
                            ForEach(commonLanguages, id: \.rawValue) { languageRow($0) }
                        }
                        sectionHeader("All languages")
                        ForEach(remainingLanguages, id: \.rawValue) { languageRow($0) }
                    } else if !results.isEmpty {
                        sectionHeader("Results")
                        ForEach(results, id: \.rawValue) { languageRow($0) }
                    } else {
                        Text("No matching languages")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 10)
            }
            Text("At least one language is required. Each selected language adds one transcription pass.")
                .wrappingCaption()
        }
        .padding(14)
        .frame(width: 300, height: 360)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func languageRow(_ language: TranscriptionLanguage) -> some View {
        Toggle(language.label, isOn: Binding(
            get: { languages.contains(language.rawValue) },
            set: { _ in languages = Self.toggled(language.rawValue, in: languages) }
        ))
        .toggleStyle(.checkbox)
        .disabled(languages.contains(language.rawValue) && languages.count == 1)
        .padding(.vertical, 5)
    }

    static func toggled(_ rawValue: String, in languages: [String]) -> [String] {
        var result = languages
        if let index = result.firstIndex(of: rawValue) {
            guard result.count > 1 else { return result }
            result.remove(at: index)
        } else {
            result.append(rawValue)
        }
        return result
    }

    static func orderedLanguages(query: String, selected: [String]) -> [TranscriptionLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedSet = Set(selected)
        let matches = TranscriptionLanguage.allCases.filter { language in
            trimmed.isEmpty || language.label.localizedStandardContains(trimmed)
                || language.rawValue.localizedStandardContains(trimmed)
        }
        return matches.sorted {
            let leftSelected = selectedSet.contains($0.rawValue)
            let rightSelected = selectedSet.contains($1.rawValue)
            if leftSelected != rightSelected { return leftSelected }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }
}

struct RetranscriptionView: View {
    let meeting: MeetingHistoryItem
    @State var languages: [String]
    @State var hints: String
    @State var settings: SpeechSettings
    @State var advancedPresented = false
    let dismiss: () -> Void
    let start: ([String], String, SpeechSettings) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if advancedPresented {
                OptionsPageHeader(title: "Advanced transcription", backTo: meeting.needsTranscription ? "Transcribe meeting" : "Re-transcribe meeting") {
                    advancedPresented = false
                }
                AdvancedTranscriptionView(settings: $settings, languages: $languages, hints: $hints)
            } else {
                HStack {
                    Text(meeting.needsTranscription ? "Transcribe meeting" : "Re-transcribe meeting").font(.headline)
                    Spacer()
                    Button { advancedPresented = true } label: {
                        Label("Advanced…", systemImage: "waveform")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Advanced transcription")
                    .help("Engine, languages, speaker labels, model, vocabulary, and decoding options")
                }
                Text(meeting.title).lineLimit(2)
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meeting.needsTranscription
                     ? "Creates a transcript from the saved recording. The meeting name stays the same."
                     : "Replaces the saved transcript, including edits, only after processing succeeds. The meeting name stays the same.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(meeting.needsTranscription ? "Transcribe" : "Re-transcribe") {
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

    /// What will run, since the choices themselves sit behind Advanced.
    private var summary: String {
        let engine = settings.usesWhisperOptions
            ? "Whisper (" + languages.compactMap { TranscriptionLanguage(rawValue: $0)?.label }.joined(separator: ", ") + ")"
            : "Parakeet"
        return "Uses \(engine), " + (settings.speakerLabels == true ? "with speaker labels." : "without speaker labels.")
    }
}

struct AdvancedTranscriptionView: View {
    @Binding var settings: SpeechSettings
    @Binding var languages: [String]
    @Binding var hints: String
    var modelSelectionDisabled = false
    @State var decodingExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Applies to future transcriptions.")
                    .wrappingCaption()
                HelpPopover(text: "The engine picks speed or accuracy; the model trades memory for quality; vocabulary and decoding help Whisper with names and noisy audio. Defaults suit most meetings.")
                Spacer(minLength: 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Engine")
                    Picker("Engine", selection: Binding(get: { settings.selectedEngine }, set: { settings.engine = $0 })) {
                        ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    .gridPicker("Engine", disabled: modelSelectionDisabled)
                }
                GridRow {
                    Text("")
                    Text(settings.selectedEngine.detail).wrappingCaption()
                }
                if settings.usesWhisperOptions {
                    LanguagesRow(languages: $languages)
                    GridRow {
                        Text("Model")
                        Picker("Whisper model", selection: $settings.model) {
                            ForEach(SpeechModel.allCases, id: \.self) { model in
                                Text(model == .turbo ? "\(model.label) (default)" : model.label).tag(model)
                            }
                        }
                        .gridPicker("Whisper model", disabled: modelSelectionDisabled)
                    }
                    GridRow {
                        Text("")
                        Text(settings.model.detail + " Downloads once, then works offline.").wrappingCaption()
                    }
                    GridRow {
                        Text("Vocabulary")
                        TextField("Names and terms (optional)", text: $hints)
                            .textFieldStyle(.roundedBorder)
                            .help("Comma-separated names, companies, or technical terms to help Whisper recognize them")
                    }
                }
                GridRow {
                    Toggle("Add speaker labels", isOn: Binding(
                        get: { settings.speakerLabels == true },
                        set: { settings.speakerLabels = $0 }
                    ))
                    .setting(help: "Adds Speaker 1, Speaker 2… after transcription. Downloads about 11 MB once, takes longer, and needs review.")
                    .toggleStyle(.checkbox)
                    .gridCellColumns(2)
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
                Text("Parakeet detects each language automatically. Languages, vocabulary, and decoding options apply to Whisper only.")
                    .wrappingCaption()
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

/// Whisper's spoken languages: one transcription pass each. Parakeet detects them itself.
private struct LanguagesRow: View {
    @Binding var languages: [String]
    @State private var pickerPresented = false

    private var names: String {
        languages.compactMap { TranscriptionLanguage(rawValue: $0)?.label }.joined(separator: ", ")
    }

    var body: some View {
        GridRow {
            Text("Languages")
            Button {
                pickerPresented = true
            } label: {
                Text(names)
                    .lineLimit(1)
                    .padding(.trailing, 14) // Clears the chevron drawn over the button's end.
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 0, maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 7)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("Spoken languages")
            .accessibilityValue(names)
            .help(names + ". One transcription pass per language; at least one is required.")
            .popover(isPresented: $pickerPresented, arrowEdge: .bottom) {
                TranscriptionLanguagePicker(languages: $languages)
            }
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
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About these options")
        .help("About these options")
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
        .hoverHighlight(cornerRadius: 6)
        .help(help)
    }
}
