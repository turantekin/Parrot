import Foundation

/// One embedded chunk of a knowledge base document.
struct KBChunk: Codable, Identifiable {
    var id = UUID()
    var documentName: String
    var languageRaw: String
    var text: String
    var embedding: [Double]
    /// The model and revision `embedding` came from; vectors are only ever
    /// compared within one space. nil = no usable vector yet: indexes from
    /// before 0.20 (sentence embeddings) or a model still downloading.
    var space: String?
}

/// Where a folder or document may be used on calls ("Use for").
enum KBScope: Codable, Equatable {
    /// Every call type.
    case all
    /// Only these call types (CallProfile ids).
    case only(Set<UUID>)
    /// Never used on calls.
    case off

    /// Whether a call of this type may use it. `nil` = no call type
    /// (harnesses, back-compat): everything that isn't off.
    func allows(_ callType: UUID?) -> Bool {
        switch self {
        case .all: return true
        case .off: return false
        case .only(let ids): return callType.map { ids.contains($0) } ?? true
        }
    }

    /// The scope after ticking or unticking one call type in the Use for
    /// menu. From `.all` (where no single type shows ticked) a pick means
    /// just that type; none left = off.
    func toggling(_ id: UUID) -> KBScope {
        var ids: Set<UUID>
        switch self {
        case .all, .off: ids = []
        case .only(let current): ids = current
        }
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        return ids.isEmpty ? .off : .only(ids)
    }

    /// A new call type starts with another's documents: a set that has
    /// `source` gets `target` too. Other scopes are unchanged.
    func adding(_ target: UUID, whereHas source: UUID) -> KBScope {
        guard case .only(let ids) = self, ids.contains(source) else { return self }
        return .only(ids.union([target]))
    }
}

/// A group of documents sharing one Use for.
struct KBFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var scope: KBScope = .all
}

/// A document the user added to the knowledge base.
struct KBDocument: Codable, Identifiable {
    var id = UUID()
    var name: String
    /// The About line ("Signed service agreement, Sept 2026"), sent to the
    /// Assistant as the source's user note. Stored under its old key.
    var note: String = ""
    var chunkCount: Int
    var addedAt: Date
    /// Pre-folders call-type tags. Read only to upgrade (`migrated()`).
    var profileIDs: Set<UUID> = []
    /// nil = No folder.
    var folderID: UUID?
    /// nil = Same as folder.
    var scope: KBScope?

    enum CodingKeys: String, CodingKey { case id, name, note, chunkCount, addedAt, profileIDs, folderID, scope }

    init(id: UUID = UUID(), name: String, note: String = "", chunkCount: Int, addedAt: Date,
         profileIDs: Set<UUID> = [], folderID: UUID? = nil, scope: KBScope? = nil) {
        self.id = id
        self.name = name
        self.note = note
        self.chunkCount = chunkCount
        self.addedAt = addedAt
        self.profileIDs = profileIDs
        self.folderID = folderID
        self.scope = scope
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
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        // A scope this build can't read falls back to Same as folder
        // rather than failing the whole index.
        scope = try? c.decodeIfPresent(KBScope.self, forKey: .scope)
    }

    /// `profileIDs` is never written: it exists only to upgrade old indexes.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(note, forKey: .note)
        try c.encode(chunkCount, forKey: .chunkCount)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encodeIfPresent(scope, forKey: .scope)
    }

    /// This document as a pre-folders index upgrades: no folder, its tags
    /// become its own Use for, and no tags (which meant never used on a
    /// call) becomes off. Behaviour is unchanged, only visible now.
    func migrated() -> KBDocument {
        var doc = self
        doc.folderID = nil
        doc.scope = profileIDs.isEmpty ? .off : .only(profileIDs)
        doc.profileIDs = []
        return doc
    }

    /// Its own Use for, else its folder's, else No folder's (all).
    func effectiveScope(in folders: [KBFolder]) -> KBScope {
        scope ?? folders.first { $0.id == folderID }?.scope ?? .all
    }

    /// The file name without a common document extension (the icon shows the type).
    var displayName: String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["md", "markdown", "txt", "text", "pdf"].contains(ext) ? (name as NSString).deletingPathExtension : name
    }
}

/// A retrieved chunk handed to the analysis provider, joined with its
/// document's current note.
struct KBReference {
    let documentName: String
    let note: String?
    let text: String
}
