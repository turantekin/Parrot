import AVFoundation
import ScreenCaptureKit
import Combine

/// Captures system audio via ScreenCaptureKit and microphone via AVAudioEngine.
/// Provides mixed PCM audio for transcription and saves separate tracks to disk.
@Observable
final class AudioCaptureManager: NSObject {
    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?
    private var systemAudioWriter: AVAssetWriter?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioWriter: AVAssetWriter?
    private var micAudioInput: AVAssetWriterInput?

    private(set) var isCapturing = false
    private(set) var systemAudioURL: URL?
    private(set) var micAudioURL: URL?
    private(set) var audioLevel: Float = 0

    /// Called with PCM audio buffers suitable for WhisperKit, tagged with which
    /// stream they came from (mic = the user, system = everyone else).
    var onAudioBuffer: ((AVAudioPCMBuffer, AudioSource) -> Void)?

    private let sampleRate: Double = 16000
    private let channels: UInt32 = 1

    // MARK: - Start Capture

    func startCapture() async throws {
        let storageDir = Self.storageDirectory()
        let timestamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")

        systemAudioURL = storageDir.appendingPathComponent("system_\(timestamp).m4a")
        micAudioURL = storageDir.appendingPathComponent("mic_\(timestamp).m4a")

        try await startSystemAudioCapture()
        try startMicCapture()
        isCapturing = true
    }

    // MARK: - Stop Capture

    func stopCapture() async {
        isCapturing = false

        // Stop system audio stream
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        // Stop mic engine
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Finalize writers
        await finalizeWriter(systemAudioWriter, input: systemAudioInput)
        await finalizeWriter(micAudioWriter, input: micAudioInput)
        systemAudioWriter = nil
        micAudioWriter = nil
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        // Pre-check screen capture permission
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw CaptureError.screenRecordingDenied
        }

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = Int(channels)
        // We only want audio, minimize video overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // Set up audio file writer
        if let url = systemAudioURL {
            systemAudioWriter = try createAudioWriter(url: url)
            systemAudioInput = createAudioWriterInput()
            if let input = systemAudioInput {
                systemAudioWriter?.add(input)
            }
            systemAudioWriter?.startWriting()
            systemAudioWriter?.startSession(atSourceTime: .zero)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Set up mic audio file writer
        if let url = micAudioURL {
            micAudioWriter = try createAudioWriter(url: url)
            micAudioInput = createAudioWriterInput()
            if let input = micAudioInput {
                micAudioWriter?.add(input)
            }
            micAudioWriter?.startWriting()
            micAudioWriter?.startSession(atSourceTime: .zero)
        }

        // Convert mic audio to our target format for WhisperKit
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self, self.isCapturing else { return }

            // Write raw mic audio to file
            if let sampleBuffer = buffer.toCMSampleBuffer(presentationTime: time) {
                self.micAudioInput?.append(sampleBuffer)
            }

            // Convert to target format
            guard let converter else { return }
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                // Update audio level for UI visualization
                self.updateAudioLevel(buffer: convertedBuffer)

                // Send the user's speech to transcription as "Me"
                self.onAudioBuffer?(convertedBuffer, .me)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    // MARK: - Audio Writer Helpers

    private func createAudioWriter(url: URL) throws -> AVAssetWriter {
        // Remove existing file if any
        try? FileManager.default.removeItem(at: url)
        return try AVAssetWriter(outputURL: url, fileType: .m4a)
    }

    private func createAudioWriterInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func finalizeWriter(_ writer: AVAssetWriter?, input: AVAssetWriterInput?) async {
        guard let writer, writer.status == .writing else { return }
        input?.markAsFinished()
        await writer.finishWriting()
    }

    private func updateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            sum += abs(channelData[i])
        }
        let avg = sum / Float(max(frames, 1))
        DispatchQueue.main.async {
            self.audioLevel = avg
        }
    }

    // MARK: - Storage

    static func storageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Parrot/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isCapturing else { return }

        // Write to file
        if systemAudioInput?.isReadyForMoreMediaData == true {
            systemAudioInput?.append(sampleBuffer)
        }

        // Convert CMSampleBuffer to AVAudioPCMBuffer for WhisperKit
        guard let pcmBuffer = sampleBuffer.toAVAudioPCMBuffer(sampleRate: sampleRate, channels: channels) else {
            return
        }

        // Update audio level
        updateAudioLevel(buffer: pcmBuffer)

        // Send everyone else's speech to transcription as "Them"
        onAudioBuffer?(pcmBuffer, .them)
    }
}

// MARK: - Capture Error

enum CaptureError: LocalizedError {
    case noDisplay
    case noMicrophone
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display found for audio capture"
        case .noMicrophone: "No microphone available"
        case .screenRecordingDenied: "Screen Recording permission is required. Please grant it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Parrot."
        }
    }
}

// MARK: - Buffer Conversion Extensions

extension CMSampleBuffer {
    func toAVAudioPCMBuffer(sampleRate: Double, channels: UInt32) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false
        ) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, let channelData = pcmBuffer.floatChannelData else { return nil }

        // Copy audio data — handle float32 format
        let byteCount = min(length, Int(pcmBuffer.frameCapacity) * MemoryLayout<Float>.size)
        memcpy(channelData[0], data, byteCount)

        return pcmBuffer
    }
}

extension AVAudioPCMBuffer {
    func toCMSampleBuffer(presentationTime: AVAudioTime) -> CMSampleBuffer? {
        let format = self.format
        guard let formatDesc = format.formatDescription as CMFormatDescription? else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameLength), timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: CMTime(seconds: Double(presentationTime.sampleTime) / format.sampleRate, preferredTimescale: CMTimeScale(format.sampleRate)),
            decodeTimeStamp: .invalid
        )

        guard let data = floatChannelData?[0] else { return nil }
        let dataSize = Int(frameLength) * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard let block = blockBuffer else { return nil }
        CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize)

        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}
