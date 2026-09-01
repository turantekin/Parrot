import Foundation

/// Shared callbacks for Deepgram and Gemini Live sockets.
protocol LiveAudioStreamer: AnyObject {
    var onInterim: ((String) -> Void)? { get set }
    var onFinal: ((String, Double, Double) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func send(_ samples: [Float])
    func finish()
    func close()
}

/// Parsed Live API server messages. Used by the streamer and the harness.
enum GeminiLiveEvent {
    static func parse(_ data: Data) -> (setupComplete: Bool, interim: String?, finalText: String?, output: String?, error: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return (false, nil, nil, nil, nil)
        }
        return parseObject(object)
    }

    static func parseObject(_ object: Any) -> (setupComplete: Bool, interim: String?, finalText: String?, output: String?, error: String?) {
        guard let dict = object as? [String: Any] else {
            return (false, nil, nil, nil, nil)
        }
        if let err = dict["error"] as? [String: Any] {
            let message = (err["message"] as? String) ?? "Gemini Live error"
            return (false, nil, nil, nil, message)
        }
        let setup = dict["setupComplete"] != nil || dict["setup_complete"] != nil
        let content = (dict["serverContent"] as? [String: Any])
            ?? (dict["server_content"] as? [String: Any])
            ?? [:]
        let interim = text(in: content, keys: ["interimInputTranscription", "interim_input_transcription"])
        let finalText = text(in: content, keys: ["inputTranscription", "input_transcription"])
        let output = text(in: content, keys: ["outputTranscription", "output_transcription"])
        return (setup, interim, finalText, output, nil)
    }

    private static func text(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let nested = dict[key] as? [String: Any],
               let text = nested["text"] as? String,
               !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

/// Pair translated utterances to transcript rows by overlap, then leftover order.
enum TranslationAssigner {
    static func apply(
        translations: [(start: Double, end: Double, text: String)],
        segments: [(start: Double, end: Double)]
    ) -> [Int: String] {
        guard !translations.isEmpty, !segments.isEmpty else { return [:] }
        let timed = translations.contains { $0.end > $0.start }
        if !timed {
            var out: [Int: String] = [:]
            for (i, item) in zip(segments.indices, translations) {
                out[i] = item.text
            }
            return out
        }
        var out: [Int: String] = [:]
        var used = Set<Int>()
        for item in translations {
            var best: (Int, Double)?
            for (i, segment) in segments.enumerated() where !used.contains(i) {
                let overlap = min(item.end, segment.end) - max(item.start, segment.start)
                let span = max(segment.end - segment.start, 0.01)
                let needed = max(0.5, 0.3 * span)
                if overlap >= needed, best == nil || overlap > best!.1 {
                    best = (i, overlap)
                }
            }
            if let (i, _) = best {
                used.insert(i)
                out[i] = item.text
            }
        }
        return out
    }
}

/// One Live socket per audio source. `gemini-3.5-transcribe-live` for meetings
/// and the live translation feature. Sessions rotate before the 10-minute cap.
final class GeminiLiveStreamer: LiveAudioStreamer {
    static let model = "gemini-3.5-transcribe-live"
    static let sessionLimitSeconds: Double = 540
    static let chunkSamples = 1600

    var onInterim: ((String) -> Void)?
    var onFinal: ((String, Double, Double) -> Void)?
    var onError: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var apiKey = ""
    private var language: String?
    private var vocabulary: [String] = []
    private var ready = false
    private var failed = false
    private var closing = false
    private var queued: [Float] = []
    private var chunk: [Float] = []
    private var samplesSent = 0
    private var sessionOffset = 0.0
    private var utteranceStart = 0
    private var inUtterance = false

    func connect(apiKey: String, language: String?, vocabulary: [String]) {
        self.apiKey = apiKey
        self.language = language
        self.vocabulary = vocabulary
        openSocket()
    }

    func send(_ samples: [Float]) {
        if !ready {
            queued.append(contentsOf: samples)
            return
        }
        flush(samples)
    }

    func finish() {
        closing = true
        if !chunk.isEmpty { emitPCM(chunk); chunk = [] }
        sendJSON(["realtimeInput": ["audioStreamEnd": true]])
    }

    func close() {
        closing = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        ready = false
    }

    private func openSocket() {
        ready = false
        var components = URLComponents(string:
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            fail("Gemini Live URL failed")
            return
        }
        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
        sendSetup()
    }

    private func sendSetup() {
        var transcription: [String: Any] = [
            "languageCodes": GeminiLanguage.bcp47(from: language),
            "mode": "VERBATIM",
        ]
        if !vocabulary.isEmpty {
            transcription["customVocabulary"] = Array(vocabulary.prefix(100))
        }
        sendJSON([
            "setup": [
                "model": "models/\(Self.model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
            ] as [String: Any],
        ])
    }

    private func flush(_ samples: [Float]) {
        if samplesSent > 0,
           Double(samplesSent) / 16000 >= Self.sessionLimitSeconds {
            rotate()
        }
        var rest = samples
        if !chunk.isEmpty {
            let need = Self.chunkSamples - chunk.count
            if rest.count >= need {
                emitPCM(chunk + Array(rest.prefix(need)))
                rest.removeFirst(need)
                chunk = []
            } else {
                chunk.append(contentsOf: rest)
                return
            }
        }
        while rest.count >= Self.chunkSamples {
            emitPCM(Array(rest.prefix(Self.chunkSamples)))
            rest.removeFirst(Self.chunkSamples)
        }
        chunk = rest
    }

    private func rotate() {
        sessionOffset += Double(samplesSent) / 16000
        samplesSent = 0
        utteranceStart = 0
        inUtterance = false
        chunk = []
        task?.cancel(with: .normalClosure, reason: nil)
        openSocket()
    }

    private func emitPCM(_ samples: [Float]) {
        samplesSent += samples.count
        sendJSON([
            "realtimeInput": [
                "audio": [
                    "data": pcmBase64(samples),
                    "mimeType": "audio/pcm;rate=16000",
                ],
            ],
        ])
    }

    private func receiveLoop() {
        guard let socket = task else { return }
        socket.receive { [weak self] result in
            guard let self, self.task === socket else { return }
            switch result {
            case .failure(let error):
                if !self.closing { self.fail(error.localizedDescription) }
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let body): data = body
                @unknown default: data = nil
                }
                if let data { self.handle(data) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ data: Data) {
        let event = GeminiLiveEvent.parse(data)
        if let error = event.error {
            fail(error)
            return
        }
        if event.setupComplete && !ready {
            ready = true
            if !queued.isEmpty {
                let pending = queued
                queued = []
                flush(pending)
            }
        }
        if let interim = event.interim {
            if !inUtterance {
                inUtterance = true
                utteranceStart = samplesSent
            }
            onInterim?(interim)
        }
        if let finalText = event.finalText {
            let start = sessionOffset + Double(min(utteranceStart, samplesSent)) / 16000
            let end = sessionOffset + Double(max(samplesSent, utteranceStart + 1)) / 16000
            inUtterance = false
            utteranceStart = samplesSent
            onFinal?(finalText, start, max(end, start + 0.2))
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error, self?.closing != true { self?.fail(error.localizedDescription) }
        }
    }

    private func fail(_ message: String) {
        guard !failed, !closing else { return }
        failed = true
        onError?(message)
    }
}

/// Post-call pass: `gemini-3.5-live-translate-preview` over saved tracks.
enum GeminiLiveTranslator {
    static let model = "gemini-3.5-live-translate-preview"

    enum TranslateError: LocalizedError {
        case missingKey
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: "No Gemini API key."
            case .failed(let message): message
            }
        }
    }

    static func translateTrack(
        samples: [Float],
        targetBCP47: String,
        apiKey: String
    ) async throws -> [(text: String, start: Double, end: Double)] {
        guard !apiKey.isEmpty else { throw TranslateError.missingKey }
        guard !samples.isEmpty else { return [] }
        let limit = Int(GeminiLiveStreamer.sessionLimitSeconds * 16000)
        var offset = 0
        var out: [(String, Double, Double)] = []
        while offset < samples.count {
            let end = min(samples.count, offset + limit)
            let part = Array(samples[offset..<end])
            let shift = Double(offset) / 16000
            let rows = try await runSession(samples: part, targetBCP47: targetBCP47, apiKey: apiKey)
            for row in rows {
                out.append((row.text, row.start + shift, row.end + shift))
            }
            offset = end
        }
        return out
    }

    private static func runSession(
        samples: [Float],
        targetBCP47: String,
        apiKey: String
    ) async throws -> [(text: String, start: Double, end: Double)] {
        try await withCheckedThrowingContinuation { continuation in
            let session = PostCallTranslateSession(
                samples: samples,
                targetBCP47: targetBCP47,
                apiKey: apiKey
            ) { result in
                continuation.resume(with: result)
            }
            session.start()
        }
    }
}

private final class PostCallTranslateSession {
    private let samples: [Float]
    private let targetBCP47: String
    private let apiKey: String
    private let finish: (Result<[(text: String, start: Double, end: Double)], Error>) -> Void
    private var task: URLSessionWebSocketTask?
    private var finished = false
    private var retained: PostCallTranslateSession?
    private var utterances: [(String, Double, Double)] = []
    private var samplesSent = 0
    private var utteranceStart = 0

    init(samples: [Float], targetBCP47: String, apiKey: String,
         finish: @escaping (Result<[(text: String, start: Double, end: Double)], Error>) -> Void) {
        self.samples = samples
        self.targetBCP47 = targetBCP47
        self.apiKey = apiKey
        self.finish = finish
    }

    func start() {
        retained = self
        var components = URLComponents(string:
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            complete(.failure(GeminiLiveTranslator.TranslateError.failed("Gemini Live URL failed")))
            return
        }
        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
        sendJSON([
            "setup": [
                "model": "models/\(GeminiLiveTranslator.model)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "inputAudioTranscription": [:] as [String: Any],
                    "outputAudioTranscription": [:] as [String: Any],
                    "translationConfig": [
                        "targetLanguageCode": targetBCP47,
                        "echoTargetLanguage": true,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ])
        let cap = min(180, max(90, Double(samples.count) / 16000 + 30))
        DispatchQueue.main.asyncAfter(deadline: .now() + cap) { [weak self] in
            self?.complete(.success(self?.utterances ?? []))
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, !self.finished else { return }
            switch result {
            case .failure(let error):
                self.complete(.failure(GeminiLiveTranslator.TranslateError.failed(error.localizedDescription)))
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let body): data = body
                @unknown default: data = nil
                }
                if let data { self.handle(data) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ data: Data) {
        let event = GeminiLiveEvent.parse(data)
        if let error = event.error {
            complete(.failure(GeminiLiveTranslator.TranslateError.failed(error)))
            return
        }
        if event.setupComplete {
            pumpAudio()
        }
        if let text = event.output ?? event.finalText {
            // Untimed: pumpAudio is faster than realtime, so clocked stamps
            // collapse and fail the overlap assigner. Zip by order instead.
            utterances.append((text, 0, 0))
        }
    }

    private func pumpAudio() {
        var rest = samples
        let size = GeminiLiveStreamer.chunkSamples
        while !rest.isEmpty {
            let n = min(size, rest.count)
            let chunk = Array(rest.prefix(n))
            rest.removeFirst(n)
            samplesSent += chunk.count
            sendJSON([
                "realtimeInput": [
                    "audio": [
                        "data": pcmBase64(chunk),
                        "mimeType": "audio/pcm;rate=16000",
                    ],
                ],
            ])
        }
        sendJSON(["realtimeInput": ["audioStreamEnd": true]])
        let wait = min(30, max(2.5, Double(samples.count) / 16000 * 0.35))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.complete(.success(self?.utterances ?? []))
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func complete(_ result: Result<[(text: String, start: Double, end: Double)], Error>) {
        guard !finished else { return }
        finished = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        finish(result.map { $0.map { (text: $0.0, start: $0.1, end: $0.2) } })
        retained = nil
    }
}

private func pcmBase64(_ samples: [Float]) -> String {
    var pcm = [Int16](repeating: 0, count: samples.count)
    for (i, s) in samples.enumerated() {
        pcm[i] = Int16(max(-1, min(1, s)) * 32767)
    }
    return pcm.withUnsafeBufferPointer { Data(buffer: $0).base64EncodedString() }
}
