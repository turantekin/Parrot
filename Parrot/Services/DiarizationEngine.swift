import Foundation
import AVFoundation
import FluidAudio

/// Post-meeting speaker diarization over the system-audio track, backed by
/// FluidAudio's chunked pyannote pipeline (CoreML, fully on-device).
/// Models (~13 MB, CC-BY-4.0) auto-download to Application Support on first use.
///
/// Pipeline choice, validated 2026-08-04 on a real 3-person Turkish call:
/// the chunked `DiarizerManager` separates two similar remote voices at
/// threshold 0.5–0.6, while `OfflineDiarizerManager` (better on published
/// AMI benchmarks) merges them at EVERY threshold 0.2–0.6 — its VBx stage
/// won't keep these voices apart. Real recordings beat benchmarks; re-check
/// with --diarize-test before switching pipelines.
@Observable
final class DiarizationEngine {
    private(set) var isProcessing = false
    private(set) var progress: Double = 0

    struct SpeakerSegmentResult {
        let speakerLabel: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    struct Output {
        let segments: [SpeakerSegmentResult]
        /// Mean voice embedding per speaker label — persisted on the meeting
        /// for voice profiles (phase 3).
        let embeddings: [String: [Float]]
        /// Where the diarized audio starts in the call: 0 for a whole file,
        /// the tail's start for a live window.
        var start: TimeInterval = 0
    }

    /// The one calibration knob. On the reference call: 0.70 (library
    /// default) merges the two remote voices, 0.5–0.6 separates them
    /// correctly, 0.4 shatters into 14 fragments. ponytail: re-validate with
    /// --diarize-test + scripts/dev/diarization-compare.py when bumping the
    /// FluidAudio pin.
    static let clusteringThreshold: Float = 0.6

    static var modelsInstalled: Bool {
        let dir = DiarizerModels.defaultModelsDirectory()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !items.isEmpty
    }

    static func removeModels() {
        try? FileManager.default.removeItem(at: DiarizerModels.defaultModelsDirectory())
    }

    /// Downloads models if missing (first run needs network). Lets Settings
    /// pre-fetch without running a diarization.
    func ensureModels() async throws {
        isProcessing = true
        defer { isProcessing = false }
        _ = try await DiarizerModels.downloadIfNeeded()
    }

    /// The last `seconds` of a (possibly still growing) recording as 16 kHz
    /// mono samples, plus where that tail starts in the call. Live sweeps use
    /// this so their cost stays flat however long the call runs.
    static func tail(of url: URL, seconds: TimeInterval) throws -> (samples: [Float], offset: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let start = max(0, file.length - AVAudioFramePosition(seconds * rate))
        file.framePosition = start
        let count = AVAudioFrameCount(file.length - start)
        guard count > 0,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(Double(count) * 16000 / rate) + 1024)
        else { return ([], TimeInterval(start) / rate) }
        try file.read(into: input, frameCount: count)
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData?[0], count: Int(output.frameLength)))
        return (samples, TimeInterval(start) / rate)
    }

    func diarize(audioURL: URL) async throws -> Output {
        try await diarize(load: { try AudioConverter().resampleAudioFile(audioURL) }, offset: 0)
    }

    /// Diarizes only the tail of the recording; times come back in call time.
    func diarize(audioURL: URL, lastSeconds: TimeInterval) async throws -> Output {
        let tail = try Self.tail(of: audioURL, seconds: lastSeconds)
        return try await diarize(load: { tail.samples }, offset: tail.offset)
    }

    private func diarize(load: @escaping @Sendable () throws -> [Float], offset: TimeInterval) async throws -> Output {
        isProcessing = true
        progress = 0
        defer {
            isProcessing = false
            progress = 1.0
        }

        let models = try await DiarizerModels.downloadIfNeeded()
        progress = 0.3

        // The chunked pipeline is synchronous and CPU/ANE-heavy (~seconds for
        // a long call) — keep it off the calling actor.
        let threshold = Self.clusteringThreshold
        let result = try await Task.detached(priority: .userInitiated) {
            var config = DiarizerConfig()
            config.clusteringThreshold = threshold
            let manager = DiarizerManager(config: config)
            manager.initialize(models: models)
            return try manager.performCompleteDiarization(try load(), sampleRate: 16000)
        }.value
        progress = 0.95

        // Stable, human-meaningful labels: Speaker 1 talked the most.
        let bySpeaker = Dictionary(grouping: result.segments, by: \.speakerId)
        let ordered = bySpeaker.sorted { a, b in
            a.value.reduce(0) { $0 + $1.endTimeSeconds - $1.startTimeSeconds }
                > b.value.reduce(0) { $0 + $1.endTimeSeconds - $1.startTimeSeconds }
        }
        var labelFor: [String: String] = [:]
        for (index, entry) in ordered.enumerated() {
            labelFor[entry.key] = "Speaker \(index + 1)"
        }

        let segments = result.segments.map {
            SpeakerSegmentResult(
                speakerLabel: labelFor[$0.speakerId] ?? "Speaker ?",
                startTime: offset + TimeInterval($0.startTimeSeconds),
                endTime: offset + TimeInterval($0.endTimeSeconds))
        }

        var embeddings: [String: [Float]] = [:]
        for (id, segs) in bySpeaker {
            let vectors = segs.map(\.embedding).filter { !$0.isEmpty }
            guard let first = vectors.first, let label = labelFor[id] else { continue }
            var mean = [Float](repeating: 0, count: first.count)
            for vector in vectors {
                for i in 0..<min(mean.count, vector.count) { mean[i] += vector[i] }
            }
            for i in mean.indices { mean[i] /= Float(vectors.count) }
            embeddings[label] = mean
        }

        return Output(segments: segments, embeddings: embeddings, start: offset)
    }
}
