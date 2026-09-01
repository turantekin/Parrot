import Darwin
import Foundation

/// Per-session decode counters for `--liveloop-test` / `--asr-bench`.
/// The live UI never prints these; harnesses snapshot after stop.
struct DecodeStats: Sendable {
    var previewDecodes = 0
    var commitDecodes = 0
    var fallbackDecodes = 0
    var glossaryRetries = 0
    var languageDetects = 0
    var emptyTextCommits = 0
    var agreementEmits = 0
    var samplesDroppedAsSilence = 0
    var audioSecondsFed = 0.0
    var decodeMs: [Double] = []
    var firstPreviewMs: Double?
    var firstCommitMs: Double?
    var peakRSSMB = 0.0
    var startedAt = Date()

    enum Kind: Sendable {
        case preview, commit, fallback, glossaryRetry
    }

    mutating func record(_ kind: Kind, ms: Double, meetingStart: Date) {
        decodeMs.append(ms)
        peakRSSMB = max(peakRSSMB, Self.currentRSSMB())
        let sinceStart = Date().timeIntervalSince(meetingStart) * 1000
        switch kind {
        case .preview:
            previewDecodes += 1
            if firstPreviewMs == nil { firstPreviewMs = sinceStart }
        case .commit:
            commitDecodes += 1
            if firstCommitMs == nil { firstCommitMs = sinceStart }
        case .fallback:
            fallbackDecodes += 1
        case .glossaryRetry:
            glossaryRetries += 1
        }
    }

    /// LocalAgreement emit — no extra decode, but it is the first committed text.
    mutating func recordAgreementEmit(meetingStart: Date) {
        agreementEmits += 1
        if firstCommitMs == nil {
            firstCommitMs = Date().timeIntervalSince(meetingStart) * 1000
        }
        peakRSSMB = max(peakRSSMB, Self.currentRSSMB())
    }

    func snapshot(segmentCount: Int) -> Snapshot {
        let wall = Date().timeIntervalSince(startedAt)
        let rtfx = wall > 0 ? audioSecondsFed / wall : 0
        return Snapshot(
            audioSeconds: audioSecondsFed,
            wallSeconds: wall,
            rtfx: rtfx,
            firstPreviewMs: firstPreviewMs,
            firstCommitMs: firstCommitMs,
            previewDecodes: previewDecodes,
            commitDecodes: commitDecodes,
            fallbackDecodes: fallbackDecodes,
            glossaryRetries: glossaryRetries,
            languageDetects: languageDetects,
            emptyTextCommits: emptyTextCommits,
            agreementEmits: agreementEmits,
            samplesDroppedAsSilence: samplesDroppedAsSilence,
            decodeP50: Self.percentile(decodeMs, 0.50),
            decodeP90: Self.percentile(decodeMs, 0.90),
            peakRSSMB: peakRSSMB,
            segments: segmentCount
        )
    }

    struct Snapshot: Sendable {
        var audioSeconds: Double
        var wallSeconds: Double
        var rtfx: Double
        var firstPreviewMs: Double?
        var firstCommitMs: Double?
        var previewDecodes: Int
        var commitDecodes: Int
        var fallbackDecodes: Int
        var glossaryRetries: Int
        var languageDetects: Int
        var emptyTextCommits: Int
        var agreementEmits: Int
        var samplesDroppedAsSilence: Int
        var decodeP50: Double?
        var decodeP90: Double?
        var peakRSSMB: Double
        var segments: Int

        func footerLines() -> [String] {
            func ms(_ v: Double?) -> String {
                v.map { String(format: "%.0f", $0) } ?? "-"
            }
            func dec(_ v: Double?, _ fmt: String) -> String {
                v.map { String(format: fmt, $0) } ?? "-"
            }
            return [
                "=== liveloop-metrics ===",
                String(format: "audio_s            %.1f", audioSeconds),
                String(format: "wall_s             %.1f", wallSeconds),
                String(format: "rtfx               %.2f", rtfx),
                "first_preview_ms   \(ms(firstPreviewMs))",
                "first_commit_ms    \(ms(firstCommitMs))",
                "preview_decodes    \(previewDecodes)",
                "commit_decodes     \(commitDecodes)",
                "fallback_decodes   \(fallbackDecodes)",
                "glossary_retries   \(glossaryRetries)",
                "language_detects   \(languageDetects)",
                "empty_text_commits \(emptyTextCommits)",
                "agreement_emits    \(agreementEmits)",
                "silence_dropped    \(samplesDroppedAsSilence)",
                "decode_ms p50/p90  \(dec(decodeP50, "%.0f")) / \(dec(decodeP90, "%.0f"))",
                String(format: "peak_rss_mb        %.0f", peakRSSMB),
                "segments           \(segments)",
            ]
        }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    static func currentRSSMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
