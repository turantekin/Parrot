import AppKit
import UserNotifications

/// What Parrot does when it notices a call starting in another app.
enum AutoRecordMode: String, CaseIterable, Identifiable {
    case off
    /// Default: a notification (and an in-app banner) offers to record.
    case ask
    /// Start recording on its own. Recording people has legal weight, so
    /// this is never the default and Settings says so.
    case auto

    static let defaultsKey = "autoRecordMode"
    var id: String { rawValue }

    static var current: AutoRecordMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AutoRecordMode.init) ?? .ask
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .ask: "Ask me"
        case .auto: "Record automatically"
        }
    }
}

/// Watches for calls (via `CallDetector`), offers to record them, offers to
/// stop when they end, and reminds about calendar meetings. Owns the app's
/// notification actions. Created and started by RecordingManager.prepare.
@MainActor
@Observable
final class CallWatcher: NSObject, UNUserNotificationCenterDelegate {

    /// A detected call waiting for an answer — drives the in-app banner and
    /// the menu-bar item alongside the notification.
    struct Prompt: Equatable {
        enum Kind: Equatable { case start, stop }
        var kind: Kind
        /// Bundle ID of the call app ("us.zoom.xos").
        var appID: String
        var appName: String
        /// The calendar event the call matched, if any.
        var eventTitle: String?
    }

    private(set) var prompt: Prompt?

    @ObservationIgnored weak var recordingManager: RecordingManager?
    @ObservationIgnored private var detector = CallDetector()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastReminderCheck = Date.distantPast
    @ObservationIgnored private var remindedEventIDs = Set<String>()
    /// The current recording was started by auto mode, so auto mode may
    /// stop it too. A recording the user started is only ever offered a stop.
    @ObservationIgnored private var autoStarted = false

    static let ignoredAppsKey = "callDetectIgnoredApps"
    static let pollInterval: TimeInterval = 2

    // Notification identifiers + actions.
    static let startCategory = "PARROT_CALL_START"
    static let stopCategory = "PARROT_CALL_END"
    static let meetingCategory = "PARROT_MEETING_SOON"
    static let recordAction = "PARROT_RECORD"
    static let ignoreAppAction = "PARROT_IGNORE_APP"
    static let stopAction = "PARROT_STOP"
    static let keepAction = "PARROT_KEEP"
    static let promptID = "parrot-call-prompt"

    // MARK: Lifecycle

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.startCategory, actions: [
                UNNotificationAction(identifier: Self.recordAction, title: "Record", options: []),
                UNNotificationAction(identifier: Self.ignoreAppAction, title: "Never for This App", options: []),
            ], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.stopCategory, actions: [
                UNNotificationAction(identifier: Self.stopAction, title: "Stop Recording", options: []),
                UNNotificationAction(identifier: Self.keepAction, title: "Keep Recording", options: []),
            ], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.meetingCategory, actions: [
                UNNotificationAction(identifier: Self.recordAction, title: "Record Now", options: []),
            ], intentIdentifiers: [], options: []),
        ])
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static var ignoredApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: ignoredAppsKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: ignoredAppsKey) }
    }

    // MARK: Polling

    private func tick() {
        guard let manager = recordingManager else { return }
        let mode = AutoRecordMode.current
        let isRecording = manager.isRecording
        if !isRecording { autoStarted = false }
        // A stop prompt outlives its recording only until the recording ends.
        if !isRecording, prompt?.kind == .stop { clearPrompt() }

        if mode != .off {
            let apps = CallDetector.relevantApps(MicActivity.snapshot(isRecording: isRecording),
                                                 ignored: Self.ignoredApps)
            // The call app let go of the mic before anyone answered: the
            // start offer is stale.
            if apps.isEmpty, prompt?.kind == .start { clearPrompt() }
            if let event = detector.update(now: .now, apps: apps, isRecording: isRecording) {
                handle(event, mode: mode)
            }
        }

        if Date.now.timeIntervalSince(lastReminderCheck) >= 30 {
            lastReminderCheck = .now
            checkCalendarReminders()
        }
    }

    private func handle(_ event: CallDetector.Event, mode: AutoRecordMode) {
        guard let manager = recordingManager else { return }
        switch event {
        case .callStarted(let appID):
            // Can't record yet (model still loading, an import running) —
            // an offer we can't honor is worse than none.
            guard manager.transcriptionEngine.isReady, !manager.isBusy else { return }
            let name = CallDetector.displayName(for: appID)
            let eventTitle = manager.calendar.isConnected ? manager.calendar.currentEvent()?.title : nil
            if mode == .auto {
                autoStarted = true
                Task {
                    let started = await manager.startDetectedCall(appID: appID)
                    if started {
                        post(id: Self.promptID, title: "Parrot is recording",
                             body: "Your \(eventTitle.map { "“\($0)” " } ?? "")\(name) call is being recorded.",
                             category: Self.stopCategory)
                    } else {
                        autoStarted = false
                    }
                }
            } else {
                prompt = Prompt(kind: .start, appID: appID, appName: name, eventTitle: eventTitle)
                post(id: Self.promptID, title: "\(name) call started",
                     body: eventTitle.map { "Record “\($0)” with Parrot?" } ?? "Record it with Parrot?",
                     category: Self.startCategory)
            }

        case .callEnded:
            guard manager.isRecording, !manager.isStopping else { return }
            if autoStarted {
                autoStarted = false
                Task {
                    await manager.stopRecording()
                    post(id: Self.promptID, title: "Recording stopped",
                         body: "The call ended. Your report is on its way.", category: nil)
                }
            } else {
                prompt = Prompt(kind: .stop, appID: "", appName: "", eventTitle: nil)
                post(id: Self.promptID, title: "Call ended?",
                     body: "Parrot is still recording.", category: Self.stopCategory)
            }
        }
    }

    // MARK: Answers (banner, menu bar, notification)

    func acceptPrompt() {
        guard let prompt, let manager = recordingManager else { return }
        clearPrompt()
        switch prompt.kind {
        case .start: Task { _ = await manager.startDetectedCall(appID: prompt.appID) }
        case .stop: Task { await manager.stopRecording() }
        }
    }

    func dismissPrompt() {
        clearPrompt()
    }

    /// "Never for This App": stop offering for this app (Settings lists and
    /// restores ignored apps).
    func ignorePromptApp() {
        guard let prompt, prompt.kind == .start, prompt.appID != CallDetector.unknownApp else {
            clearPrompt(); return
        }
        Self.ignoredApps.insert(prompt.appID)
        clearPrompt()
    }

    private func clearPrompt() {
        prompt = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.promptID])
    }

    // MARK: Calendar reminders

    private func checkCalendarReminders() {
        guard let manager = recordingManager, manager.calendar.isConnected,
              UserDefaults.standard.bool(forKey: CalendarService.remindersKey),
              !manager.isRecording else { return }
        let now = Date.now
        let due = CalendarService.dueReminders(
            manager.calendar.events(from: now, to: now.addingTimeInterval(120)),
            now: now, alreadyReminded: remindedEventIDs)
        for event in due {
            remindedEventIDs.insert(event.id)
            let title = event.title.isEmpty ? "Your meeting" : event.title
            post(id: "parrot-meeting-\(event.id.hashValue)", title: "\(title) starts in a minute",
                 body: AutoRecordMode.current == .off
                    ? "Want Parrot to record it?"
                    : "Parrot will offer to record when the call starts.",
                 category: Self.meetingCategory)
        }
    }

    // MARK: Notifications

    private func post(id: String, title: String, body: String, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    // Notifications off: the in-app banner and menu-bar item
                    // still carry the prompt; a dock bounce points at them.
                    NSApp.requestUserAttention(.informationalRequest)
                    return
                }
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                NSLog("Parrot: call notification failed, \(error.localizedDescription)")
            }
        }
    }

    // Show banners even while Parrot is in front (the default hides them).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            self.route(action: action, category: category)
            completionHandler()
        }
    }

    private func route(action: String, category: String) {
        switch action {
        case Self.recordAction:
            if prompt?.kind == .start {
                acceptPrompt()
            } else if let manager = recordingManager, !manager.isRecording {
                // "Record Now" from a meeting reminder: no detected app yet.
                Task { _ = await manager.startDetectedCall(appID: nil) }
            }
        case Self.ignoreAppAction:
            ignorePromptApp()
        case Self.stopAction:
            if let manager = recordingManager, manager.isRecording {
                clearPrompt()
                autoStarted = false
                Task { await manager.stopRecording() }
            }
        case Self.keepAction, UNNotificationDismissActionIdentifier:
            if prompt?.kind == .stop || action == Self.keepAction { clearPrompt() }
        case UNNotificationDefaultActionIdentifier:
            // Clicking the notification itself: bring Parrot forward, where
            // the banner holds the same question.
            NSApp.activate(ignoringOtherApps: true)
        default:
            break
        }
    }
}
