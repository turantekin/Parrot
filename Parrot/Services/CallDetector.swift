import AppKit
import CoreAudio

/// Notices calls starting and ending in other apps, so Parrot can offer to
/// record without the user remembering to press a button.
///
/// The signal is the microphone: a Zoom, Meet, Teams or FaceTime call holds
/// the mic open for as long as it lasts. Core Audio's process list (macOS
/// 14.2+) says which process is capturing input, without any permission —
/// it's the same information behind the orange mic dot in the menu bar.
/// Parrot never hears that audio; it only learns that the mic is in use.
///
/// Split in two: `MicActivity` reads Core Audio; `CallDetector` is a pure
/// state machine over those readings (debounce, own-mic exclusion, end
/// detection), covered by the logic harness.
enum MicActivity {

    /// Bundle IDs of other processes capturing audio input right now
    /// (possibly duplicated, callers dedupe). Nil when this macOS can't say
    /// which process holds the mic (before 14.2) — see `defaultInputInUse`.
    static func inputProcesses(excludingPID ownPID: pid_t = getpid()) -> [String]? {
        guard #available(macOS 14.2, *) else { return nil }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        var apps: [String] = []
        for id in ids where uint32(id, kAudioProcessPropertyIsRunningInput) == 1 {
            let pid = processPID(id)
            if pid == ownPID { continue }
            if let bundleID = string(id, kAudioProcessPropertyBundleID), !bundleID.isEmpty {
                apps.append(bundleID)
            } else if let pid, let app = NSRunningApplication(processIdentifier: pid),
                      let bundleID = app.bundleIdentifier {
                apps.append(bundleID)
            } else {
                apps.append(CallDetector.unknownApp)
            }
        }
        return apps
    }

    /// Pre-14.2 fallback: whether ANY process (us included) uses the default
    /// input device. Only meaningful while Parrot itself isn't recording.
    static func defaultInputInUse() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &deviceID) == noErr, deviceID != 0 else { return false }
        return uint32(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    /// Other apps using the mic, as best this macOS can tell.
    static func snapshot(isRecording: Bool) -> [String] {
        if let apps = inputProcesses() { return apps }
        // Can't tell who holds the mic, and while we record it's us.
        return (!isRecording && defaultInputInUse()) ? [CallDetector.unknownApp] : []
    }

    // MARK: Core Audio property readers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func processPID(_ object: AudioObjectID) -> pid_t? {
        guard #available(macOS 14.2, *) else { return nil }
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        // CFString reference through an Unmanaged slot (see
        // AudioCaptureManager.defaultDeviceName for why not &CFString).
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = ref?.takeRetainedValue() else { return nil }
        return value as String
    }
}

/// Pure state machine: mic readings in, "a call started / ended" out.
struct CallDetector {

    enum Event: Equatable {
        /// Another app has held the mic for `startDebounce`: a call, most likely.
        case callStarted(app: String)
        /// During a recording, the call app let go of the mic for
        /// `endDebounce`: the call is over, most likely.
        case callEnded
    }

    /// Placeholder when Core Audio can't name the process.
    static let unknownApp = "?"

    /// Long enough that a dictation burst or a voice-message recording
    /// doesn't read as a call; short enough to catch the first sentence.
    var startDebounce: TimeInterval = 5
    /// Calls drop the mic briefly on device switches and reconnects; only a
    /// sustained release means the call ended.
    var endDebounce: TimeInterval = 20

    private(set) var activeSince: Date?
    private(set) var quietSince: Date?
    /// `callStarted` already fired for the current stretch of mic use (or a
    /// recording covered it) — one prompt per call, never a nag.
    private(set) var announced = false
    /// A call app held the mic at some point during the current recording:
    /// only then can the recording's call "end". A recording of an in-person
    /// meeting (no call app) must never be told its call ended.
    private(set) var sawCallWhileRecording = false

    /// System processes that capture input without being a call.
    static let builtInIgnored: [String] = [
        "com.uygar.parrot",
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech",
        "com.apple.assistantd",
        "com.apple.corespeechd",
        "com.apple.Siri",
        "com.apple.accessibility.heard",
        "com.apple.accessibility.AccessibilityUIServer",
        "com.apple.VoiceOver",
        "com.apple.dictation",
    ]

    /// The apps that count, after the ignore lists. Helper processes are
    /// folded into their app ("com.google.Chrome.helper" → Chrome) so an
    /// ignore of Chrome covers its helpers.
    static func relevantApps(_ raw: [String], ignored: Set<String>) -> [String] {
        var seen: [String] = []
        for bundle in raw {
            let app = normalizedAppID(bundle)
            let isIgnored = (builtInIgnored + Array(ignored)).contains {
                app == $0 || app.hasPrefix($0 + ".")
            }
            if !isIgnored, !seen.contains(app) { seen.append(app) }
        }
        return seen
    }

    /// Strips helper suffixes so a browser's audio helper reads as the browser.
    static func normalizedAppID(_ bundle: String) -> String {
        var id = bundle
        for suffix in [".helper.Renderer", ".helper.GPU", ".helper.Plugin", ".helper", ".Helper",
                       ".framework.AlertNotificationService"] where id.hasSuffix(suffix) {
            id = String(id.dropLast(suffix.count))
        }
        // Safari (and any WebKit app) captures through the shared WebKit GPU
        // process; the call is almost always in Safari.
        if id.hasPrefix("com.apple.WebKit") { return "com.apple.Safari" }
        // FaceTime audio runs in the conferencing daemon.
        if id == "com.apple.avconferenced" { return "com.apple.FaceTime" }
        return id
    }

    /// A friendly name for prompts ("Zoom", "Chrome").
    static func displayName(for appID: String) -> String {
        let known: [(String, String)] = [
            ("us.zoom", "Zoom"),
            ("com.microsoft.teams", "Microsoft Teams"),
            ("com.apple.FaceTime", "FaceTime"),
            ("com.tinyspeck.slackmacgap", "Slack"),
            ("com.google.Chrome", "Chrome"),
            ("com.apple.Safari", "Safari"),
            ("company.thebrowser", "Arc"),
            ("com.microsoft.edgemac", "Edge"),
            ("org.mozilla.firefox", "Firefox"),
            ("com.brave.Browser", "Brave"),
            ("com.hnc.Discord", "Discord"),
            ("Cisco-Systems.Spark", "Webex"),
            ("com.cisco.webexmeetingsapp", "Webex"),
            ("com.skype", "Skype"),
            ("net.whatsapp.WhatsApp", "WhatsApp"),
            ("desktop.WhatsApp", "WhatsApp"),
            ("ru.keepcoder.Telegram", "Telegram"),
            ("com.loom.desktop", "Loom"),
        ]
        if let hit = known.first(where: { appID == $0.0 || appID.hasPrefix($0.0) }) { return hit.1 }
        if appID == unknownApp { return "Another app" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return appID.split(separator: ".").last.map(String.init) ?? appID
    }

    /// Feeds one reading. `apps` must already be filtered by `relevantApps`.
    mutating func update(now: Date, apps: [String], isRecording: Bool) -> Event? {
        if let app = apps.first {
            quietSince = nil
            if activeSince == nil { activeSince = now }
            if isRecording {
                // Already recording: nothing to offer, but remember a call
                // is on so its end can be noticed.
                sawCallWhileRecording = true
                announced = true
                return nil
            }
            if !announced, let since = activeSince, now.timeIntervalSince(since) >= startDebounce {
                announced = true
                return .callStarted(app: app)
            }
            return nil
        }

        // Nobody else holds the mic.
        activeSince = nil
        announced = false
        guard isRecording, sawCallWhileRecording else {
            if !isRecording { sawCallWhileRecording = false }
            quietSince = nil
            return nil
        }
        guard let since = quietSince else {
            quietSince = now
            return nil
        }
        if now.timeIntervalSince(since) >= endDebounce {
            sawCallWhileRecording = false
            quietSince = nil
            return .callEnded
        }
        return nil
    }
}
