import AppKit
import Foundation
import SwiftData

/// Consent records, retention clean-up and the "what left this Mac" line.
extension RecordingManager {

    // MARK: Consent

    /// Records how the other side was told, at this moment of the call.
    /// `.noticeShared` also copies the notice to paste into the call chat.
    func recordConsent(_ method: Consent.Method) {
        guard let meeting = currentMeeting, let start = recordingStartTime else { return }
        var notice: String?
        if method == .noticeShared {
            notice = Consent.currentNotice
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Consent.currentNotice, forType: .string)
        }
        meeting.consent = Consent(method: method, at: Date.now.timeIntervalSince(start), notice: notice)
        try? modelContext?.save()
    }

    // MARK: Retention

    /// Applies the retention settings once. Returns (audio removed, meetings deleted).
    @discardableResult
    func applyRetention(now: Date = .now) -> (Int, Int) {
        let audioDays = UserDefaults.standard.integer(forKey: Retention.audioDaysKey)
        let meetingDays = UserDefaults.standard.integer(forKey: Retention.meetingDaysKey)
        guard audioDays > 0 || meetingDays > 0, let modelContext else { return (0, 0) }
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        let items = meetings.map {
            Retention.Item(id: $0.id, date: $0.date,
                           hasAudio: $0.systemAudioPath.nilIfEmpty != nil || $0.micAudioPath?.nilIfEmpty != nil,
                           finished: $0.status == .done || $0.status == .failed)
        }
        let due = Retention.due(items, now: now, audioDays: audioDays, meetingDays: meetingDays)
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in due.meetings {
            if let m = byID[id], !(isRecording && currentMeeting?.id == id) { delete(m) }
        }
        for id in due.audio {
            guard let m = byID[id] else { continue }
            for path in [m.systemAudioPath.nilIfEmpty, m.micAudioPath?.nilIfEmpty].compactMap({ $0 }) {
                try? FileManager.default.removeItem(atPath: path)
            }
            m.systemAudioPath = ""
            m.micAudioPath = nil
        }
        if !due.audio.isEmpty { try? modelContext.save() }
        if !due.audio.isEmpty || !due.meetings.isEmpty {
            NSLog("Parrot: retention removed audio from \(due.audio.count) meeting(s), deleted \(due.meetings.count)")
        }
        return (due.audio.count, due.meetings.count)
    }
}

/// "What left this Mac" for one meeting, from what it recorded about itself.
enum PrivacyLedger {
    /// One line per destination; a single reassuring line when there were none.
    static func lines(onDeviceOnly: Bool, usage: AIUsage?) -> [String] {
        if onDeviceOnly { return ["On-device only: nothing about this call left your Mac."] }
        guard let usage else { return [] }
        var out: [String] = []
        switch usage.transcriptionBackend {
        case TranscriptionBackend.groq.rawValue: out.append("Call audio → Groq, for transcription")
        case TranscriptionBackend.deepgram.rawValue: out.append("Call audio → Deepgram, for transcription")
        default: break
        }
        if usage.polishSeconds > 0 { out.append("Call audio → Groq, for the polish pass") }
        func textLine(_ provider: String?, _ totals: AITokenTotals?, _ job: String) {
            guard let totals, totals.calls > 0 else { return }
            switch provider ?? "claude" {
            case "claude": out.append("Transcript text → Anthropic (Claude), for \(job)")
            case "custom": out.append("Transcript text → your custom AI server, for \(job)")
            default: break   // Ollama: local
            }
        }
        textLine(usage.copilotProvider, usage.copilot, usage.reports == nil ? "the copilot and report" : "the copilot")
        textLine(usage.reportsProvider, usage.reports, "the report")
        if let docs = usage.docAnswers, docs.calls > 0 {
            out.append("Questions + document snippets → TypeSafe AI, for instant answers")
        }
        return out.isEmpty ? ["Nothing about this call left your Mac."] : out
    }
}
