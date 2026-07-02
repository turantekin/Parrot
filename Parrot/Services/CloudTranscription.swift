import Foundation

/// Cloud transcription backends (bring-your-own-key). On-device Whisper stays
/// the default and the always-available fallback; these exist for users who
/// trade "audio never leaves the Mac" for accuracy (Groq) or latency (Deepgram).
enum TranscriptionBackend: String, CaseIterable {
    /// On-device WhisperKit — private, free (default).
    case local
    /// Groq-hosted whisper-large-v3-turbo — same chunk cadence as local, big-model
    /// accuracy, ~$0.04 per audio hour.
    case groq
    /// Deepgram Nova-3 streaming — word-by-word, ~300 ms latency.
    case deepgram

    static let defaultsKey = "transcriptionBackend"

    static var selected: TranscriptionBackend {
        TranscriptionBackend(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .local
    }

    var label: String {
        switch self {
        case .local: "On-device Whisper"
        case .groq: "Groq cloud"
        case .deepgram: "Deepgram cloud"
        }
    }

    /// Keychain account holding this backend's API key (nil = no key needed).
    var keychainAccount: String? {
        switch self {
        case .local: nil
        case .groq: "groq-api-key"
        case .deepgram: "deepgram-api-key"
        }
    }
}

enum CloudTranscriptionError: LocalizedError {
    case missingKey
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "No API key set for the selected transcription engine."
        case .badResponse(let message): message
        }
    }
}

// MARK: - Groq (OpenAI-compatible audio transcription)

enum GroqTranscriber {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let model = "whisper-large-v3-turbo"

    /// Transcribe one PCM chunk (16 kHz mono floats). Same cadence as the local
    /// loop — only the decode moves to Groq.
    static func transcribe(samples: [Float], language: String?, apiKey: String) async throws -> String {
        struct Response: Decodable { let text: String }
        let data = try await post(fileData: WAVEncoder.encode(samples: samples, sampleRate: 16000),
                                  fileName: "chunk.wav",
                                  fields: fields(language: language, responseFormat: "json"),
                                  apiKey: apiKey)
        return try JSONDecoder().decode(Response.self, from: data).text
    }

    /// Transcribe a whole audio file (the post-call polish pass) with segment
    /// timestamps. Returns (text, start, end) tuples in file-relative seconds.
    static func transcribeFile(_ fileData: Data, fileName: String, language: String?,
                               apiKey: String) async throws -> [(text: String, start: Double, end: Double)] {
        struct Segment: Decodable { let text: String; let start: Double; let end: Double }
        struct Response: Decodable { let segments: [Segment]? }
        let data = try await post(fileData: fileData, fileName: fileName,
                                  fields: fields(language: language, responseFormat: "verbose_json"),
                                  apiKey: apiKey)
        let segments = try JSONDecoder().decode(Response.self, from: data).segments ?? []
        return segments.map { ($0.text, $0.start, $0.end) }
    }

    private static func fields(language: String?, responseFormat: String) -> [(String, String)] {
        var fields = [("model", model), ("response_format", responseFormat)]
        if let language, language != "auto" { fields.append(("language", language)) }
        return fields
    }

    private static func post(fileData: Data, fileName: String,
                             fields: [(String, String)], apiKey: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        let boundary = "parrot-\(UUID().uuidString)"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Multipart.body(boundary: boundary, fields: fields,
                                          file: (name: "file", fileName: fileName,
                                                 mimeType: "audio/wav", data: fileData))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.badResponse("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw CloudTranscriptionError.badResponse("Groq HTTP \(http.statusCode): \(detail)")
        }
        return data
    }
}

// MARK: - Multipart form encoding

enum Multipart {
    static func body(boundary: String, fields: [(String, String)],
                     file: (name: String, fileName: String, mimeType: String, data: Data)) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.fileName)\"\r\n")
        append("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}

// MARK: - WAV encoding

enum WAVEncoder {
    /// Minimal 16-bit PCM mono WAV wrapper around float samples (-1…1).
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var out = Data(capacity: 44 + dataSize)

        func append(_ s: String) { out.append(Data(s.utf8)) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)                              // PCM chunk size
        append16(1)                               // PCM format
        append16(1)                               // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))          // byte rate
        append16(2)                               // block align
        append16(16)                              // bits per sample
        append("data")
        append32(UInt32(dataSize))

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        pcm.withUnsafeBufferPointer { ptr in
            out.append(UnsafeBufferPointer(start: UnsafeRawPointer(ptr.baseAddress!)
                .assumingMemoryBound(to: UInt8.self), count: dataSize))
        }
        return out
    }
}
