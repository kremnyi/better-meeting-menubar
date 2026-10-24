import AppKit

/// Opens a meeting in an AI app or CLI as a new, empty conversation. Nothing is sent;
/// the user writes the prompt in that app.
enum AssistantHandoff: CaseIterable, Identifiable {
    case claude
    case claudeCode
    case codex
    case codexCLI

    var id: Self { self }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .codexCLI: "Codex CLI"
        }
    }

    /// Deep links come from the apps themselves: Claude's "Send to Claude" Finder service
    /// attaches files to a new chat, and Codex's `threads/new` opens a thread in a folder.
    func url(for folder: URL) -> URL? {
        switch self {
        case .claude:
            Self.url("claude://cowork/new?source=services&file=", folder.appendingPathComponent("transcript.md").path)
        case .codex:
            Self.url("codex://threads/new?path=", folder.path)
        case .claudeCode, .codexCLI:
            nil
        }
    }

    var command: String? {
        switch self {
        case .claudeCode: "claude"
        case .codexCLI: "codex"
        case .claude, .codex: nil
        }
    }

    /// A Terminal script that starts the CLI in the meeting folder, through a login shell
    /// so the user's PATH applies. The script deletes itself when it runs.
    func script(for folder: URL) -> String? {
        guard let command else { return nil }
        return """
        #!/bin/zsh
        rm -f "$0"
        cd \(Self.shellQuoted(folder.path)) || exit 1
        /bin/zsh -lic \(Self.shellQuoted(command))

        """
    }

    @MainActor
    func open(_ folder: URL) throws {
        if let url = url(for: folder) {
            guard NSWorkspace.shared.open(url) else { throw HandoffError.notInstalled(title) }
        } else if let script = script(for: folder) {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("Better Meeting \(title) \(UUID().uuidString).command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            guard NSWorkspace.shared.open(file) else {
                try? FileManager.default.removeItem(at: file)
                throw HandoffError.terminalUnavailable
            }
        }
    }

    @MainActor
    func openOrAlert(_ folder: URL) {
        do {
            try open(folder)
        } catch {
            NSAlert(error: error).runActive()
        }
    }

    private static func url(_ prefix: String, _ path: String) -> URL? {
        // ASCII only: `.alphanumerics` would leave non-Latin titles unencoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: prefix + encoded)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum HandoffError: LocalizedError {
    case notInstalled(String)
    case terminalUnavailable

    var errorDescription: String? {
        switch self {
        case .notInstalled(let app): "\(app) could not be opened. Check that the app is installed."
        case .terminalUnavailable: "Terminal could not be opened."
        }
    }
}
