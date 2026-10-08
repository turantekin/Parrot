import Sparkle
import UserNotifications

/// The words and the one decision behind "an update is waiting".
enum UpdateNotice {
    static func title(version: String) -> String { "Parrot \(version) is perched and ready" }
    static let body = "It moves in next time you quit Parrot. Or right now, if you can't wait."
    static let busyBody = "Finish your call first. Parrot will be right here."

    enum Action: Equatable { case post, hold, skip }

    /// Tell now, wait for the call to end, or stay quiet (already told).
    static func onReady(version: String, alreadyPosted: String?, busy: Bool) -> Action {
        if alreadyPosted == version { return .skip }
        return busy ? .hold : .post
    }
}

/// Self-updating, via Sparkle.
///
/// Replaces the hand-rolled GitHub poll and its download banner. Sparkle
/// fetches the appcast (SUFeedURL), verifies every update against our EdDSA
/// public key (SUPublicEDKey) so a compromised feed can't push anything users
/// would accept, and installs on quit — including the awkward part nobody
/// should write twice: replacing an app while it's running.
///
/// Installing happens through Sparkle's installer XPC service, which runs
/// outside our sandbox; that's what the two mach-lookup exceptions in the
/// entitlements are for. A recording is never interrupted, because Sparkle
/// only swaps the bundle when the app quits, and Restart now refuses during
/// a call.
///
/// As the updater's delegate it also tells people an update is waiting:
/// Sparkle's silent mode shows nothing, and Parrot is an app people rarely quit.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater(startSparkle: true)

    static let readyCategory = "PARROT_UPDATE_READY"
    static let restartAction = "PARROT_RESTART_NOW"
    private static let readyID = "parrot-update-ready"
    private static let busyID = "parrot-update-busy"

    /// nil in unbundled dev builds (`swift build` with no Info.plist, and any
    /// harness run) — starting Sparkle without a feed just logs errors, and the
    /// CLI harnesses have no business talking to the network.
    private var controller: SPUStandardUpdaterController?
    /// Set at launch by RecordingManager: true while a call records.
    var isBusy: () -> Bool = { false }
    /// The downloaded update waiting for a quit, and Sparkle's install-now handle.
    private var pending: (version: String, install: () -> Void)?
    private(set) var postedVersion: String?
    private(set) var lastNoticeBody: String?

    init(startSparkle: Bool) {
        super.init()
        guard startSparkle, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        // A notice from before the last quit is stale: that update is installed now.
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.readyID, Self.busyID])
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Menu and Settings both land here. Sparkle owns the whole conversation,
    /// including the "you're already up to date" case the old button couldn't
    /// express.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// False in dev builds, so UI can hide controls that would do nothing.
    var isAvailable: Bool { controller != nil }

    /// Whether updates install themselves. Bound to the Settings toggle: on by
    /// default (Info.plist SUAutomaticallyUpdate), because an update nobody
    /// clicks is an update nobody gets.
    var automaticallyUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// The running bundle's version. "dev" for an unbundled binary — the
    /// version row, the sidebar footer and bug reports all read this.
    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Update waiting

    /// Sparkle downloaded an update and will install it on quit. Returning
    /// true takes over telling the user (and pauses further checks until the
    /// next launch, which is fine: this one installs on quit either way).
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated { updateReady(version: version, install: immediateInstallHandler) }
        return true
    }

    func updateReady(version: String, install: @escaping () -> Void) {
        pending = (version, install)
        if UpdateNotice.onReady(version: version, alreadyPosted: postedVersion, busy: isBusy()) == .post {
            postReady(version)
        }
    }

    /// RecordingManager calls this when a call, its report or an import
    /// finishes: a held notice goes out once nothing is left running.
    func becameIdle() {
        guard let pending,
              UpdateNotice.onReady(version: pending.version, alreadyPosted: postedVersion, busy: isBusy()) == .post
        else { return }
        postReady(pending.version)
    }

    /// The notification's Restart now. Never during a call or while its
    /// report is being written: relaunching then would cut that work short.
    func restartNow() {
        guard let pending else { return }
        if isBusy() {
            notify(id: Self.busyID, title: UpdateNotice.title(version: pending.version),
                   body: UpdateNotice.busyBody, category: nil)
            // Clicking the action removed the notice; offer it again when idle.
            postedVersion = nil
            return
        }
        pending.install()
    }

    private func postReady(_ version: String) {
        postedVersion = version
        notify(id: Self.readyID, title: UpdateNotice.title(version: version),
               body: UpdateNotice.body, category: Self.readyCategory)
    }

    /// Posts like CallWatcher does. The bare harness binary has no bundle and
    /// UNUserNotificationCenter would crash there, so it only records the body.
    private func notify(id: String, title: String, body: String, category: String?) {
        lastNoticeBody = body
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // No sound: it may arrive during a call Parrot isn't recording.
        if let category { content.categoryIdentifier = category }
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                NSLog("Parrot: update notification failed, \(error.localizedDescription)")
            }
        }
    }
}
