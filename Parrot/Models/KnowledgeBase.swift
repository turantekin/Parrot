import Foundation

/// One embedded chunk of a knowledge base document.
struct KBChunk: Codable, Identifiable {
    var id = UUID()
    var documentName: String
    var languageRaw: String
    var text: String
    var embedding: [Double]
}

/// A document the user added to the knowledge base.
struct KBDocument: Codable, Identifiable {
    var id = UUID()
    var name: String
    /// User guidance for when to use this document, e.g. "use for pricing questions".
    var note: String = ""
    var chunkCount: Int
    var addedAt: Date
    /// Profiles this document is tagged into. Empty = unscoped (all-profiles).
    var profileIDs: Set<UUID> = []

    enum CodingKeys: String, CodingKey { case id, name, note, chunkCount, addedAt, profileIDs }

    init(id: UUID = UUID(), name: String, note: String = "", chunkCount: Int, addedAt: Date, profileIDs: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.note = note
        self.chunkCount = chunkCount
        self.addedAt = addedAt
        self.profileIDs = profileIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Fields added after 1.0 decode leniently (decodeIfPresent + default):
        // a strict decode of a missing key fails the WHOLE store load, and the
        // next save would then overwrite the store with empty — total KB loss.
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        chunkCount = try c.decode(Int.self, forKey: .chunkCount)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        profileIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .profileIDs) ?? []
    }
}

/// A retrieved chunk handed to the analysis provider, joined with its
/// document's current note.
struct KBReference {
    let documentName: String
    let note: String?
    let text: String
}
