import AVFoundation
import CoreAudio
import os

/// System-audio capture via a Core Audio process tap (macOS 15+): taps every
/// process's output except our own, mixed to mono at the hardware rate, and
/// delivers 16 kHz mono Float32 buffers — the same contract the
/// ScreenCaptureKit path produces. Runs under TCC's "System Audio Recording
/// Only" category, so the scary Screen Recording ask (and its periodic macOS
/// re-confirmation prompts) disappears.
///
/// TCC reality, measured on-device: creating a tap while unauthorized
/// *succeeds* and delivers buffers of exact digital zeros — there is no error
/// and no status API. Callers must treat "audio actually flowed" as the only
/// proof of a grant (see PermissionFlow.tapProvenKey and the silence rescue in
/// AudioCaptureManager).
@available(macOS 15.0, *)
final class SystemAudioTap {
    /// Converted 16 kHz mono buffers, in order, on a serial queue of their own.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    /// IO callbacks and the format-change listener share this queue, so the
    /// converter/sourceFormat pair is never read while being rebuilt.
    private let queue = DispatchQueue(label: "com.uygar.parrot.audio.tap", qos: .userInteractive)
    /// onBuffer runs here, not in the IO callback: Core Audio skips whatever
    /// time the callback overruns, so a consumer stuck on a lock for 50 ms
    /// lost 50 ms of "Them" (measured with --capture-test, issue #100).
    private let deliveryQueue = DispatchQueue(label: "com.uygar.parrot.audio.tap.deliver", qos: .userInteractive)
    private var formatListener: AudioObjectPropertyListenerBlock?
    /// Uptime when start() began; the first IO callback logs its delay from
    /// here once, then zeroes it. IO queue only after start() returns.
    private var startedAt: TimeInterval = 0
    /// Audio Core Audio skipped because a callback ran late, heard as a click
    /// in "Them". Found from jumps in the input sample time. IO queue; read
    /// after stop().
    private(set) var lostSeconds: Double = 0
    private var lostGaps = 0
    private var nextSampleTime: Float64 = -1

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    deinit { stop() }

    enum TapError: LocalizedError {
        case coreAudio(stage: String, status: OSStatus)
        var errorDescription: String? {
            switch self {
            case .coreAudio(let stage, let status):
                return "System audio tap \(stage) failed (OSStatus \(status))"
            }
        }
    }

    func start() throws {
        let t0 = ProcessInfo.processInfo.systemUptime
        func ms(_ since: TimeInterval) -> Int { Int((ProcessInfo.processInfo.systemUptime - since) * 1000) }
        startedAt = t0
        // Mirror ScreenCaptureKit's excludesCurrentProcessAudio: leave our own
        // output out of the mix. Failure to translate just means no exclusion.
        var excluded: [AudioObjectID] = []
        if let own = Self.processObject(forPID: ProcessInfo.processInfo.processIdentifier) {
            excluded = [own]
        }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "Parrot System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted  // the user must keep hearing their call

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.coreAudio(stage: "creation", status: err)
        }
        tapID = newTapID
        let tapMs = ms(t0)

        do {
            // The tap's format follows the output hardware (typically 48 kHz
            // mono Float32 for a mono mixdown); the converter brings it to 16 kHz.
            let asbd = try readTapFormat()
            try rebuildConverter(from: asbd)

            // A private aggregate device whose only member is the tap gives us a
            // clock to run an IOProc against. It never appears in Audio MIDI Setup.
            // No tap auto-start: with it, IO waits until some other app starts
            // playing ("Starting tap after waiting for writers" in coreaudiod),
            // 8-12 s on recordings started before the call audio, and then
            // lags that app's output by 20-100 ms. Without it the tap delivers
            // (silent) buffers from the first instant, ~50 ms after start.
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Parrot System Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: description.uuid.uuidString,
                     kAudioSubTapDriftCompensationKey: true]
                ],
            ]
            let t1 = ProcessInfo.processInfo.systemUptime
            err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
            guard err == noErr, aggregateID != kAudioObjectUnknown else {
                throw TapError.coreAudio(stage: "aggregate device", status: err)
            }
            let aggregateMs = ms(t1)
            let t2 = ProcessInfo.processInfo.systemUptime

            err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, inInputTime, _, _ in
                self?.deliver(inInputData, at: inInputTime.pointee)
            }
            guard err == noErr, ioProcID != nil else {
                throw TapError.coreAudio(stage: "IO proc", status: err)
            }

            err = AudioDeviceStart(aggregateID, ioProcID)
            guard err == noErr else {
                throw TapError.coreAudio(stage: "device start", status: err)
            }
            AudioCaptureManager.oslog.log("system tap up in \(ms(t0), privacy: .public) ms (tap \(tapMs, privacy: .public), aggregate \(aggregateMs, privacy: .public), IO start \(ms(t2), privacy: .public))")

            // Output-device switches (speakers → AirPods) can change the tap's
            // rate mid-recording; rebuilding just the converter keeps the
            // stream alive without a full restart.
            var addr = Self.formatAddress
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleFormatChange()
            }
            if AudioObjectAddPropertyListenerBlock(tapID, &addr, queue, listener) == noErr {
                formatListener = listener
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let listener = formatListener {
            var addr = Self.formatAddress
            AudioObjectRemovePropertyListenerBlock(tapID, &addr, queue, listener)
            formatListener = nil
        }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioCaptureManager.oslog.log("system tap stopped: \(self.lostGaps, privacy: .public) gaps, \(self.lostSeconds, format: .fixed(precision: 3), privacy: .public) s of audio skipped")
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
        sourceFormat = nil
    }

    /// Creating (and immediately destroying) a tap is the only way to make
    /// macOS post its one official "System Audio Recording" consent prompt —
    /// the audio-only sibling of CGRequestScreenCaptureAccess(). Returns
    /// immediately; the prompt resolves asynchronously and its answer cannot
    /// be read back.
    static func fireAuthorizationPrompt() {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Parrot System Audio"
        description.isPrivate = true
        var probeTapID = AudioObjectID(kAudioObjectUnknown)
        if AudioHardwareCreateProcessTap(description, &probeTapID) == noErr,
           probeTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(probeTapID)
        }
    }

    // MARK: - IO path

    /// IO-queue only. Wraps the raw buffer list, resamples to the target
    /// format, and hands the result to `onBuffer` on the delivery queue.
    private func deliver(_ bufferList: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp) {
        if startedAt > 0 {
            let delay = ProcessInfo.processInfo.systemUptime - startedAt
            startedAt = 0
            AudioCaptureManager.oslog.log("system tap first IO callback \(delay, format: .fixed(precision: 3), privacy: .public) s after start")
        }
        guard let sourceFormat, let converter,
              let source = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                bufferListNoCopy: UnsafeMutablePointer(mutating: bufferList),
                deallocator: nil),
              source.frameLength > 0 else { return }

        if time.mFlags.contains(.sampleTimeValid) {
            if nextSampleTime >= 0, time.mSampleTime > nextSampleTime + 1 {
                lostSeconds += (time.mSampleTime - nextSampleTime) / sourceFormat.sampleRate
                lostGaps += 1
                // ponytail: first few, then every 100th, so a bad call can't flood the log.
                if lostGaps <= 5 || lostGaps % 100 == 0 {
                    AudioCaptureManager.oslog.log("system tap skipped audio: \(self.lostGaps, privacy: .public) gaps, \(self.lostSeconds, format: .fixed(precision: 3), privacy: .public) s lost so far")
                }
            }
            nextSampleTime = time.mSampleTime + Float64(source.frameLength)
        }

        let capacity = AVAudioFrameCount(
            (Double(source.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)
        )
        guard capacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            // Same contract as the mic tap: hand the source over exactly once
            // per convert() or rate conversion duplicates audio.
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }
        guard error == nil, converted.frameLength > 0, let onBuffer else { return }
        deliveryQueue.async { onBuffer(converted) }
    }

    // MARK: - Format handling

    private static let formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var addr = Self.formatAddress
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            throw TapError.coreAudio(stage: "format read", status: err)
        }
        return asbd
    }

    private func rebuildConverter(from asbd: AudioStreamBasicDescription) throws {
        var mutable = asbd
        guard let format = AVAudioFormat(streamDescription: &mutable),
              let newConverter = AVAudioConverter(from: format, to: targetFormat) else {
            throw TapError.coreAudio(stage: "converter setup", status: kAudioFormatUnsupportedDataFormatError)
        }
        sourceFormat = format
        converter = newConverter
    }

    /// Listener queue == IO queue, so swapping the converter can't race deliver().
    private func handleFormatChange() {
        guard let asbd = try? readTapFormat() else { return }
        if let current = sourceFormat,
           current.sampleRate == asbd.mSampleRate,
           current.channelCount == asbd.mChannelsPerFrame { return }
        try? rebuildConverter(from: asbd)
        nextSampleTime = -1  // the device clock may restart with the new rate
        AudioCaptureManager.oslog.log("system tap format changed — now \(asbd.mSampleRate, privacy: .public) Hz ×\(asbd.mChannelsPerFrame, privacy: .public)ch")
    }

    // MARK: - Helpers

    /// The Core Audio process object for a PID, needed for the tap's exclude list.
    private static func processObject(forPID pid: Int32) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID)
        }
        guard err == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }
}
