import Foundation

/// Cumulative Anthropic token usage for one recording session.
struct AITokenTotals: Codable, Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var calls = 0
}

/// Estimated pricing constants. Copilot rates verified against the claude-api
/// skill on 2026-07-02 — update here when providers change pricing.
enum AIPricing {
    /// claude-haiku-4-5: $1.00 / 1M input tokens, $5.00 / 1M output tokens.
    static let haikuInputUSDPerMTok = 1.00
    static let haikuOutputUSDPerMTok = 5.00
    /// Groq whisper-large-v3-turbo: $0.04 per audio hour.
    static let groqUSDPerAudioHour = 0.04
    /// Deepgram Nova-3 streaming: $0.29 per audio hour per stream — matches the
    /// "rate applied" on Deepgram's own billing dashboard (verified against a
    /// real invoice 2026-07-02: 220s billed = $0.01788).
    static let deepgramUSDPerAudioHour = 0.29
}

/// Per-meeting AI usage snapshot, stored denormalized in `Meeting.aiUsageData`
/// (same JSON pattern as profileSnapshotData). All dollar figures are estimates
/// from the AIPricing table — the UI labels them "estimated".
struct AIUsage: Codable {
    /// Model used for the live copilot + post-call reports.
    var copilotModel = ""
    /// CopilotProviderKind rawValue ("claude"/"ollama"/"custom"); nil on
    /// meetings recorded before provider selection existed (= claude).
    var copilotProvider: String?
    var copilot = AITokenTotals()
    /// Live transcription engine (TranscriptionBackend rawValue).
    var transcriptionBackend = TranscriptionBackend.local.rawValue
    /// Audio duration per track, seconds.
    var transcriptionSeconds: Double = 0
    /// Billable audio tracks (mic + system = 2; 1 when the mic never recorded).
    var transcriptionTracks = 2
    /// Post-call Groq polish: seconds of audio re-transcribed, all tracks
    /// summed. 0 when polish didn't run.
    var polishSeconds: Double = 0

    struct LineItem: Equatable {
        let label: String
        let detail: String
        let usd: Double
    }

    /// Pure cost math — harness-tested in ProfileTest.
    func costBreakdown() -> [LineItem] {
        var items: [LineItem] = []
        if copilot.calls > 0 {
            let tokens = "\(copilot.calls) calls · \(Self.compactTokens(copilot.inputTokens)) in / \(Self.compactTokens(copilot.outputTokens)) out"
            switch copilotProvider {
            case "ollama":
                // Runs on this Mac — the whole point.
                items.append(LineItem(label: "Copilot \(copilotModel) — local",
                                      detail: tokens, usd: 0))
            case "custom":
                // Rates for arbitrary servers aren't tracked; show tokens, claim $0.
                items.append(LineItem(label: "Copilot \(copilotModel)",
                                      detail: tokens + " · rates not tracked", usd: 0))
            default:
                // Claude (nil = meetings recorded before provider selection).
                let usd = Double(copilot.inputTokens) / 1_000_000 * AIPricing.haikuInputUSDPerMTok
                    + Double(copilot.outputTokens) / 1_000_000 * AIPricing.haikuOutputUSDPerMTok
                items.append(LineItem(label: "Copilot \(copilotModel)",
                                      detail: tokens, usd: usd))
            }
        }
        let backend = TranscriptionBackend(rawValue: transcriptionBackend) ?? .local
        let billedSeconds = transcriptionSeconds * Double(transcriptionTracks)
        let transcriptionUSD: Double = switch backend {
        case .local: 0
        case .groq: billedSeconds / 3600 * AIPricing.groqUSDPerAudioHour
        case .deepgram: billedSeconds / 3600 * AIPricing.deepgramUSDPerAudioHour
        }
        items.append(LineItem(
            label: "Transcription \(backend.label)",
            detail: backend == .local ? "on-device" : Self.compactMinutes(billedSeconds),
            usd: transcriptionUSD))
        if polishSeconds > 0 {
            items.append(LineItem(
                label: "Polish Groq",
                detail: Self.compactMinutes(polishSeconds),
                usd: polishSeconds / 3600 * AIPricing.groqUSDPerAudioHour))
        }
        return items
    }

    var totalUSD: Double {
        costBreakdown().reduce(0) { $0 + $1.usd }
    }

    static func compactTokens(_ n: Int) -> String {
        n >= 1000 ? "\(Int((Double(n) / 1000).rounded()))k" : "\(n)"
    }

    static func compactMinutes(_ seconds: Double) -> String {
        "\(max(1, Int((seconds / 60).rounded()))) min"
    }

    /// UI money formatting: cost rows deal in cents, so 2 decimals normally and
    /// 3 when the amount would otherwise show as $0.00.
    static func formatUSD(_ usd: Double) -> String {
        usd > 0 && usd < 0.005 ? String(format: "$%.3f", usd) : String(format: "$%.2f", usd)
    }
}
