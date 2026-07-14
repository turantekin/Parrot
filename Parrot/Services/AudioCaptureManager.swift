import AVFoundation
import ScreenCaptureKit
import CoreAudio
import Combine

/// Captures system audio via ScreenCaptureKit and microphone via AVAudioEngine.
/// Provides mixed PCM audio for transcription and saves separate tracks to disk.
@Observable
final class AudioCaptureManager: NSObject {
    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?
    // Write uncompressed PCM (.caf) via AVAudioFile rather than AAC/.m4a via
    // AVAssetWriter: on recent macOS the AAC encoder fails to initialize
    // (AudioCodecInitialize failed / -12651), producing silent 0-byte files.
    // PCM has no codec to fail. Each file is written only from its own serial
    // queue, off the audio render thread.
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    /// Set true before stopCapture's sync barriers. A straggler write block that
    /// was enqueued after the barriers must not lazily recreate an AVAudioFile on
    /// the finished URL — AVAudioFile(forWriting:) truncates, destroying the
    /// recording, and the stale file object would hijack the NEXT recording's
    /// audio. Plain Bool across threads, same accepted pattern as `isCapturing`.
    private var filesClosed = true
    private let systemWriteQueue = DispatchQueue(label: "com.uygar.parrot.audio.system")
    private let micWriteQueue = DispatchQueue(label: "com.uygar.parrot.audio.mic")
    /// Acoustic echo canceller, created per recording when enabled. Removes the
    /// speaker bleed from the mic using the system audio as the reference. nil =
    /// disabled (mic passes through untouched).
    private var echoCanceller: EchoCanceller?

    /// Throttle timestamps for pushing audio levels to the UI — the waveform needs
    /// only ~10 updates/sec, not one per ~20 ms audio buffer per stream.
    @ObservationIgnored private var lastSystemLevelAt = Date.distantPast
    @ObservationIgnored private var lastMicLevelAt = Date.distantPast

    private(set) var isCapturing = false
    private(set) var systemAudioURL: URL?
    private(set) var micAudioURL: URL?
    private(set) var audioLevel: Float = 0
    /// Live mic input level (separate from system audio) so the UI can show
    /// whether the user's own voice is actually being picked up.
    private(set) var micLevel: Float = 0
    /// Whether the mic stream is actually capturing (false = system audio only).
    private(set) var micActive = false
    private(set) var inputDeviceName = ""
    private(set) var outputDeviceName = ""
    /// Capture-start time, or the last moment the mic carried real signal. While the
    /// mic has never been heard it stays at capture start, so it doubles as "how long
    /// the mic has been silent since recording began".
    private(set) var lastMicSignalAt = Date.distantPast

    /// True once the mic has produced any real signal this recording. A user who is
    /// merely listening (normal while the other side talks) just hasn't spoken yet —
    /// that is not a dead mic — so once we've heard signal we never warn.
    private(set) var micEverHadSignal = false

    /// True when echo cancellation is enabled but the system-audio reference never
    /// arrives in the expected format — the AEC is then a silent no-op and the
    /// far end's voice can transcribe as "Me". Shown in the live device bar.
    private(set) var echoCancellerStarved = false

    /// True only when the mic has been on for a while but has never produced any
    /// signal — a genuinely dead, muted, or misrouted mic. We key off "never heard"
    /// rather than recent silence, because in a call the user is routinely silent for
    /// far longer than a few seconds while the other side is speaking.
    var micSeemsDead: Bool {
        isCapturing && micActive && !micEverHadSignal
            && Date().timeIntervalSince(lastMicSignalAt) > 15
    }

    /// Called with PCM audio buffers suitable for WhisperKit, tagged with which
    /// stream they came from (mic = the user, system = everyone else).
    var onAudioBuffer: ((AVAudioPCMBuffer, AudioSource) -> Void)?

    /// Called after the mic engine is rebuilt following an input-device change,
    /// so the transcription clock for "Me" can be re-anchored past the dead gap.
    var onMicRestarted: (() -> Void)?
    /// Observer for AVAudioEngineConfigurationChange on the current engine.
    private var micRestartObserver: NSObjectProtocol?

    private let sampleRate: Double = 16000
    private let channels: UInt32 = 1

    // MARK: - Start Capture

    func startCapture() async throws {
        let storageDir = Self.storageDirectory()
        let timestamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")

        systemAudioURL = storageDir.appendingPathComponent("system_\(timestamp).caf")
        micAudioURL = storageDir.appendingPathComponent("mic_\(timestamp).caf")

        inputDeviceName = Self.defaultDeviceName(input: true)
        outputDeviceName = Self.defaultDeviceName(input: false)
        NSLog("Parrot: starting capture — input: \(inputDeviceName), output: \(outputDeviceName)")

        // Echo cancellation on by default (defeats speaker bleed without headphones).
        let aecEnabled = UserDefaults.standard.object(forKey: "echoCancellationEnabled") as? Bool ?? true
        echoCanceller = aecEnabled ? EchoCanceller() : nil

        filesClosed = false  // fresh URLs above; queues are idle, so no race

        try await startSystemAudioCapture()

        // The microphone is optional. System audio ("Them") is the core capture;
        // a missing or denied mic must NOT abort the whole recording. If mic setup
        // fails we just don't get the user's own voice ("Me") and carry on.
        do {
            try startMicCapture()
            micActive = true
        } catch {
            micActive = false
            micAudioURL = nil
            NSLog("Parrot: microphone unavailable, recording system audio only — \(error.localizedDescription)")
        }

        lastMicSignalAt = Date()  // capture start; the "dead mic" warning waits on this
        micEverHadSignal = false
        echoCancellerStarved = false
        isCapturing = true
    }

    // MARK: - Stop Capture

    func stopCapture() async {
        isCapturing = false
        micActive = false
        micEverHadSignal = false
        audioLevel = 0
        micLevel = 0
        echoCanceller = nil

        // Stop system audio stream
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        // Stop mic engine
        if let micRestartObserver { NotificationCenter.default.removeObserver(micRestartObserver) }
        micRestartObserver = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Flush queued writes, then close the files. AVAudioFile finalizes the
        // .caf header when it deallocates; the sync barrier guarantees every
        // pending write has landed first. filesClosed goes up BEFORE the
        // barriers so any write block enqueued after them no-ops instead of
        // recreating (= truncating) the finished file.
        filesClosed = true
        systemWriteQueue.sync { systemAudioFile = nil }
        micWriteQueue.sync { micAudioFile = nil }

        if let url = systemAudioURL {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            NSLog("Parrot: system audio file finalized — \(size) bytes")
        }
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

        // The system audio file is created lazily from the first buffer's format
        // (see the SCStreamOutput handler), so it always matches what we write.

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // NOTE: we previously enabled setVoiceProcessingEnabled(true) for acoustic
        // echo cancellation, but on this hardware it cancelled ALL mic input (the
        // user's own voice was lost — every recording came back with only "Them").
        // Reverted. Echo (mic picking up the speakers) is avoided by using
        // headphones; a safer AEC approach can be revisited and tested later.

        let inputFormat = inputNode.outputFormat(forBus: 0)

        // When mic access is denied/unavailable the input format collapses to 0
        // channels; installing a tap on that would crash. Bail out cleanly so the
        // caller can continue with system audio only.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw CaptureError.noMicrophone
        }

        // The mic file is created lazily from the converted (16 kHz mono) format.

        // Convert mic audio to our target format for WhisperKit
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isCapturing else { return }

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
            var consumed = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                // Contract: the converter may call this more than once per
                // convert() during rate conversion — handing it the same buffer
                // again duplicates ~20 ms of mic audio (stutter in "Me").
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                // Echo-cancel the mic using the system audio as reference. With AEC
                // off, this returns the mic unchanged. With it on, it returns cleaned
                // 10 ms frames (possibly empty until a frame fills) — fail-safe.
                let micFloats = Self.floats(from: convertedBuffer)
                let cleaned = self.echoCanceller?.process(mic: micFloats) ?? micFloats
                guard !cleaned.isEmpty,
                      let cleanedBuffer = Self.makeBuffer(cleaned, format: targetFormat) else { return }

                // Persist the user's voice ("Me") as 16 kHz mono PCM.
                self.appendAudio(cleanedBuffer, to: .mic)

                // Update the mic level so the UI can show the user's voice landing.
                self.updateAudioLevel(buffer: cleanedBuffer, isMic: true)

                // Send the user's speech to transcription as "Me"
                self.onAudioBuffer?(cleanedBuffer, .me)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine

        // AVAudioEngine stops itself when the input device changes or vanishes
        // (dead AirPods, a manual input switch in System Settings) and never
        // comes back on its own — a 1-hour call once lost its mic at minute 44
        // this way. Rebuild the tap on whatever the new default input is.
        if let micRestartObserver { NotificationCenter.default.removeObserver(micRestartObserver) }
        micRestartObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartMicCapture()
        }
    }

    /// Tear down the stopped engine and rebuild the mic tap on the current
    /// default input. Retries for a while — a Bluetooth handoff takes seconds
    /// to settle, and mid-transition there may briefly be no input device.
    private func restartMicCapture(attempt: Int = 0) {
        guard isCapturing else { return }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        do {
            try startMicCapture()
            micActive = true
            inputDeviceName = Self.defaultDeviceName(input: true)
            NSLog("Parrot: mic restarted after device change — input: \(inputDeviceName)")
            // ponytail: the mic .caf keeps writing continuously, so its file
            // timeline compresses by the dead gap (post-call polish would place
            // late "Me" words early); pad silence on restart if that matters.
            onMicRestarted?()
        } catch {
            micActive = false
            guard attempt < 10 else {
                NSLog("Parrot: mic restart gave up after \(attempt) retries — \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.restartMicCapture(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Audio File Writing

    private enum AudioStream { case system, mic }

    /// Appends a PCM buffer to a stream's .caf file off the capture/render thread.
    /// The file is created lazily from the first buffer's own format, so writes can
    /// never fail on a format mismatch and there is no codec to initialize. The
    /// buffer is deep-copied because the audio system reuses it after we return.
    private func appendAudio(_ buffer: AVAudioPCMBuffer, to stream: AudioStream) {
        guard let copy = buffer.deepCopy() else { return }
        let queue = stream == .system ? systemWriteQueue : micWriteQueue
        let url = stream == .system ? systemAudioURL : micAudioURL
        guard let url else { return }

        queue.async { [weak self] in
            guard let self, !self.filesClosed else { return }
            do {
                let file: AVAudioFile
                if stream == .system {
                    if self.systemAudioFile == nil {
                        self.systemAudioFile = try AVAudioFile(forWriting: url, settings: copy.format.settings)
                    }
                    file = self.systemAudioFile!
                } else {
                    if self.micAudioFile == nil {
                        self.micAudioFile = try AVAudioFile(forWriting: url, settings: copy.format.settings)
                    }
                    file = self.micAudioFile!
                }
                try file.write(from: copy)
            } catch {
                NSLog("Parrot: \(stream) audio write failed — \(error.localizedDescription)")
            }
        }
    }

    private func updateAudioLevel(buffer: AVAudioPCMBuffer, isMic: Bool = false) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            sum += abs(channelData[i])
        }
        let avg = sum / Float(max(frames, 1))

        // Throttle the main-thread hop per stream: the waveform only needs ~10
        // updates/sec, and dispatching every ~20 ms buffer (×2 streams) thrashed
        // SwiftUI. Sampling at 10 Hz still detects a live mic well within the
        // 15 s dead-mic window.
        let now = Date()
        if isMic {
            guard now.timeIntervalSince(lastMicLevelAt) >= 0.1 else { return }
            lastMicLevelAt = now
        } else {
            guard now.timeIntervalSince(lastSystemLevelAt) >= 0.1 else { return }
            lastSystemLevelAt = now
        }

        DispatchQueue.main.async {
            if isMic {
                self.micLevel = avg
                // Speech sits well above room noise; treat this as "mic is alive".
                if avg > 0.004 {
                    self.lastMicSignalAt = Date()
                    self.micEverHadSignal = true
                }
            } else {
                self.audioLevel = avg
            }
        }
    }

    /// Name of the current system default input or output device (CoreAudio).
    static func defaultDeviceName(input: Bool) -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return "Unknown" }

        // The property is a CFString reference; fetch it through an Unmanaged
        // slot rather than &CFString (which the compiler rightly flags — taking
        // a raw pointer to an object reference is UB territory).
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &nameRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard status == noErr, let name = nameRef?.takeRetainedValue() else {
            return "Unknown"
        }
        return name as String
    }

    // MARK: - Buffer helpers

    /// Mono float samples from a PCM buffer.
    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    }

    /// Mono PCM buffer from float samples in the given format.
    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            ch[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
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

        // Convert CMSampleBuffer to AVAudioPCMBuffer for WhisperKit
        guard let pcmBuffer = sampleBuffer.toAVAudioPCMBuffer(sampleRate: sampleRate, channels: channels) else {
            return
        }

        // Persist everyone else's voice ("Them") as PCM.
        appendAudio(pcmBuffer, to: .system)

        // Feed the same audio to the echo canceller as the far-end reference, so it
        // can subtract this from the mic. Only when it's the expected 16 kHz mono.
        if pcmBuffer.format.sampleRate == sampleRate, pcmBuffer.format.channelCount == channels {
            echoCanceller?.pushReference(Self.floats(from: pcmBuffer))
        } else if echoCanceller != nil, !echoCancellerStarved {
            // Without a reference the AEC is silently a no-op and speaker bleed
            // transcribes as "Me" — surface it once instead of hiding it.
            NSLog("Parrot: echo canceller starved — system audio is \(pcmBuffer.format.sampleRate) Hz ×\(pcmBuffer.format.channelCount)ch, expected \(sampleRate) Hz mono")
            DispatchQueue.main.async { self.echoCancellerStarved = true }
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
    /// Independent copy of the samples. Tap/conversion buffers are owned by the
    /// audio system and reused on the next callback, so we must copy before
    /// handing the data to an async writer.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        let channelCount = Int(format.channelCount)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size)
            }
        }
        return copy
    }

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
