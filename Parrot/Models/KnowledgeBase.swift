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
}

/// A retrieved chunk handed to the analysis provider, joined with its
/// document's current note.
struct KBReference {
    let documentName: String
    let note: String?
    let text: String
}
