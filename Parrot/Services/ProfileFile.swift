import AppKit
import Foundation

/// The portable profile format (`.parrotprofile`): UTF-8 JSON, at most
/// 64 KB. Spec and limits: docs/superpowers/plans/2026-09-26-profiles-share-suggest-gallery.md.
/// Today `get_profile` emits it; import and export come with Profiles 2.0.
///
/// Never in a file: meeting content, names from calls, knowledge-base
/// documents, local ids, API keys, settings outside the profile. Nothing in
/// a file can turn on-device only off. Fields this Parrot doesn't know are
/// kept (see `data()`), so a newer file passes through an older Parrot intact.
struct ProfileFile: Codable {

    static let formatName = "parrot.profile"
    static let formatVersion = 1
    static let maxBytes = 64 * 1024

    var format = ProfileFile.formatName
    var formatVersion = ProfileFile.formatVersion
    /// Identifies the profile across Macs for life; nil for a profile made on
    /// this Mac until Profiles 2.0 gives CallProfile its own.
    var sharedID: UUID?
    var version: Int
    var profile: Profile
    var privacy: Privacy?
    var meta: Meta?
    var suggestion: Suggestion?

    /// The JSON this was decoded from, for unknown fields.
    private var raw: Data?

    enum CodingKeys: String, CodingKey {
        case format, formatVersion, sharedID, version, profile, privacy, meta, suggestion
    }

    struct Profile: Codable, Equatable {
        var name: String
        var icon: String
        var summary: String
        var persona: String
        var tone: String
        var counterpart: String
        var allowGeneralKnowledge: Bool
        var kinds: [Kind]
        var gauges: [Gauge]
        /// nil = the Default report, word for word as today.
        var report: Report?
    }

    struct Kind: Codable, Equatable {
        var key, label, color, icon, trigger: String
        var pinned: Bool
        var priority: Int
    }

    struct Gauge: Codable, Equatable {
        var key, label, low, high, color: String
    }

    struct Report: Codable, Equatable {
        var sections: [Section]
        var coaching: Coaching?
    }

    struct Section: Codable, Equatable {
        var key, title, type: String
        var guide: String?
        /// Bullets must be things someone said; they feed list_commitments.
        var commitments: Bool?
        var criteria: [Criterion]?
    }

    struct Criterion: Codable, Equatable {
        var key, label: String
        var guide: String?
    }

    struct Coaching: Codable, Equatable {
        var enabled: Bool
        var role: String?
        var focus: String?
    }

    struct Privacy: Codable, Equatable {
        var recommendOnDeviceOnly: Bool
    }

    struct Meta: Codable, Equatable {
        var description, author, authorURL, language, category: String?
        var tags: [String]?
        var license: String?
        /// "user", "claude", "gallery" or "builtin".
        var source: String?
        var basedOn: BasedOn?
        var createdWith: String?
    }

    struct BasedOn: Codable, Equatable {
        var sharedID: UUID
        var version: Int
    }

    struct Suggestion: Codable, Equatable {
        var targetSharedID: UUID?
        var reason: String?
    }

    struct Refused: Error, Equatable {
        let reason: String
    }

    // MARK: Encode

    /// The profile as a file. A built-in the user never tuned keeps its fixed
    /// id and preset version; a tuned one says what it's based on.
    static func encode(_ p: CallProfile, source: String? = nil) -> Data {
        let pristine = p.isBuiltIn && !p.isUserModified
        let file = ProfileFile(
            sharedID: pristine ? p.id : nil,
            version: pristine ? p.presetVersion : 1,
            profile: Profile(
                name: p.name, icon: p.iconSystemName, summary: p.summary, persona: p.persona, tone: p.tone,
                counterpart: p.counterpart, allowGeneralKnowledge: p.allowGeneralKnowledge,
                kinds: p.kinds.map {
                    Kind(key: $0.key, label: $0.label, color: $0.colorHex, icon: $0.iconSystemName,
                         trigger: $0.triggerDescription, pinned: $0.isPinned, priority: $0.priority)
                },
                gauges: p.gauges.map {
                    Gauge(key: $0.key, label: $0.label, low: $0.lowLabel, high: $0.highLabel, color: $0.colorHex)
                },
                report: nil),
            privacy: Privacy(recommendOnDeviceOnly: p.onDeviceOnly),
            meta: Meta(source: source ?? (pristine ? "builtin" : "user"),
                       basedOn: p.isBuiltIn && !pristine ? BasedOn(sharedID: p.id, version: p.presetVersion) : nil,
                       createdWith: "Parrot \(AppUpdater.currentVersion)"))
        return file.data()
    }

    /// Pretty JSON, with any unknown fields from the decoded file put back.
    /// ponytail: a known field set to nil after decoding comes back from the
    /// original; clear `raw` if an editor ever needs to remove one.
    func data() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let typed = try? encoder.encode(self) else { return Data() }
        guard let raw, let original = try? JSONSerialization.jsonObject(with: raw),
              let known = try? JSONSerialization.jsonObject(with: typed),
              let merged = try? JSONSerialization.data(withJSONObject: Self.merge(original, known),
                                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return typed }
        return merged
    }

    /// `known` wins; keys only `original` has are kept, at every depth.
    private static func merge(_ original: Any, _ known: Any) -> Any {
        if let o = original as? [String: Any], let k = known as? [String: Any] {
            var out = o
            for (key, value) in k { out[key] = o[key].map { merge($0, value) } ?? value }
            return out
        }
        if let o = original as? [Any], let k = known as? [Any], o.count == k.count {
            return zip(o, k).map { merge($0, $1) }
        }
        return known
    }

    // MARK: Decode

    static let defaultColor = "5F6470"
    static let defaultKindIcon = "circle.fill"
    static let defaultProfileIcon = "person.wave.2"

    /// Reads a file, refusing one that breaks a limit with a plain reason.
    /// A bad color or an unknown symbol isn't worth refusing: it gets a default.
    static func decode(_ data: Data) throws -> ProfileFile {
        guard data.count <= maxBytes else { throw Refused(reason: "The file is bigger than 64 KB.") }
        guard var file = try? JSONDecoder().decode(ProfileFile.self, from: data) else {
            throw Refused(reason: "This isn't a Parrot profile, or it's damaged.")
        }
        guard file.format == formatName else { throw Refused(reason: "This isn't a Parrot profile.") }
        guard file.formatVersion <= formatVersion else { throw Refused(reason: "This profile needs a newer Parrot.") }
        try file.checkLimits()
        file.profile.icon = symbol(file.profile.icon, or: defaultProfileIcon)
        for i in file.profile.kinds.indices {
            file.profile.kinds[i].color = hex(file.profile.kinds[i].color)
            file.profile.kinds[i].icon = symbol(file.profile.kinds[i].icon, or: defaultKindIcon)
        }
        for i in file.profile.gauges.indices { file.profile.gauges[i].color = hex(file.profile.gauges[i].color) }
        file.raw = data
        return file
    }

    private func checkLimits() throws {
        func text(_ value: String?, _ what: String, max: Int = 300) throws {
            guard (value ?? "").count <= max else { throw Refused(reason: "\(what) is longer than \(max) characters.") }
        }
        let p = profile
        guard !p.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Refused(reason: "The profile has no name.") }
        try text(p.name, "The name")
        try text(p.icon, "The icon")
        try text(p.summary, "The summary")
        try text(p.counterpart, "The other side's name")
        try text(p.persona, "The persona", max: 4000)
        try text(p.tone, "The tone", max: 4000)
        guard p.kinds.count <= 20 else { throw Refused(reason: "A profile can have at most 20 card types.") }
        guard p.gauges.count <= 6 else { throw Refused(reason: "A profile can have at most 6 gauges.") }
        for k in p.kinds {
            for (value, what) in [(k.key, "A card key"), (k.label, "A card name"), (k.color, "A card color"),
                                  (k.icon, "A card icon"), (k.trigger, "A card's trigger")] { try text(value, what) }
        }
        for g in p.gauges {
            for (value, what) in [(g.key, "A gauge key"), (g.label, "A gauge name"), (g.low, "A gauge label"),
                                  (g.high, "A gauge label"), (g.color, "A gauge color")] { try text(value, what) }
        }
        if let report = p.report {
            guard report.sections.count <= 8 else { throw Refused(reason: "A report can have at most 8 sections.") }
            for s in report.sections {
                guard ["prose", "bullets", "scorecard"].contains(s.type) else {
                    throw Refused(reason: "Section \"\(s.title)\" has an unknown type.")
                }
                try text(s.key, "A section key")
                try text(s.title, "A section title")
                try text(s.guide, "A section guide")
                if s.type == "scorecard" {
                    let criteria = s.criteria ?? []
                    guard (1...8).contains(criteria.count) else {
                        throw Refused(reason: "A scorecard needs 1 to 8 criteria.")
                    }
                    for c in criteria {
                        try text(c.key, "A criterion key")
                        try text(c.label, "A criterion name")
                        try text(c.guide, "A criterion guide")
                    }
                }
            }
            try text(report.coaching?.role, "The coaching role")
            try text(report.coaching?.focus, "The coaching focus")
        }
        try text(suggestion?.reason, "The suggestion's reason", max: 4000)
    }

    private static func hex(_ raw: String) -> String {
        let h = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        return h.count == 6 && h.allSatisfy(\.isHexDigit) ? h : defaultColor
    }

    private static func symbol(_ name: String, or fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? fallback : name
    }
}
