import Foundation
import NaturalLanguage
import Observation
import PDFKit

/// On-device knowledge base: documents are chunked and embedded locally with the
/// NaturalLanguage framework, then matched against the live conversation by cosine
/// similarity. Documents never leave the Mac: the only download is Apple's own
/// one-time language model for some scripts, and only the few best-matching
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
        if persistent {
            load()
            Task { await refreshEmbeddings() }
        }
    }

    // MARK: - Document Management

    func addDocuments(at urls: [URL]) async {
        isIndexing = true
        lastError = nil
        for url in urls {
            await addDocument(at: url)
        }
        isIndexing = false
        await refreshEmbeddings()
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

        // A chunk without a vector (the language's model is still downloading,
        // or the OS has none) is still indexed: it matches on exact words, and
        // refreshEmbeddings gives it a vector once the model is there.
        let embedded: [KBChunk] = await Task.detached(priority: .userInitiated) {
            pieces.map { piece in
                let vector = Self.embed(piece, language: language)
                return KBChunk(
                    documentName: name,
                    languageRaw: language.rawValue,
                    text: piece,
                    embedding: vector?.vector ?? [],
                    space: vector?.space
                )
            }
        }.value

        guard !embedded.isEmpty else {
            lastError = "No text to index in \(name)"
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

    // MARK: - Snapshot Harness Support

    /// Fake documents for the offscreen renders. Never persisted.
    func seedForSnapshot(documents docs: [KBDocument]) {
        documents = docs
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

    /// Tags every document that is tagged into `source` into `target` as well.
    func copyProfileTags(from source: UUID, to target: UUID) {
        var changed = false
        for i in documents.indices where documents[i].profileIDs.contains(source) {
            documents[i].profileIDs.insert(target)
            changed = true
        }
        if changed { save() }
    }

    /// Returns the names of documents tagged into the given profile ID.
    func documentNames(for profileID: UUID) -> [String] {
        documents.filter { $0.profileIDs.contains(profileID) }.map(\.name)
    }

    /// The documents the copilot can quote on a call: those tagged into the
    /// profile, or every document when there is no profile. Mirrors `search`.
    func documentsInPlay(for profileID: UUID?) -> [String] {
        guard let profileID else { return documents.map(\.name) }
        return documentNames(for: profileID)
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
            // Documents may be in different scripts, each with its own model;
            // embed the query once per model so vectors are always compared
            // within the same space. Latin-script documents (English, Turkish,
            // Spanish...) share one model, so an English question can match a
            // Turkish chunk. A chunk with no current vector scores 0.
            var queryVectors: [String: [Double]] = [:]
            for raw in Set(snapshot.map(\.languageRaw)) {
                let language = NLLanguage(rawValue: raw)
                guard let space = Self.space(for: language), queryVectors[space] == nil,
                      let vector = Self.embed(query, language: language) else { continue }
                queryVectors[vector.space] = vector.vector
            }

            let cosine: [Double] = snapshot.map { chunk in
                chunk.space.flatMap { queryVectors[$0] }.map { Self.cosineSimilarity($0, chunk.embedding) } ?? 0
            }
            // ponytail: no similarity floor. Mean-pooled contextual vectors sit
            // near 0.86 for any pair (2026-09-24 eval: answerable 0.88,
            // off-topic 0.86), so no absolute cut separates them; embedding
            // hits only ever take the reserved third of the slots anyway.
            let cosineOrder = cosine.indices
                .filter { cosine[$0] > 0 }
                .sorted { cosine[$0] > cosine[$1] }

            // Exact words first. Sentence embeddings alone miss most factual
            // questions on a long document (2026-09-19 eval: the answering chunk
            // sat in the cosine top 8 for 14 of 71 questions, in the BM25 top 8
            // for 55), and fusing the two with equal weight was worse than BM25
            // alone. So BM25 ranks, and embeddings only fill the slots exact
            // words did not reach. Chunks with neither signal stay out.
            let lexicalOrder = Self.bm25Order(
                query: Self.lexicalTokens(query),
                documents: snapshot.map { Self.lexicalTokens($0.text) })

            return Self.hybridOrder(lexical: lexicalOrder, cosine: cosineOrder, topK: topK)
                .map { snapshot[$0] }
        }.value

        return best.map { chunk in
            let note = notesByDocument[chunk.documentName]?.nilIfEmpty
            return KBReference(documentName: chunk.documentName, note: note, text: chunk.text)
        }
    }

    // MARK: - Lexical retrieval (BM25 + rank fusion)

    /// English function words: spoken questions are full of them ("what is
    /// the … for this"), and each one matches every chunk a little, which
    /// buried the one chunk with the actual answer (2026-09-19 eval).
    private nonisolated static let lexicalStopWords: Set<String> = [
        "the", "a", "an", "and", "or", "is", "are", "was", "were", "be", "been", "this", "that",
        "these", "those", "what", "which", "how", "much", "many", "do", "does", "did", "i", "you",
        "we", "they", "it", "he", "she", "me", "us", "them", "my", "your", "our", "their", "its",
        "for", "of", "to", "in", "on", "at", "by", "from", "with", "as", "so", "if", "but", "not",
        "no", "any", "some", "can", "could", "will", "would", "should", "shall", "may", "might",
        "about", "into", "over", "under", "than", "then", "there", "here", "when", "where", "who",
        "whom", "whose", "why", "okay", "ok", "yes", "just", "also", "very", "really", "one",
        "thing", "things",
    ]

    /// Lowercased alphanumeric tokens of two or more characters, minus
    /// function words; alphabetic tokens longer than five keep their first
    /// five letters, a cheap stem so "verification" and "verified" meet.
    /// Numbers stay whole ("99", "2026").
    nonisolated static func lexicalTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !lexicalStopWords.contains($0) }
            .map { token in
                token.count > 5 && token.allSatisfy(\.isLetter) ? String(token.prefix(5)) : token
            }
    }

    /// Exact-word matches first, in BM25 order, with a third of the slots
    /// (at least one, none below three) reserved for the top embedding
    /// matches, then whatever is left fills. Equal-weight fusion was measured
    /// worse than BM25 alone (answer in the top 4 for 32 vs 47 of 71
    /// questions): the sentence embeddings rank near noise on factual
    /// questions yet outvoted a lone exact-word hit. The reserve exists for
    /// questions that share no words with their answer ("how much does it
    /// cost" against "Launchese fee $11.99"), where words cannot help at all.
    nonisolated static func hybridOrder(lexical: [Int], cosine: [Int], topK: Int) -> [Int] {
        let reserve = topK >= 3 ? max(1, topK / 3) : 0
        var seen = Set<Int>()
        var order: [Int] = []
        func take(_ candidates: [Int], upTo limit: Int) {
            for index in candidates where !seen.contains(index) && order.count < limit {
                seen.insert(index)
                order.append(index)
            }
        }
        take(lexical, upTo: topK - reserve)
        take(cosine, upTo: order.count + reserve)
        take(lexical, upTo: topK)
        take(cosine, upTo: topK)
        return order
    }

    /// Document indices ordered by BM25 score for the query tokens (k1 = 1.2,
    /// b = 0.75); documents sharing no term with the query are left out.
    nonisolated static func bm25Order(query: [String], documents: [[String]]) -> [Int] {
        guard !query.isEmpty, !documents.isEmpty else { return [] }
        let n = Double(documents.count)
        let averageLength = documents.reduce(0) { $0 + Double($1.count) } / n
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in Set(document) { documentFrequency[term, default: 0] += 1 }
        }
        let k1 = 1.2, b = 0.75
        var scored: [(index: Int, score: Double)] = []
        for (index, document) in documents.enumerated() {
            var counts: [String: Int] = [:]
            for term in document { counts[term, default: 0] += 1 }
            var score = 0.0
            for term in query {
                guard let count = counts[term] else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let tf = Double(count)
                score += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * Double(document.count) / averageLength))
            }
            if score > 0 { scored.append((index, score)) }
        }
        return scored.sorted { $0.score > $1.score }.map(\.index)
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
    /// Markdown headings are glued onto the paragraph that follows them and
    /// "---" separators are dropped, so a chunk is never a bare heading (the
    /// 2026-09-19 eval found Jev rating "## 17. How Launchese works" at 0.66
    /// for a price question). A paragraph over the cap, typically a table or
    /// a long list, is split on its lines and every piece carries the section
    /// heading, so "### Close a company (£75)" stays with its rows.
    nonisolated static func chunkText(_ text: String, cap: Int = 900) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "---" }

        var result: [String] = []
        var current = ""
        var heading: String?   // waiting to be glued onto the next paragraph
        var section: String?   // last heading seen; prefixed onto split pieces
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = ""
        }
        for paragraph in paragraphs {
            // A bare heading waits for its paragraph. One that merely starts
            // with a heading line is body text: PDF text keeps single
            // newlines, so a whole page can arrive as one "paragraph", and
            // skipping it left such a PDF with no chunks at all.
            if paragraph.hasPrefix("#") {
                section = String(paragraph.prefix { $0 != "\n" })
                if section == paragraph {
                    heading = paragraph
                    continue
                }
            }
            var piece = paragraph
            if let pending = heading {
                piece = pending + "\n" + piece
                heading = nil
            }
            if piece.count > cap {
                flush()
                let prefix = section.map { $0 + "\n" } ?? ""
                var part = prefix
                for line in piece.split(separator: "\n").map(String.init) where line != section {
                    if part.count + line.count > cap, part != prefix {
                        result.append(part.trimmingCharacters(in: .whitespacesAndNewlines))
                        part = prefix
                    }
                    part += line + "\n"
                }
                if part != prefix { result.append(part.trimmingCharacters(in: .whitespacesAndNewlines)) }
                continue
            }
            if current.count + piece.count > cap, !current.isEmpty { flush() }
            current += current.isEmpty ? piece : "\n\n" + piece
        }
        flush()
        return result.filter { $0.count >= 40 }
    }

    // MARK: - Embedding

    /// Re-embeds every chunk whose vector is missing or from another model:
    /// indexes from before 0.20 (sentence embeddings), documents added while
    /// their language's model was downloading, and OS updates that ship a new
    /// model revision. Until then search skips those vectors and the chunks
    /// match on exact words, so results stay correct meanwhile.
    func refreshEmbeddings() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Apple's one-time model download for a language (Cyrillic, Arabic,
        // Indic scripts on a fresh Mac). On-device after that; documents are
        // never uploaded. Can take minutes, so nothing waits on it but this.
        for raw in Set(chunks.filter { $0.space == nil }.map(\.languageRaw)) {
            if let model = NLContextualEmbedding(language: NLLanguage(rawValue: raw)), !model.hasAvailableAssets {
                _ = try? await model.requestAssets()
            }
        }

        let stale = chunks.filter { chunk in
            guard let current = Self.space(for: NLLanguage(rawValue: chunk.languageRaw)) else { return false }
            return chunk.space != current
        }
        guard !stale.isEmpty else { return }
        let refreshed: [UUID: KBChunk] = await Task.detached(priority: .utility) {
            var out: [UUID: KBChunk] = [:]
            for var chunk in stale {
                guard let vector = Self.embed(chunk.text, language: NLLanguage(rawValue: chunk.languageRaw)) else { continue }
                chunk.embedding = vector.vector
                chunk.space = vector.space
                out[chunk.id] = chunk
            }
            return out
        }.value
        // By id: a document removed or re-added meanwhile keeps its new state.
        for i in chunks.indices {
            if let chunk = refreshed[chunks[i].id] { chunks[i] = chunk }
        }
        save()
    }

    private var isRefreshing = false

    // ponytail: one global lock around every model call. Embedding is CPU
    // bound and the docs don't promise NLContextualEmbedding is thread-safe.
    private nonisolated static let embeddingLock = NSLock()
    private nonisolated(unsafe) static var models: [String: NLContextualEmbedding] = [:]

    /// The loaded model for a language; nil when the OS has none for it or
    /// its assets aren't downloaded yet. Caller holds `embeddingLock`.
    private nonisolated static func loadedModel(for language: NLLanguage) -> NLContextualEmbedding? {
        if let model = models[language.rawValue] { return model }
        guard let model = NLContextualEmbedding(language: language), model.hasAvailableAssets,
              (try? model.load()) != nil else { return nil }
        models[language.rawValue] = model
        return model
    }

    /// The vector space a language embeds into right now, if any.
    nonisolated static func space(for language: NLLanguage) -> String? {
        embeddingLock.lock()
        defer { embeddingLock.unlock() }
        return loadedModel(for: language).map { "\($0.modelIdentifier)/\($0.revision)" }
    }

    /// Mean of the token vectors from Apple's on-device contextual embedding
    /// (NaturalLanguage, macOS 14+). It replaced NLEmbedding.sentenceEmbedding,
    /// which exists only for English, Spanish, German, French, Italian and
    /// Portuguese; this has one model for 20+ Latin-script languages (Turkish,
    /// Dutch, Polish, Swedish...) plus Cyrillic, Arabic, CJK and Indic models,
    /// and ranked answers higher even in English (2026-09-24 eval, cosine top
    /// 8: 10/30 vs 4/30). The model reads 256 tokens and drops the rest, so
    /// long text is embedded in sentence windows and pooled across them.
    nonisolated static func embed(_ text: String, language: NLLanguage) -> (vector: [Double], space: String)? {
        embeddingLock.lock()
        defer { embeddingLock.unlock() }
        guard let model = loadedModel(for: language) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        for window in embeddingWindows(text) {
            guard let result = try? model.embeddingResult(for: window, language: nil) else { continue }
            result.enumerateTokenVectors(in: window.startIndex..<window.endIndex) { vector, _ in
                for i in vector.indices { sum[i] += vector[i] }
                count += 1
                return true
            }
        }
        guard count > 0 else { return nil }
        return (sum.map { $0 / Double(count) }, "\(model.modelIdentifier)/\(model.revision)")
    }

    /// Consecutive sentences joined up to `cap` characters, well under the
    /// model's 256 tokens (Turkish ran ~3.3 characters a token).
    nonisolated static func embeddingWindows(_ text: String, cap: Int = 400) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var windows: [String] = []
        var current = ""
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            if !current.isEmpty, current.count + sentence.count > cap {
                windows.append(current)
                current = ""
            }
            current += sentence
            return true
        }
        if !current.isEmpty { windows.append(current) }
        return windows
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
        // Dev harnesses point this at the sandboxed app's real index
        // (~/Library/Containers/com.uygar.parrot/…/KnowledgeBase/index.json)
        // so --kb-add / --doc-answer-eval work on what the app actually uses.
        if let override = ProcessInfo.processInfo.environment["PARROT_KB_INDEX"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot/KnowledgeBase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        do {
            let store = try JSONDecoder().decode(Store.self, from: data)
            documents = store.documents
            chunks = store.chunks
        } catch {
            // The index exists but doesn't decode. Starting with an empty KB is
            // fine; silently OVERWRITING the broken index on the next save is
            // not — move it aside so the data stays recoverable.
            let stamp = ISO8601DateFormatter().string(from: .now)
                .replacingOccurrences(of: ":", with: "-")
            let backup = Self.storeURL.deletingLastPathComponent()
                .appendingPathComponent("index-corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: Self.storeURL, to: backup)
            NSLog("Parrot: knowledge base index failed to decode (\(error.localizedDescription)) — moved aside to \(backup.lastPathComponent)")
        }
    }

    private func save() {
        guard persistent else { return }
        guard let data = try? JSONEncoder().encode(Store(documents: documents, chunks: chunks)) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
