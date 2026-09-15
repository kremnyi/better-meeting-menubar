import Foundation

enum AppState: Equatable {
    case idle
    case preparing
    case recording
    case failed
}

enum ProcessingPhase: Equatable {
    case finalizingRecording
    case preparingAudio
    case preparingModel
    case downloadingModel
    case loadingModel
    case transcribing
    case labelingSpeakers
    case writingFiles
    case extractingScreens
    case exportingBundle

    var stepText: String {
        switch self {
        case .finalizingRecording: "Step 1 of 5"
        case .preparingAudio: "Step 2 of 5"
        case .preparingModel, .downloadingModel, .loadingModel: "Step 3 of 5"
        case .transcribing: "Step 4 of 5"
        case .writingFiles: "Step 5 of 5"
        case .labelingSpeakers: "Speaker labels"
        case .extractingScreens: "Step 1 of 2"
        case .exportingBundle: "Step 2 of 2"
        }
    }

    var statusText: String {
        switch self {
        case .finalizingRecording: "Finalizing the recording…"
        case .preparingAudio: "Preparing audio for transcription…"
        case .preparingModel: "Checking the speech model…"
        case .downloadingModel: "Downloading the speech model…"
        case .loadingModel: "Loading the speech model…"
        case .transcribing: "Transcribing…"
        case .labelingSpeakers: "Preparing speaker labels…"
        case .writingFiles: "Writing transcript.md…"
        case .extractingScreens: "Extracting screenshots and screen text…"
        case .exportingBundle: "Writing the export bundle…"
        }
    }
}

enum PrivacyPermission: Equatable {
    case screenRecording
    case microphone

    var accessNeededText: String {
        switch self {
        case .screenRecording: "Screen access needed"
        case .microphone: "Microphone access needed"
        }
    }

    var settingsURL: URL? {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

enum AppError: LocalizedError {
    case missingRecording

    var errorDescription: String? {
        switch self {
        case .missingRecording:
            "The active recording folder is missing. Start a new recording."
        }
    }
}
