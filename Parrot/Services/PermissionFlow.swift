import AVFoundation
import AppKit
import CoreGraphics

/// The one place that decides how to ask for System Audio (macOS 15+) /
/// Screen Recording (macOS 14) / Microphone. Both the onboarding permissions
/// step and the record-button preflight route through here, so the "first ask
/// shows the OS prompt AND opens System Settings on top of it" double-dialog
/// bug can't come back.
enum PermissionFlow {

    enum ScreenCaptureStep: Equatable {
        case granted        // preflight says we're good
        case promptShown    // first ever ask: the single official OS prompt was posted
        case openSettings   // asked before, still not granted: deep-link to Settings
    }

    /// Set the first time either call site posts the OS prompt. Needed because
    /// `CGRequestScreenCaptureAccess()` returns the CURRENT status (false on a
    /// first ask) — it never waits for the user's answer, so its return value
    /// can't distinguish "prompt just shown" from "previously denied".
    static let screenAskedKey = "hasRequestedScreenCapture"

    /// Pure decision — covered by `--profile-test`.
    static func nextScreenCaptureStep(preflightGranted: Bool, askedBefore: Bool) -> ScreenCaptureStep {
        if preflightGranted { return .granted }
        return askedBefore ? .openSettings : .promptShown
    }

    @discardableResult
    static func requestScreenCapture() -> ScreenCaptureStep {
        let step = nextScreenCaptureStep(
            preflightGranted: CGPreflightScreenCaptureAccess(),
            askedBefore: UserDefaults.standard.bool(forKey: screenAskedKey)
        )
        switch step {
        case .granted:
            break
        case .promptShown:
            UserDefaults.standard.set(true, forKey: screenAskedKey)
            _ = CGRequestScreenCaptureAccess()
        case .openSettings:
            // ALWAYS re-request before deep-linking. If the user (or a TCC
            // reset) wiped the grant back to not-determined, this posts the
            // official prompt again instead of stranding them in a Settings
            // pane; and in the genuinely-denied case it is a silent no-op that
            // still (re)registers Parrot's row in the Settings list — without
            // it, the pane we open may not even show the app. Worst case
            // (reset + this flag still set) the prompt and Settings both
            // appear; that beats the dead-end loop it replaces.
            _ = CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() {
                openSettings(pane: "Privacy_ScreenCapture")
            }
        }
        return step
    }

    // MARK: - System audio (macOS 15+, Core Audio process tap)

    /// macOS 15+ captures system audio through a process tap under TCC's
    /// "System Audio Recording Only" category — no Screen Recording rights, no
    /// scary prompt, no periodic macOS re-confirmation. The catch, measured
    /// on-device: there is NO status/preflight API for this category, and an
    /// unauthorized tap is created without error — it just delivers silence.
    /// So status is inferred: the first nonzero buffer through a tap proves the
    /// grant (AudioCaptureManager sets `tapProvenKey`), and until then the flow
    /// stays optimistic — blocking a recording on a grant we cannot read would
    /// hold the user's data hostage to a guess. A denied user still gets their
    /// mic track, a dead system level bar, and one Settings deep-link.
    static let tapProvenKey = "systemAudioTapProven"
    static let tapAskedKey = "hasRequestedSystemAudioTap"
    static let tapSettingsShownKey = "systemAudioSettingsShown"

    /// Pure decision — covered by `--profile-test`. `screenGranted` counts as
    /// granted because ScreenCaptureKit remains a full fallback backend.
    static func nextSystemAudioStep(proven: Bool, screenGranted: Bool,
                                    askedBefore: Bool, settingsShownBefore: Bool) -> ScreenCaptureStep {
        if proven || screenGranted { return .granted }
        if !askedBefore { return .promptShown }
        if !settingsShownBefore { return .openSettings }
        // Asked and deep-linked once already. The grant is unreadable, so stop
        // gatekeeping: start the recording and let the level bar tell the truth.
        return .granted
    }

    @available(macOS 15.0, *)
    @discardableResult
    static func requestSystemAudioCapture() -> ScreenCaptureStep {
        let defaults = UserDefaults.standard
        let step = nextSystemAudioStep(
            proven: defaults.bool(forKey: tapProvenKey),
            screenGranted: CGPreflightScreenCaptureAccess(),
            askedBefore: defaults.bool(forKey: tapAskedKey),
            settingsShownBefore: defaults.bool(forKey: tapSettingsShownKey)
        )
        switch step {
        case .granted:
            break
        case .promptShown:
            defaults.set(true, forKey: tapAskedKey)
            SystemAudioTap.fireAuthorizationPrompt()
        case .openSettings:
            defaults.set(true, forKey: tapSettingsShownKey)
            // Re-fire first: if a TCC reset put us back to not-determined this
            // posts the official prompt again; if genuinely denied it is a
            // silent no-op that keeps Parrot's row present in the pane.
            SystemAudioTap.fireAuthorizationPrompt()
            // On macOS 15+ this anchor opens the combined
            // "Screen & System Audio Recording" pane, which hosts both lists.
            openSettings(pane: "Privacy_ScreenCapture")
        }
        return step
    }

    /// Silent status for onboarding UI — must never fire a prompt.
    static func systemAudioLooksGranted() -> Bool {
        UserDefaults.standard.bool(forKey: tapProvenKey) || CGPreflightScreenCaptureAccess()
    }

    /// notDetermined → the one official OS prompt; denied/restricted → Settings.
    /// Returns whether the mic ended up authorized.
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            openSettings(pane: "Privacy_Microphone")
            return false
        }
    }

    static func openSettings(pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
