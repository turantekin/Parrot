import Foundation
import Observation

/// One call's live nudges: owns the detector, the Copilot's mood snapshots
/// and the nudge on screen. RecordingManager feeds it; the Copilot panel's
/// banner reads `current`, the floating pill listens to `onShow`.
@MainActor
@Observable
final class LiveNudgeSession {
    nonisolated static let defaultsKey = "liveNudges"
    /// On unless turned off in Settings → Copilot → Live Nudges.
    nonisolated static var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// The latest nudge shown, until dismissed or replaced.
    private(set) var current: Nudge?
    @ObservationIgnored var onShow: ((Nudge) -> Void)?
    @ObservationIgnored private var detector = NudgeDetector()
    @ObservationIgnored private var gauges: [SentimentGauge] = []
    @ObservationIgnored private var snapshots: [MoodSnapshot] = []
    @ObservationIgnored private var nudging = false
    @ObservationIgnored private var active = false

    func start(gauges: [SentimentGauge], nudging: Bool = LiveNudgeSession.isEnabled) {
        detector = NudgeDetector(gauges: gauges)
        self.gauges = gauges
        snapshots = []
        current = nil
        self.nudging = nudging
        active = true
    }

    func add(line: NudgeDetector.Line) {
        guard active, !line.text.isEmpty else { return }
        detector.add(line)
    }

    /// The mood line is kept even with nudges off: it's the report's, not the pill's.
    func add(pass: NudgeDetector.Pass) {
        guard active else { return }
        if !pass.values.isEmpty { snapshots.append(MoodSnapshot(time: pass.time, values: pass.values)) }
        detector.add(pass)
    }

    func tick(now: TimeInterval, lastHeard: [AudioSource: TimeInterval], paused: Bool) {
        guard active, nudging, !paused, let nudge = detector.tick(now: now, lastHeard: lastHeard) else { return }
        current = nudge
        onShow?(nudge)
    }

    func dismiss() {
        current = nil
    }

    /// Ends the call: what to save on the meeting.
    func stop() -> (nudges: [Nudge], timeline: MoodTimeline?) {
        active = false
        current = nil
        return (detector.all, snapshots.isEmpty ? nil : MoodTimeline(gauges: gauges, snapshots: snapshots))
    }
}
