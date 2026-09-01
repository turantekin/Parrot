import Foundation

/// How a feature splits work between this Mac and a cloud vendor.
enum ProcessingMode: String, CaseIterable, Identifiable {
    case local, hybrid, cloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "Local"
        case .hybrid: "Hybrid"
        case .cloud: "Cloud"
        }
    }

    /// Invalid or missing stored values fall back to on-device.
    static func resolved(_ raw: String?) -> ProcessingMode {
        ProcessingMode(rawValue: raw ?? "") ?? .local
    }

    /// Downloaded Whisper / Ollama (and Hybrid's first pass).
    var runsLocalModel: Bool {
        switch self {
        case .local, .hybrid: true
        case .cloud: false
        }
    }

    /// Preferred vendor (Hybrid's enhance pass, or Cloud alone).
    var runsCloudModel: Bool {
        switch self {
        case .local: false
        case .hybrid, .cloud: true
        }
    }
}

/// Vendor used by every Hybrid / Cloud speech or rewrite path.
enum CloudVendor: String, CaseIterable, Identifiable {
    case gemini, groq, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gemini: "Gemini"
        case .groq: "Groq"
        case .custom: "Custom server"
        }
    }

    var keychainAccount: String {
        switch self {
        case .gemini: "gemini-api-key"
        case .groq: TranscriptionBackend.groq.keychainAccount!
        case .custom: "custom-llm-api-key"
        }
    }

    static func resolved(_ raw: String?) -> CloudVendor {
        CloudVendor(rawValue: raw ?? "") ?? .gemini
    }

    static var selected: CloudVendor {
        resolved(UserDefaults.standard.string(forKey: FeatureProcessing.cloudVendorKey))
    }

    /// Non-empty key for this vendor, or nil. The profile-test harness
    /// short-circuits `APIKeyStore.load`, so this stays hermetic there.
    func speechKey() -> String? {
        let key = APIKeyStore.load(account: keychainAccount)
        return (key?.isEmpty == false) ? key : nil
    }
}

/// Per-feature mode keys. Local / Hybrid / Cloud means the same thing
/// everywhere (`ProcessingMode.runsLocalModel` / `runsCloudModel`).
enum FeatureProcessing {
    static let callModeKey = "callProcessingMode"
    static let polishModeKey = "polishProcessingMode"
    static let translationModeKey = "translationProcessingMode"
    static let dictationModeKey = "dictationProcessingMode"
    /// Written only during the brief one-mode experiment; read to seed features.
    static let sharedModeKey = "processingMode"
    static let cloudVendorKey = "preferredCloudVendor"
    static let refineIntervalKey = "hybridRefineInterval"
    static let translationEnabledKey = "liveTranslationEnabled"
    static let translationTargetKey = "liveTranslationTarget"
    static let translationOllamaModelKey = "translationOllamaModel"
    static let translationOllamaDefault = "gemma3:1b"
    static let appleTranslationKey = "useAppleTranslation"
    static let appleReadyKey = "appleTranslationReadyPairs"
    static let appleDeclinedKey = "appleTranslationDeclinedPairs"
    static let showBarKey = "showProcessingBar"
    /// When on, finished dictation (and transforms) insert into the focused field.
    static let autoPasteKey = "dictationAutoPaste"
    static let lastDictationKey = "lastDictationTranscript"

    static var call: ProcessingMode { resolved(callModeKey) }
    static var polish: ProcessingMode { resolved(polishModeKey, polishLegacy: true) }
    static var translation: ProcessingMode { resolved(translationModeKey) }
    static var dictation: ProcessingMode { resolved(dictationModeKey) }

    /// Local / Hybrid translation text model. Separate from Copilot's Ollama pick.
    static var translationOllamaModel: String {
        let stored = UserDefaults.standard.string(forKey: translationOllamaModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if LocalTextCatalog.entry(id: stored) != nil { return stored }
        return translationOllamaDefault
    }

    static func resolved(_ key: String, polishLegacy: Bool = false) -> ProcessingMode {
        if let stored = UserDefaults.standard.string(forKey: key) {
            return ProcessingMode.resolved(stored)
        }
        if let shared = UserDefaults.standard.string(forKey: sharedModeKey) {
            return ProcessingMode.resolved(shared)
        }
        if polishLegacy, UserDefaults.standard.bool(forKey: "polishAfterCall") {
            return .hybrid
        }
        return .local
    }

    /// Copy the short-lived shared mode onto any feature that has no value yet.
    static func migrateIfNeeded() {
        guard let shared = UserDefaults.standard.string(forKey: sharedModeKey) else { return }
        let inherited = ProcessingMode.resolved(shared).rawValue
        for key in [callModeKey, polishModeKey, translationModeKey, dictationModeKey]
        where UserDefaults.standard.string(forKey: key) == nil {
            UserDefaults.standard.set(inherited, forKey: key)
        }
    }

    /// Hybrid window length in seconds. 60 / 120 / 180; default 120.
    static var refineInterval: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: refineIntervalKey)
        if raw == 60 || raw == 180 { return raw }
        return 120
    }

    static let refineOverlap: TimeInterval = 5
}

/// Local = in-app model. Hybrid = that model, then Gemini. Cloud = Gemini only.
enum TranslationRouting {
    static func destinations(for mode: ProcessingMode) -> [TextRewriter.Destination] {
        switch mode {
        case .local: [.local]
        case .hybrid: [.local, .cloud]
        case .cloud: [.cloud]
        }
    }

    static func usesGemini(_ mode: ProcessingMode) -> Bool {
        mode.runsCloudModel
    }
}
