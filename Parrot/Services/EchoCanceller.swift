import Foundation
import CSpeexDSP

/// Acoustic echo canceller (SpeexDSP MDF).
///
/// When the call plays through the Mac's speakers, the mic picks it up and the
/// other person's voice would be transcribed a second time as "Me". Parrot already
/// captures that exact speaker output as the system-audio stream (via
/// ScreenCaptureKit), so we use it as the AEC *reference* and subtract it from the
/// mic — the same near-end + far-end approach Zoom/Meet use, just with the
/// reference we capture instead of one we play.
///
/// Everything works on 16 kHz mono, 10 ms frames (160 samples), matching the rest
/// of the pipeline. Fail-safe: if the canceller can't initialise, `process` returns
/// the mic audio untouched — the mic is never silenced.
final class EchoCanceller {
    private var echoState: OpaquePointer?
    private var preprocess: OpaquePointer?

    private let frameSize = 160          // 10 ms @ 16 kHz
    private let filterTail = 2048        // ~128 ms echo tail
    private let sampleRate: Int32 = 16000

    /// Far-end reference (system audio) waiting to be paired with mic frames, and
    /// the mic accumulator. Int16 is what SpeexDSP operates on.
    private var reference: [Int16] = []
    private var micAccum: [Int16] = []
    private let lock = NSLock()
    private let maxReference = 16000 * 5  // cap the reference ring at 5 s

    var isActive: Bool { echoState != nil }

    init() {
        echoState = speex_echo_state_init(Int32(frameSize), Int32(filterTail))
        var rate = sampleRate
        if let echoState {
            _ = speex_echo_ctl(echoState, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        }
        preprocess = speex_preprocess_state_init(Int32(frameSize), sampleRate)
        if let preprocess, let echoState {
            _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE,
                                     UnsafeMutableRawPointer(echoState))
        }
    }

    deinit {
        if let echoState { speex_echo_state_destroy(echoState) }
        if let preprocess { speex_preprocess_state_destroy(preprocess) }
    }

    /// Feed far-end reference samples (the system audio). Called from the SCK
    /// callback, concurrently with `process`.
    func pushReference(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let ints = samples.map(Self.toInt16)
        lock.lock()
        reference.append(contentsOf: ints)
        if reference.count > maxReference {
            reference.removeFirst(reference.count - maxReference)
        }
        lock.unlock()
    }

    /// Cancel echo from a mic buffer. Returns cleaned samples for whatever whole
    /// 10 ms frames completed (possibly empty if fewer than 160 samples have
    /// accumulated). On any failure, returns the input unchanged.
    func process(mic samples: [Float]) -> [Float] {
        guard let echoState, let preprocess else { return samples }

        let micInts = samples.map(Self.toInt16)

        // Pair each mic frame with a reference frame under the lock, then run the
        // (heavier) DSP outside it so pushReference isn't blocked.
        var pairs: [([Int16], [Int16])] = []
        lock.lock()
        micAccum.append(contentsOf: micInts)
        while micAccum.count >= frameSize {
            let micFrame = Array(micAccum.prefix(frameSize))
            micAccum.removeFirst(frameSize)
            let refFrame: [Int16]
            if reference.count >= frameSize {
                refFrame = Array(reference.prefix(frameSize))
                reference.removeFirst(frameSize)
            } else {
                refFrame = [Int16](repeating: 0, count: frameSize)
            }
            pairs.append((micFrame, refFrame))
        }
        lock.unlock()

        guard !pairs.isEmpty else { return [] }

        var out: [Float] = []
        out.reserveCapacity(pairs.count * frameSize)
        for (micFrame, refFrame) in pairs {
            var outFrame = [Int16](repeating: 0, count: frameSize)
            micFrame.withUnsafeBufferPointer { mic in
                refFrame.withUnsafeBufferPointer { ref in
                    speex_echo_cancellation(echoState, mic.baseAddress, ref.baseAddress, &outFrame)
                }
            }
            _ = speex_preprocess_run(preprocess, &outFrame)
            out.append(contentsOf: outFrame.map(Self.toFloat))
        }
        return out
    }

    private static func toInt16(_ f: Float) -> Int16 {
        Int16(max(-1, min(1, f)) * 32767)
    }
    private static func toFloat(_ i: Int16) -> Float {
        Float(i) / 32767
    }
}
