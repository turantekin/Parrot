import Foundation
import SwiftUI
import SwiftData

struct ProfileKind: Codable, Identifiable, Hashable {
    var id: UUID
    var key: String
    var label: String
    var colorHex: String
    var iconSystemName: String
    var triggerDescription: String
    var isPinned: Bool
    var priority: Int
}

struct SentimentGauge: Codable, Identifiable, Hashable {
    var id: UUID
    var key: String
    var label: String
    var lowLabel: String
    var highLabel: String
    var colorHex: String
}

@Model
final class CallProfile {
    var id: UUID
    var name: String
    var iconSystemName: String
    var summary: String
    var isBuiltIn: Bool
    var sortOrder: Int
    var persona: String
    var tone: String
    var allowGeneralKnowledge: Bool
    /// JSON-encoded [ProfileKind] / [SentimentGauge] — config, not queried entities.
    var kindsData: Data
    var gaugesData: Data

    // NOTE: @Relationship(inverse: \Meeting.profile) var meetings: [Meeting] = [] is
    // intentionally omitted here — Meeting.profile does not exist until Task 9/5.
    // A later task will re-add this backref once the inverse property is in place.

    init(id: UUID = UUID(), name: String, iconSystemName: String, summary: String,
         isBuiltIn: Bool, sortOrder: Int, persona: String, tone: String,
         allowGeneralKnowledge: Bool, kinds: [ProfileKind], gauges: [SentimentGauge]) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.summary = summary
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.persona = persona
        self.tone = tone
        self.allowGeneralKnowledge = allowGeneralKnowledge
        self.kindsData = (try? JSONEncoder().encode(kinds)) ?? Data()
        self.gaugesData = (try? JSONEncoder().encode(gauges)) ?? Data()
    }

    var kinds: [ProfileKind] {
        get { (try? JSONDecoder().decode([ProfileKind].self, from: kindsData)) ?? [] }
        set { kindsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var gauges: [SentimentGauge] {
        get { (try? JSONDecoder().decode([SentimentGauge].self, from: gaugesData)) ?? [] }
        set { gaugesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Profile-defined style for a key, or nil if this profile doesn't define it.
    func style(forKey key: String) -> KindStyle? {
        guard let k = kinds.first(where: { $0.key == key }) else { return nil }
        return KindStyle(label: k.label, color: KindResolver.adaptiveColor(forHex: k.colorHex),
                         iconSystemName: k.iconSystemName, isPinned: k.isPinned)
    }
}
