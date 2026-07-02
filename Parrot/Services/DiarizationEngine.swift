import Foundation
import AVFoundation

/// Handles post-meeting speaker diarization.
/// Uses SpeakerKit (Argmax) when available, with a fallback to basic
/// energy-based segmentation for V1.
@Observable
final class DiarizationEngine {
    private(set) var isProcessing = false
    private(set) var progress: Double = 0

    struct SpeakerSegmentResult {
        let speakerLabel: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// Process audio file and return speaker segments.
    /// In V1, this uses a basic energy-based approach.
    /// SpeakerKit integration is ready for when the package is added.
    func diarize(audioURL: URL) async throws -> [SpeakerSegmentResult] {
        isProcessing = true
        progress = 0

        defer {
            isProcessing = false
            progress = 1.0
        }

        // Stream per-window energies off disk — the segmentation only needs one
        // RMS per 250 ms, so loading a 2-hour recording (~460 MB of floats) into
        // a single buffer was pure memory waste.
        let energies = try windowEnergies(from: audioURL)
        progress = 0.5

        // Perform basic energy-based speaker segmentation
        let segments = performEnergyBasedDiarization(windowEnergies: energies,
                                                     windowDuration: Self.windowDuration)
        progress = 0.9

        return segments
    }

    // MARK: - Audio Loading

    /// 250 ms analysis windows.
    private static let windowDuration = 0.25

    /// RMS energy per window, computed block-by-block. Reads in the file's own
    /// processing format (a rate-mismatched fixed-format buffer made read throw
    /// on non-16 kHz files, which used to fail the whole meeting).
    private func windowEnergies(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let windowSize = max(1, Int(format.sampleRate * Self.windowDuration))
        let blockFrames: AVAudioFrameCount = 1 << 18  // a few seconds per read

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw DiarizationError.audioLoadFailed
        }

        var energies: [Float] = []
        var sumSquares: Float = 0
        var samplesInWindow = 0

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: blockFrames)
            guard buffer.frameLength > 0 else { break }
            guard let ch = buffer.floatChannelData?[0] else {
                throw DiarizationError.audioLoadFailed
            }
            for i in 0..<Int(buffer.frameLength) {
                sumSquares += ch[i] * ch[i]
                samplesInWindow += 1
                if samplesInWindow == windowSize {
                    energies.append(sqrt(sumSquares / Float(windowSize)))
                    sumSquares = 0
                    samplesInWindow = 0
                }
            }
        }
        if samplesInWindow > 0 {
            energies.append(sqrt(sumSquares / Float(samplesInWindow)))
        }
        return energies
    }

    // MARK: - Basic Energy-Based Diarization

    /// Simple diarization that segments audio by silence gaps and assigns
    /// alternating speaker labels. This is a placeholder until SpeakerKit is integrated.
    private func performEnergyBasedDiarization(
        windowEnergies: [Float],
        windowDuration: Double
    ) -> [SpeakerSegmentResult] {
        let silenceThreshold: Float = 0.01
        let minSegmentDuration: Double = 1.0 // minimum 1 second per segment
        let minSilenceGap: Double = 0.8 // 800ms silence = speaker change

        var segments: [SpeakerSegmentResult] = []
        var currentSpeaker = 0
        var segmentStart: Double = 0
        var lastActiveTime: Double = 0
        var isActive = false

        for (index, rms) in windowEnergies.enumerated() {
            let currentTime = Double(index) * windowDuration

            if rms > silenceThreshold {
                if !isActive {
                    // Check if this is a new segment (after silence gap)
                    if currentTime - lastActiveTime > minSilenceGap && lastActiveTime > 0 {
                        // End previous segment
                        let duration = lastActiveTime - segmentStart
                        if duration >= minSegmentDuration {
                            segments.append(SpeakerSegmentResult(
                                speakerLabel: "Speaker \(currentSpeaker + 1)",
                                startTime: segmentStart,
                                endTime: lastActiveTime
                            ))
                        }
                        // Start new segment, potentially new speaker
                        currentSpeaker = (currentSpeaker + 1) % 2 // Simple alternation
                        segmentStart = currentTime
                    } else if !isActive && segments.isEmpty {
                        segmentStart = currentTime
                    }
                    isActive = true
                }
                lastActiveTime = currentTime
            } else {
                isActive = false
            }
        }

        // Add final segment
        if lastActiveTime > segmentStart {
            let duration = lastActiveTime - segmentStart
            if duration >= minSegmentDuration {
                segments.append(SpeakerSegmentResult(
                    speakerLabel: "Speaker \(currentSpeaker + 1)",
                    startTime: segmentStart,
                    endTime: lastActiveTime
                ))
            }
        }

        return segments
    }
}

enum DiarizationError: LocalizedError {
    case audioLoadFailed
    case modelNotAvailable

    var errorDescription: String? {
        switch self {
        case .audioLoadFailed: "Failed to load audio file for diarization"
        case .modelNotAvailable: "Diarization model is not available"
        }
    }
}

// MARK: - SpeakerKit Integration (ready for Phase 4 upgrade)
//
// To upgrade to SpeakerKit:
// 1. Add to Package.swift: .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "x.x.x")
// 2. Import SpeakerKit
// 3. Replace performEnergyBasedDiarization with:
//
//    let config = SpeakerKitConfig(load: true)
//    let speakerKit = try await SpeakerKit(config: config)
//    let result = try await speakerKit.diarize(audioArray: audioData, options: nil, progressCallback: { p in
//        self.progress = Double(p.fractionCompleted)
//    })
//    return result.segments.map { segment in
//        SpeakerSegmentResult(
//            speakerLabel: "Speaker \(segment.speaker.speakerId + 1)",
//            startTime: Double(segment.startFrame) / Double(result.frameRate),
//            endTime: Double(segment.endFrame) / Double(result.frameRate)
//        )
//    }
