import Foundation

/// The one switch every path that could send meeting data off the Mac asks
/// first. On-device only is either:
///
/// - global — Settings → Privacy, for every call; or
/// - scoped to one meeting's work: the post-call chain of a meeting recorded
///   under an on-device-only profile runs inside `CloudGate.$scopeLocal`,
///   so its report, follow-up email and after-call actions route locally
///   while an unrelated call recording at the same time is unaffected. The
///   live call itself passes the flag explicitly (TranscriptionEngine,
///   CallAnalysisEngine), since audio callbacks don't carry task-locals.
///
/// While it's on: copilot and reports run on Ollama, transcription on
/// Whisper, no polish pass, no TypeSafe excerpts, no webhook. Meetings
/// recorded under it are flagged (`Meeting.onDeviceOnly`) and stay out of
/// every later cloud path too: Ask Parrot with a cloud brain, the follow-up
/// email on a cloud brain, the webhook, the last-call brief of a cloud
/// call, and the AI-app (MCP) connection.
enum CloudGate {

    static let globalKey = "onDeviceOnly"

    /// Work for a private meeting in progress on this task tree.
    @TaskLocal static var scopeLocal = false

    /// True when nothing may go to a cloud service from here.
    static var forcesLocal: Bool {
        scopeLocal || UserDefaults.standard.bool(forKey: globalKey)
    }

    /// Whether this meeting's content may go to a cloud service at all.
    static func mayLeaveMac(_ meeting: Meeting) -> Bool {
        !meeting.onDeviceOnly && !UserDefaults.standard.bool(forKey: globalKey)
    }
}
