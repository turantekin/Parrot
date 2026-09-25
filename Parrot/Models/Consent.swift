import Foundation

/// How the other side of a call was told it's recorded. Kept with the
/// meeting and shown in the report and exports — a record, not legal advice.
struct Consent: Codable, Equatable {
    enum Method: String, Codable {
        /// The notice was copied to paste into the call chat.
        case noticeShared
        /// The user marked that everyone agreed out loud.
        case verbal
    }

    var method: Method
    /// Call time it happened, seconds.
    var at: TimeInterval
    /// The notice text as shared, for `noticeShared`.
    var notice: String?

    var summary: String {
        switch method {
        case .noticeShared: "recording notice shared at \(Receipts.stamp(at))"
        case .verbal: "everyone agreed out loud at \(Receipts.stamp(at))"
        }
    }

    static let noticeKey = "consentNotice"
    static let remindKey = "consentReminder"

    static let defaultNotice = "Heads-up: I'm recording this call with Parrot so I can take notes. It runs on my own Mac. Tell me if you'd rather I didn't."

    /// The user's notice text, or the default.
    static var currentNotice: String {
        let saved = UserDefaults.standard.string(forKey: noticeKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultNotice : saved
    }
}
