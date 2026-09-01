import Foundation

/// One Wispr-style live line. Timing and source only — never keep the text
/// so a meeting bench cannot leak call content into logs by default.
struct MeetingLiveLine: Sendable, Equatable {
    var startMs: Int
    var endMs: Int
    var source: String
}

struct MeetingRefStats: Sendable, Equatable {
    var lines: Int
    var mic: Int
    var system: Int
    var firstMs: Int?
    var p50DurMs: Int?
    var lastEndMs: Int?

    static func of(_ lines: [MeetingLiveLine]) -> MeetingRefStats {
        let durs = lines.map { max(0, $0.endMs - $0.startMs) }.sorted()
        return MeetingRefStats(
            lines: lines.count,
            mic: lines.filter { $0.source == "mic" }.count,
            system: lines.filter { $0.source == "system" }.count,
            firstMs: lines.map(\.startMs).min(),
            p50DurMs: durs.isEmpty ? nil : durs[durs.count / 2],
            lastEndMs: lines.map(\.endMs).max()
        )
    }
}

/// Parses Wispr Flow `live.ndjson` (and anything with the same keys).
enum MeetingLiveRef {
    static func parseNDJSON(_ raw: String) -> [MeetingLiveLine] {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> MeetingLiveLine? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["text"] != nil
            else { return nil }
            let start = intValue(obj["startRecordingMs"]) ?? 0
            let end = intValue(obj["endRecordingMs"]) ?? start
            var source = "unknown"
            if let speaker = obj["speaker"] as? [String: Any],
               let rawSource = speaker["source"] as? String, !rawSource.isEmpty {
                source = rawSource
            }
            return MeetingLiveLine(startMs: start, endMs: end, source: source)
        }
    }

    static func inWindow(_ lines: [MeetingLiveLine], windowMs: Int) -> [MeetingLiveLine] {
        guard windowMs > 0 else { return lines }
        return lines.filter { $0.startMs < windowMs }
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
}

enum MeetingCompare {
    /// Structure-only scorecard. Text / WER is out of scope: Wispr refine is a
    /// different cloud ASR. Meetings win or lose on first-commit lag and
    /// whether we emit at live density.
    static func lines(
        ref: MeetingRefStats,
        oursSegments: Int,
        oursFirstMs: Double?,
        oursP50DurMs: Double?
    ) -> [String] {
        let refFirst = ref.firstMs.map { Double($0) }
        let lag: Double? = {
            guard let oursFirstMs, let refFirst else { return nil }
            return oursFirstMs - refFirst
        }()
        func ms(_ v: Double?) -> String {
            v.map { String(format: "%.0f", $0) } ?? "-"
        }
        return [
            "=== meeting-bench ===",
            "ref_live            \(ref.lines)  (mic \(ref.mic) / system \(ref.system))",
            "ours_segments       \(oursSegments)",
            "ref_first_ms        \(ms(refFirst))",
            "ours_first_ms       \(ms(oursFirstMs))",
            "first_commit_lag_ms \(ms(lag))",
            "ref_p50_dur_ms      \(ref.p50DurMs.map(String.init) ?? "-")",
            "ours_p50_dur_ms     \(ms(oursP50DurMs))",
        ]
    }
}
