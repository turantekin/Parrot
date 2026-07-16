import AVFoundation
import AppKit
import CoreGraphics

/// The one place that decides how to ask for Screen Recording / Microphone.
/// Both the onboarding permissions step and the record-button preflight route
/// through here, so the "first ask shows the OS prompt AND opens System
/// Settings on top of it" double-dialog bug can't come back.
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
            openSettings(pane: "Privacy_ScreenCapture")
        }
        return step
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
