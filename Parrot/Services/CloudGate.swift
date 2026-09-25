import Foundation

/// The one switch every path that could send meeting data off the Mac asks
/// first. "On-device only" is on when the user turns it on globally
/// (Settings → Privacy), or while a call recorded under a profile marked
/// on-device only is live or still being processed (its report, its
/// after-call actions).
///
/// While it's on: the copilot and reports run on Ollama, transcription runs
/// on Whisper, no polish pass, no TypeSafe excerpts, no webhook. Meetings
/// recorded under it are flagged (`Meeting.onDeviceOnly`) and stay out of
/// every later cloud path too: Ask Parrot with a cloud brain, the follow-up
/// email, the webhook, and the AI-app (MCP) connection.
enum CloudGate {

    static let globalKey = "onDeviceOnly"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var holds = Set<UUID>()

    /// True when nothing may go to a cloud service right now.
    static var forcesLocal: Bool {
        if UserDefaults.standard.bool(forKey: globalKey) { return true }
        return lock.withLock { !holds.isEmpty }
    }

    /// Keeps everything local while this meeting records and processes.
    static func hold(_ meetingID: UUID) {
        _ = lock.withLock { holds.insert(meetingID) }
    }

    static func release(_ meetingID: UUID) {
        _ = lock.withLock { holds.remove(meetingID) }
    }

    /// Harness reset.
    static func releaseAll() {
        lock.withLock { holds.removeAll() }
    }

    /// Whether this meeting's content may go to a cloud service at all
    /// (Ask with a cloud brain, follow-up email, webhook, MCP).
    static func mayLeaveMac(_ meeting: Meeting) -> Bool {
        !meeting.onDeviceOnly && !UserDefaults.standard.bool(forKey: globalKey)
    }
}
