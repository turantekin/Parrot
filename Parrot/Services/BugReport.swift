import AppKit

/// Turns "something's wrong" into a pre-filled GitHub issue that the user
/// submits themselves.
///
/// Deliberately serverless: GitHub accepts a title, body and labels as query
/// params on /issues/new, so the whole feature is a form plus a link — no
/// backend, no API token in the app, no third-party service seeing the report.
/// (Web widgets like BugDrop upload screenshots to a branch in the repo; for an
/// app whose window shows other people's call transcripts, that's a leak
/// waiting to happen.)
///
/// The screenshot is taken from Parrot's own window — never the screen, so it
/// can't catch another app — and lands on the clipboard for the user to paste
/// into the issue. Nothing is ever uploaded on their behalf.
enum BugReport {
    enum Kind: String, CaseIterable, Identifiable {
        case bug, idea

        var id: String { rawValue }

        var label: String {
            switch self {
            case .bug: "Something's broken"
            case .idea: "An idea"
            }
        }

        /// Both labels already exist in the repo.
        var githubLabel: String {
            switch self {
            case .bug: "bug"
            case .idea: "enhancement"
            }
        }

        var placeholder: String {
            switch self {
            case .bug: "What did you do, what happened, and what did you expect instead?"
            case .idea: "What would you like Parrot to do?"
            }
        }
    }

    /// What's useful for debugging and nothing that identifies the user or
    /// their calls: no API keys, no transcript text, no meeting titles, no
    /// file paths (the audio folder contains the account name).
    static func diagnostics() -> [String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let defaults = UserDefaults.standard
        let backend = defaults.string(forKey: TranscriptionBackend.defaultsKey)
            ?? TranscriptionBackend.local.rawValue
        let copilot = defaults.bool(forKey: "copilotEnabled")
            ? (defaults.string(forKey: "copilotProvider") ?? "claude")
            : "off"
        #if arch(arm64)
        let cpu = "Apple silicon"
        #else
        let cpu = "Intel"
        #endif
        return [
            "Parrot \(AppUpdater.currentVersion) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(cpu)",
            "Model: \(defaults.string(forKey: "whisperModel") ?? "base") · Transcription: \(backend) · Assistant: \(copilot)",
        ]
    }

    /// The issue body. The screenshot line is a comment so it renders as an
    /// empty spot in the issue — GitHub uploads an image wherever the caret is
    /// when you paste, so telling the user exactly where to put it matters.
    static func body(text: String, includeDiagnostics: Bool, includeScreenshot: Bool) -> String {
        var parts = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if includeScreenshot {
            parts.append("<!-- Screenshot: click here and press ⌘V to paste it in -->")
        }
        if includeDiagnostics {
            parts.append("---\n" + diagnostics().joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Encoded by hand: URLComponents leaves `&`, `+` and `=` unescaped inside
    /// query values, so a title containing an ampersand would chop the body
    /// into junk parameters.
    static func issueURL(kind: Kind, title: String, body: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        func escape(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        let query = "title=\(escape(title.trimmingCharacters(in: .whitespaces)))"
            + "&body=\(escape(body))"
            + "&labels=\(kind.githubLabel)"
        return URL(string: "\(MeetingActions.repoURL)/issues/new?\(query)")
    }

    /// A picture of Parrot's own window, captured the same way the help-book
    /// screenshot harness does it: straight off the view hierarchy, so it needs
    /// no Screen Recording permission and cannot include anything but us.
    /// Call this *before* presenting the sheet — otherwise the report form
    /// photobombs the thing being reported.
    @MainActor
    static func captureWindow() -> NSImage? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        guard let view = window?.contentView, view.bounds.width > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    static func copyToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func copyToPasteboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
