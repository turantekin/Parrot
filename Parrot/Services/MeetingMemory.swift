import Foundation
import NaturalLanguage
import Observation

/// One searchable piece of a past meeting: a run of transcript lines
/// ("[12:34] Jeremy: …") or a slice of its report.
struct MemoryChunk: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case transcript, report }

    var id = UUID()
    var meetingID: UUID
    var kind: Kind
    /// Call time of the first line (0 for report chunks).
    var start: TimeInterval
    var text: String
    var languageRaw: String
    /// On-device contextual embedding (Float32), empty when none yet.
    var vector: [Float] = []
    /// Model/revision the vector came from; vectors compare within one space.
    var space: String?

    // Vectors as raw Float32 bytes: a JSON number array is ~4x larger, and an
    // hour of calls holds ~60 chunks of 512 floats.
    enum CodingKeys: String, CodingKey { case id, meetingID, kind, start, text, languageRaw, vector, space }

    init(meetingID: UUID, kind: Kind, start: TimeInterval, text: String, languageRaw: String,
         vector: [Float] = [], space: String? = nil) {
        self.meetingID = meetingID
        self.kind = kind
        self.start = start
        self.text = text
        self.languageRaw = languageRaw
        self.vector = vector
        self.space = space
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        meetingID = try c.decode(UUID.self, forKey: .meetingID)
        kind = try c.decode(Kind.self, forKey: .kind)
        start = try c.decode(TimeInterval.self, forKey: .start)
        text = try c.decode(String.self, forKey: .text)
        languageRaw = try c.decodeIfPresent(String.self, forKey: .languageRaw) ?? "en"
        space = try c.decodeIfPresent(String.self, forKey: .space)
        let bytes = try c.decodeIfPresent(Data.self, forKey: .vector) ?? Data()
        vector = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(meetingID, forKey: .meetingID)
        try c.encode(kind, forKey: .kind)
        try c.encode(start, forKey: .start)
        try c.encode(text, forKey: .text)
        try c.encode(languageRaw, forKey: .languageRaw)
        try c.encodeIfPresent(space, forKey: .space)
        try c.encode(vector.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .vector)
    }
}

/// Everything Parrot has heard, searchable on the Mac: every finished
/// meeting's transcript and report, chunked and embedded with the same
/// on-device models as the knowledge base, ranked with the same hybrid
/// (BM25 first, embeddings fill). Nothing here touches the network; Ask
/// Parrot decides separately what, if anything, goes to an AI.
///
/// One small file per meeting under Application Support/Parrot/Memory, so
/// indexing a meeting rewrites one file, and deleting it deletes one.
@MainActor
@Observable
final class MeetingMemory {

    private(set) var chunks: [MemoryChunk] = []
    private(set) var isIndexing = false
    /// meetingID → fingerprint of what was indexed (see `fingerprint`).
    @ObservationIgnored private var fingerprints: [UUID: Int] = [:]
    @ObservationIgnored private var tokenCache: [UUID: [String]] = [:]
    @ObservationIgnored private let directory: URL?

    /// `directory` nil = in-memory only (harness).
    init(directory: URL? = MeetingMemory.defaultDirectory) {
        self.directory = directory
        load()
    }

    nonisolated static var defaultDirectory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot/Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var indexedMeetingIDs: Set<UUID> { Set(fingerprints.keys) }

    // MARK: Pure building blocks (harness-covered)

    /// Changes whenever what we'd index changes: lines landing, a speaker
    /// renamed, a line reassigned or trimmed, the report (re)written.
    nonisolated static func fingerprint(lines: [ReceiptIndex.Line], summary: String?, coaching: String?) -> Int {
        var hasher = Hasher()
        for line in lines {
            hasher.combine(line.start)
            hasher.combine(line.speaker)
            hasher.combine(line.text)
        }
        hasher.combine(summary)
        hasher.combine(coaching)
        return hasher.finalize()
    }

    /// Transcript lines grouped into chunks of up to `maxChars`, each line
    /// written as the model and the user see it ("[12:34] Jeremy: …"), plus
    /// the report split at the same size. Vectors are filled in later.
    nonisolated static func buildChunks(meetingID: UUID, lines: [ReceiptIndex.Line],
                                        summary: String?, coaching: String?,
                                        maxChars: Int = 700) -> [MemoryChunk] {
        var out: [MemoryChunk] = []
        var buffer: [String] = []
        var bufferStart: TimeInterval = 0
        var size = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n")
            out.append(MemoryChunk(meetingID: meetingID, kind: .transcript, start: bufferStart,
                                   text: text, languageRaw: language(of: text)))
            buffer = []
            size = 0
        }

        for line in lines.sorted(by: { $0.start < $1.start }) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let written = "[\(Receipts.stamp(line.start))] \(line.speaker): \(text)"
            if size + written.count > maxChars, !buffer.isEmpty { flush() }
            if buffer.isEmpty { bufferStart = line.start }
            buffer.append(written)
            size += written.count + 1
        }
        flush()

        let report = [summary, coaching].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !report.isEmpty {
            for piece in KnowledgeBaseService.chunkText(report, cap: maxChars) {
                out.append(MemoryChunk(meetingID: meetingID, kind: .report, start: 0,
                                       text: piece, languageRaw: language(of: piece)))
            }
        }
        return out
    }

    nonisolated static func language(of text: String) -> String {
        (NLLanguageRecognizer.dominantLanguage(for: text) ?? .english).rawValue
    }

    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot / (na * nb).squareRoot())
    }

    /// Chunk indices, best first: the knowledge base's hybrid — exact words
    /// (BM25) rank, embeddings fill the reserved slots.
    nonisolated static func rank(queryTokens: [String], chunkTokens: [[String]],
                                 cosine: [Double], topK: Int) -> [Int] {
        let lexical = KnowledgeBaseService.bm25Order(query: queryTokens, documents: chunkTokens)
        let cosineOrder = cosine.indices.filter { cosine[$0] > 0 }.sorted { cosine[$0] > cosine[$1] }
        return KnowledgeBaseService.hybridOrder(lexical: lexical, cosine: cosineOrder, topK: topK)
    }

    // MARK: Indexing

    /// (Re)indexes one finished meeting when its content changed.
    func index(_ meeting: Meeting) async {
        guard meeting.status == .done else { return }
        let lines = meeting.receiptIndex.lines
        let fp = Self.fingerprint(lines: lines, summary: meeting.summary, coaching: meeting.coaching)
        guard fingerprints[meeting.id] != fp else { return }
        let id = meeting.id
        let built = Self.buildChunks(meetingID: id, lines: lines,
                                     summary: meeting.summary, coaching: meeting.coaching)
        isIndexing = true
        let embedded = await Task.detached(priority: .utility) { Self.embed(built) }.value
        isIndexing = false
        replace(meetingID: id, with: embedded, fingerprint: fp)
    }

    /// Indexes every finished meeting that's new or changed, oldest first,
    /// and forgets meetings that no longer exist.
    func sync(with meetings: [Meeting]) async {
        let alive = Set(meetings.map(\.id))
        for gone in Set(fingerprints.keys).subtracting(alive) { remove(meetingID: gone) }
        for meeting in meetings.sorted(by: { $0.date < $1.date }) where meeting.status == .done {
            await index(meeting)
        }
    }

    func remove(meetingID: UUID) {
        for chunk in chunks where chunk.meetingID == meetingID { tokenCache[chunk.id] = nil }
        chunks.removeAll { $0.meetingID == meetingID }
        fingerprints[meetingID] = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(meetingID.uuidString).json"))
        }
    }

    /// Harness seam: index without a SwiftData meeting.
    func replace(meetingID: UUID, with newChunks: [MemoryChunk], fingerprint: Int) {
        for chunk in chunks where chunk.meetingID == meetingID { tokenCache[chunk.id] = nil }
        chunks.removeAll { $0.meetingID == meetingID }
        chunks.append(contentsOf: newChunks)
        fingerprints[meetingID] = fingerprint
        save(meetingID: meetingID, chunks: newChunks, fingerprint: fingerprint)
    }

    private nonisolated static func embed(_ chunks: [MemoryChunk]) -> [MemoryChunk] {
        chunks.map { chunk in
            var c = chunk
            if let result = KnowledgeBaseService.embed(chunk.text, language: NLLanguage(rawValue: chunk.languageRaw)) {
                c.vector = result.vector.map(Float.init)
                c.space = result.space
            }
            return c
        }
    }

    // MARK: Search

    /// Best chunks for `query`, optionally within some meetings and never
    /// from `excluding` (private meetings when the answer goes to a cloud AI).
    func search(_ query: String, within meetingIDs: Set<UUID>? = nil,
                excluding: Set<UUID> = [], topK: Int = 8) async -> [MemoryChunk] {
        let pool = chunks.filter {
            !excluding.contains($0.meetingID) && (meetingIDs?.contains($0.meetingID) ?? true)
        }
        guard !pool.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let tokens = pool.map { chunk -> [String] in
            if let cached = tokenCache[chunk.id] { return cached }
            let t = KnowledgeBaseService.lexicalTokens(chunk.text)
            tokenCache[chunk.id] = t
            return t
        }
        let order = await Task.detached(priority: .userInitiated) { () -> [Int] in
            var queryVectors: [String: [Float]] = [:]
            for raw in Set(pool.map(\.languageRaw)) {
                let language = NLLanguage(rawValue: raw)
                guard let space = KnowledgeBaseService.space(for: language), queryVectors[space] == nil,
                      let v = KnowledgeBaseService.embed(query, language: language) else { continue }
                queryVectors[v.space] = v.vector.map(Float.init)
            }
            let cosine = pool.map { chunk in
                chunk.space.flatMap { queryVectors[$0] }.map { Self.cosine($0, chunk.vector) } ?? 0
            }
            return Self.rank(queryTokens: KnowledgeBaseService.lexicalTokens(query),
                             chunkTokens: tokens, cosine: cosine, topK: topK)
        }.value
        return order.map { pool[$0] }
    }

    // MARK: Persistence

    private struct File: Codable {
        var fingerprint: Int
        var chunks: [MemoryChunk]
    }

    private func load() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data) else {
                // Unreadable: drop it; the next sync re-indexes that meeting.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            chunks.append(contentsOf: file.chunks)
            fingerprints[id] = file.fingerprint
        }
    }

    private func save(meetingID: UUID, chunks: [MemoryChunk], fingerprint: Int) {
        guard let directory else { return }
        let url = directory.appendingPathComponent("\(meetingID.uuidString).json")
        guard let data = try? JSONEncoder().encode(File(fingerprint: fingerprint, chunks: chunks)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
