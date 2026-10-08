import Foundation

/// Speakers without headphones: the mic re-hears the other side, and what
/// the echo canceller leaves behind decodes as "Me" lines. Often it's English
/// filler ("Yeah", "I just") that shares no words with what they said, so the
/// text dedupe can't catch it (#98). Its loudness still follows theirs,
/// syllable by syllable, a beat later. Your own voice doesn't. Pure, so the
/// live loop and `--echo-replay` share it.
enum EchoGate {
    /// 20 ms frames at 16 kHz.
    static let hop = 320
    /// Me trails Them by up to 300 ms (output + input latency)...
    static let maxLag = 15
    /// ...or sits up to 100 ms early: each track's first buffer is placed on
    /// the clock only to within a buffer (old speaker calls: 20-40 ms early).
    static let maxLead = 5

    struct Score {
        /// Correlation of the two loudness curves at the best delay, -1...1.
        var follows: Float
        /// That delay, in frames.
        var lag: Int
        /// Share of the clip the other side was talking, 0...1.
        var themTalking: Float
    }

    /// A frame of theirs above this level counts as them talking.
    static let talkingFloor: Float = 0.001
    /// Echo: they were talking during the clip, and its loudness tracked
    /// theirs closely. Your own words over theirs rarely track them at all.
    /// Talking is counted per frame, so the gaps between syllables count as
    /// silence: fluent speech scores about 0.4-0.7.
    static let minTalking: Float = 0.3
    static let minFollows: Float = 0.6

    /// A whole call's envelope, built as audio arrives in any buffer size.
    struct Levels {
        private(set) var frames: [Float] = []
        private var sum: Float = 0
        private var count = 0

        mutating func add(_ samples: ArraySlice<Float>) {
            for x in samples {
                sum += abs(x)
                count += 1
                if count == hop {
                    frames.append(sum / Float(hop))
                    sum = 0
                    count = 0
                }
            }
        }
    }

    /// Mean level of each whole 20 ms frame.
    static func envelope(_ samples: ArraySlice<Float>) -> [Float] {
        stride(from: samples.startIndex, to: samples.endIndex - hop + 1, by: hop).map { i in
            samples[i ..< i + hop].reduce(0) { $0 + abs($1) } / Float(hop)
        }
    }

    /// The mic hears the speakers at all: correlation of the two tracks over
    /// the last minute. Headphone calls sit at -0.3...0.1 (turn-taking pulls
    /// it below zero); speaker calls at 0.5...0.9 on the owner's store.
    static let minBleed: Float = 0.3
    /// One minute of frames for the bleed check; it needs 10 s to decide.
    static let bleedWindow = 3000
    static let minBleedFrames = 500

    /// #98: on a call where I do most of the talking, my turns in their
    /// silences drag `bleed` below zero and the gate never fires. So also ask
    /// whether the mic follows them while they talk, over the minute BEFORE
    /// the clip (a clip can't vouch for itself). Owner's store: headphone
    /// calls p95 0.27, two lines of 2,443 over 0.45; speaker calls 0.6...0.95.
    /// Needs 2 s of them talking: with less, a headphone call scored up to 0.5.
    static let minTalkBleed: Float = 0.45
    static let minBleedTalkFrames = 100

    struct Verdict {
        var clip: Score
        var bleed: Score
        /// The while-they-talk score, from before the clip.
        var talkBleed: Score
        var isEcho: Bool
    }

    /// The live gate and `--echo-replay`: `mic` and `them` are whole-call
    /// envelopes on one clock, and the clip starts at frame `startFrame`.
    static func check(clip: [Float], mic: [Float], them: [Float], at startFrame: Int) -> Verdict {
        let end = min(mic.count, startFrame + clip.count / hop)
        let from = max(maxLag, end - bleedWindow)  // room for every delay before it
        let none = Score(follows: 0, lag: 0, themTalking: 0)
        let bleed = end - from < minBleedFrames ? none
            : follow(Array(mic[from..<end]), them: them, at: from, lags: -maxLead...maxLag)
        let start = min(mic.count, startFrame)
        let talkFrom = max(maxLag, start - bleedWindow)
        let talkBleed = start - talkFrom < minBleedFrames ? none
            : follow(Array(mic[talkFrom..<start]), them: them, at: talkFrom, lags: -maxLead...maxLag, whileTheyTalk: true)
        let hears = bleed.follows >= minBleed ? bleed : talkBleed.follows >= minTalkBleed ? talkBleed : nil
        // Echo arrives at the call's own delay. Searching every delay let short
        // clips match by chance (best of 21 tries over 25 frames).
        let lag = (hears ?? bleed).lag
        let near = max(-maxLead, lag - 2)...min(maxLag, lag + 2)
        let clip = follow(envelope(clip[...]), them: them, at: startFrame, lags: near)
        let echo = hears != nil && clip.themTalking >= minTalking && clip.follows >= minFollows
        return Verdict(clip: clip, bleed: bleed, talkBleed: talkBleed, isEcho: echo)
    }

    /// Best correlation of a mic envelope starting at `start` with theirs over
    /// `lags` (positive: the mic is later). Compared in log level, so a quiet
    /// echo and a loud original line up. Too few frames to judge reads as 0.
    /// `whileTheyTalk` scores only the frames where they're talking.
    private static func follow(_ mine: [Float], them: [Float], at start: Int, lags: ClosedRange<Int>,
                               whileTheyTalk: Bool = false) -> Score {
        let n = min(mine.count, them.count - start - max(0, -lags.lowerBound))
        guard start >= 0, n >= 10 else { return Score(follows: 0, lag: 0, themTalking: 0) }
        func level(_ x: Float) -> Float { log10(x + 1e-4) }
        let a = mine.prefix(n).map(level)
        var best = Score(follows: -1, lag: 0, themTalking: 0)
        for lag in lags where start - lag >= 0 {
            let theirs = them[(start - lag) ..< (start - lag + n)]
            let talks = theirs.map { $0 > talkingFloor }
            let talking = talks.filter { $0 }.count
            let r: Float
            if whileTheyTalk {
                guard talking >= minBleedTalkFrames else { continue }
                let pairs = zip(a, zip(theirs, talks)).filter { $0.1.1 }
                r = pearson(pairs.map(\.0), pairs.map { level($0.1.0) })
            } else {
                r = pearson(a, theirs.map(level))
            }
            if r > best.follows {
                best = Score(follows: r, lag: lag, themTalking: Float(talking) / Float(n))
            }
        }
        return best
    }

    private static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var ab: Float = 0, aa: Float = 0, bb: Float = 0
        for (x, y) in zip(a, b) {
            ab += (x - ma) * (y - mb)
            aa += (x - ma) * (x - ma)
            bb += (y - mb) * (y - mb)
        }
        guard aa > 0, bb > 0 else { return 0 }
        return ab / (aa * bb).squareRoot()
    }
}
