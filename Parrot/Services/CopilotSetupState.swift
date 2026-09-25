import Foundation

/// What the user settled on in the Copilot screens.
struct CopilotChoices {
    var path: CopilotPath
    var ollamaModel: String
    /// The Copilot card's switch: the user's consent to turn it on.
    var copilotSwitchOn: Bool
    var claudeKeyWorks: Bool
    var deepgramKeyWorks: Bool
    var ollamaModelReady: Bool
}

enum CopilotPathSettings {
    /// Private path, model still downloading: turn Copilot on when it lands.
    static let enableWhenReadyKey = "copilotEnableWhenOllamaReady"
    /// Copilot switched itself on; the Home card says so once.
    static let justTurnedOnKey = "copilotJustTurnedOn"
    static let cardDismissedKey = "copilotCardDismissed"

    /// Writes what a path implies. Leaves `whisperModel` to the speech step
    /// and `reportsProvider` empty, so reports follow Copilot.
    static func apply(_ c: CopilotChoices, to d: UserDefaults = .standard) {
        d.set(c.path.rawValue, forKey: CopilotPath.defaultsKey)
        d.set(false, forKey: enableWhenReadyKey)
        switch c.path {
        case .private:
            d.set(CopilotProviderKind.ollama.rawValue, forKey: "copilotProvider")
            d.set(c.ollamaModel, forKey: "copilotOllamaModel")
            d.set(TranscriptionBackend.local.rawValue, forKey: TranscriptionBackend.defaultsKey)
            d.set(c.copilotSwitchOn && c.ollamaModelReady, forKey: "copilotEnabled")
            d.set(c.copilotSwitchOn && !c.ollamaModelReady, forKey: enableWhenReadyKey)
        case .balanced:
            d.set(CopilotProviderKind.claude.rawValue, forKey: "copilotProvider")
            d.set(TranscriptionBackend.local.rawValue, forKey: TranscriptionBackend.defaultsKey)
            d.set(c.copilotSwitchOn && c.claudeKeyWorks, forKey: "copilotEnabled")
        case .cloud:
            d.set(CopilotProviderKind.claude.rawValue, forKey: "copilotProvider")
            let backend: TranscriptionBackend = c.deepgramKeyWorks ? .deepgram : .local
            d.set(backend.rawValue, forKey: TranscriptionBackend.defaultsKey)
            d.set(c.copilotSwitchOn && c.claudeKeyWorks, forKey: "copilotEnabled")
        case .later:
            d.set(false, forKey: "copilotEnabled")
        }
    }

    /// The Ollama model finished. Honours a pending "turn on" from the
    /// private path; returns true when it switched Copilot on.
    @discardableResult
    static func ollamaModelReady(in d: UserDefaults = .standard) -> Bool {
        guard d.bool(forKey: enableWhenReadyKey),
              d.string(forKey: CopilotPath.defaultsKey) == CopilotPath.private.rawValue else { return false }
        d.set(true, forKey: "copilotEnabled")
        d.set(false, forKey: enableWhenReadyKey)
        d.set(true, forKey: justTurnedOnKey)
        return true
    }
}

/// Where Copilot stands, for the Ready screen and the Home card.
enum CopilotStatus: Equatable {
    case on
    case waitingForModel(progress: Double?)
    case finishOllama
    case needsClaudeKey
    case off

    static func current(copilotEnabled: Bool, path: CopilotPath?, enableWhenReady: Bool,
                        ollamaPulling: Bool, ollamaProgress: Double?, hasClaudeKey: Bool) -> CopilotStatus {
        if copilotEnabled { return .on }
        switch path {
        case .private?:
            guard enableWhenReady else { return .off }
            return ollamaPulling ? .waitingForModel(progress: ollamaProgress) : .finishOllama
        case .balanced?, .cloud?:
            return hasClaudeKey ? .off : .needsClaudeKey
        case .later?, nil:
            return .off
        }
    }

    /// A download in flight always shows; "on" shows once, right after
    /// Copilot switched itself on; the nudges respect the close button.
    static func showsHomeCard(_ status: CopilotStatus, dismissed: Bool, justTurnedOn: Bool) -> Bool {
        switch status {
        case .on: justTurnedOn
        case .waitingForModel: true
        case .finishOllama, .needsClaudeKey, .off: !dismissed
        }
    }
}
