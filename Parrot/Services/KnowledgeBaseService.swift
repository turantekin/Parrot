import Foundation
import NaturalLanguage
import Observation
import PDFKit

/// On-device knowledge base: documents are chunked and embedded locally with the
/// NaturalLanguage framework, then matched against the live conversation by cosine
/// similarity. Nothing here ever touches the network — only the few best-matching
/// chunks are later included in copilot API calls.
@MainActor
@Observable
final class KnowledgeBaseService {
    private(set) var documents: [KBDocument] = []
    private(set) var isIndexing = false
    private(set) var lastError: String?

    private var chunks: [KBChunk] = []

    var isEmpty: Bool { documents.isEmpty }

    private let persistent: Bool

    init(persistent: Bool = true) {
        self.persistent = persistent
        if persistent { load() }
    }

    // MARK: - Document Management

    func addDocuments(at urls: [URL]) async {
        isIndexing = true
        lastError = nil
        for url in urls {
            await addDocument(at: url)
        }
        isIndexing = false
    }

    private func addDocument(at url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let name = url.lastPathComponent
        guard let text = Self.extractText(from: url), !text.isEmpty else {
            lastError = "Couldn't read \(name)"
            return
        }

        let pieces = Self.chunkText(text)
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english

        let embedded: [KBChunk] = await Task.detached(priority: .userInitiated) {
            pieces.compactMap { piece in
                guard let vector = Self.embed(piece, language: language) else { return nil }
                return KBChunk(
                    documentName: name,
                    languageRaw: language.rawValue,
                    text: piece,
                    embedding: vector
                )
            }
        }.value

        guard !embedded.isEmpty else {
            lastError = "No embeddable text in \(name) — the document language may not be supported on this Mac"
            return
        }

        // Re-adding a document replaces its previous version, keeping its note.
        let existingNote = documents.first { $0.name == name }?.note ?? ""
        chunks.removeAll { $0.documentName == name }
        documents.removeAll { $0.name == name }
        chunks.append(contentsOf: embedded)
        documents.append(KBDocument(name: name, note: existingNote, chunkCount: embedded.count, addedAt: .now))
        save()
    }

    func removeDocument(_ document: KBDocument) {
        documents.removeAll { $0.id == document.id }
        chunks.removeAll { $0.documentName == document.name }
        save()
    }

    func updateNote(_ note: String, for document: KBDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index].note = note
        save()
    }

    // MARK: - Profile Scoping

    /// Tags every document in the KB into the given profile ID.
    func tagAllDocuments(into id: UUID) {
        for i in documents.indices { documents[i].profileIDs.insert(id) }
        save()
    }

    /// Replaces the full set of profile tags for a document.
    func setProfiles(_ ids: Set<UUID>, for document: KBDocument) {
        guard let i = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[i].profileIDs = ids
        save()
    }

    /// Returns the names of documents tagged into the given profile ID.
    func documentNames(for profileID: UUID) -> [String] {
        documents.filter { $0.profileIDs.contains(profileID) }.map(\.name)
    }

    // MARK: - Retrieval

    /// Returns the best-matching chunks for the recent conversation, joined with
    /// each document's current note. Pass `profileID` to restrict to documents
    /// tagged into that profile; `nil` searches all (back-compat).
    func search(query: String, profileID: UUID? = nil, topK: Int = 4) async -> [KBReference] {
        guard !chunks.isEmpty, !query.isEmpty else { return [] }

        // Restrict to documents tagged into this profile (nil = all, back-compat).
        let allowedNames: Set<String>? = profileID.map { id in
            Set(documents.filter { $0.profileIDs.contains(id) }.map(\.name))
        }
        let snapshot = allowedNames.map { names in chunks.filter { names.contains($0.documentName) } } ?? chunks
        guard !snapshot.isEmpty else { return [] }
        let notesByDocument = Dictionary(
            documents.map { ($0.name, $0.note) },
            uniquingKeysWith: { first, _ in first }
        )

        let best: [KBChunk] = await Task.detached(priority: .userInitiated) {
            // Documents may be in different languages; embed the query once per
            // language so vectors are always compared within the same space.
            let languages = Set(snapshot.map(\.languageRaw))
            var queryVectors: [String: [Double]] = [:]
            for raw in languages {
                queryVectors[raw] = Self.embed(query, language: NLLanguage(rawValue: raw))
            }

            let scored: [(KBChunk, Double)] = snapshot.compactMap { chunk in
                guard let queryVector = queryVectors[chunk.languageRaw] else { return nil }
                return (chunk, Self.cosineSimilarity(queryVector, chunk.embedding))
            }

            return scored
                .filter { $0.1 > 0.3 }
                .sorted { $0.1 > $1.1 }
                .prefix(topK)
                .map(\.0)
        }.value

        return best.map { chunk in
            let note = notesByDocument[chunk.documentName]?.nilIfEmpty
            return KBReference(documentName: chunk.documentName, note: note, text: chunk.text)
        }
    }

    // MARK: - Text Extraction & Chunking

    private nonisolated static func extractText(from url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.string
        }
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    /// Splits text into ~900-character chunks along paragraph boundaries.
    private nonisolated static func chunkText(_ text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if current.count + paragraph.count > 900, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? paragraph : "\n\n" + paragraph
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result.filter { $0.count >= 40 }
    }

    // MARK: - Embedding

    private nonisolated static func embed(_ text: String, language: NLLanguage) -> [Double]? {
        let embedding = NLEmbedding.sentenceEmbedding(for: language)
            ?? NLEmbedding.sentenceEmbedding(for: .english)
        return embedding?.vector(for: text)
    }

    private nonisolated static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / ((normA * normB).squareRoot())
    }

    // MARK: - Persistence

    private struct Store: Codable {
        var documents: [KBDocument]
        var chunks: [KBChunk]
    }

    private static var storeURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot/KnowledgeBase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        documents = store.documents
        chunks = store.chunks
    }

    private func save() {
        guard persistent else { return }
        guard let data = try? JSONEncoder().encode(Store(documents: documents, chunks: chunks)) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
