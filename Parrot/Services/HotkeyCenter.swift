import AppKit
import Carbon.HIToolbox

struct HotkeyBinding: Equatable, Codable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    var display: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyName(keyCode))
        return parts.joined()
    }

    var isReserved: Bool {
        carbonModifiers == UInt32(cmdKey)
            && [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_V, kVK_Space, kVK_Tab].contains(Int(keyCode))
    }

    static func from(event: NSEvent) -> HotkeyBinding? {
        guard event.type == .keyDown else { return nil }
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let function: Set<UInt32> = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        ]
        guard mods != 0 || function.contains(code) else { return nil }
        return HotkeyBinding(keyCode: code, carbonModifiers: mods)
    }

    static func slot(using binding: HotkeyBinding, excluding: HotkeySlot) -> HotkeySlot? {
        HotkeySlot.allCases.first {
            $0 != excluding && load(key: $0.defaultsKey) == binding
        }
    }

    static func load(key: String) -> HotkeyBinding? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    func save(key: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_ANSI_0: "0"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: "Key \(code)"
        }
    }
}

enum HotkeySlot: UInt32, CaseIterable {
    /// Hands-free: press to start, press again to stop and paste.
    case dictation = 1
    case transformLocal = 2
    case transformCloud = 3
    /// Push-to-talk: hold to dictate, release to stop and paste.
    case dictationHold = 4
    case pasteLast = 5

    var defaultsKey: String {
        switch self {
        case .dictation: "hotkey.dictation"
        case .transformLocal: "hotkey.transformLocal"
        case .transformCloud: "hotkey.transformCloud"
        case .dictationHold: "hotkey.dictationHold"
        case .pasteLast: "hotkey.pasteLast"
        }
    }

    var label: String {
        switch self {
        case .dictation: "Hands-free dictation"
        case .transformLocal: "Transform — local"
        case .transformCloud: "Transform — cloud"
        case .dictationHold: "Hold to dictate"
        case .pasteLast: "Paste last transcript"
        }
    }
}

/// Global Carbon hotkeys. Unbound by default — the user records them in Settings.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onDictation: (() -> Void)?
    var onDictationHoldStart: (() -> Void)?
    var onDictationHoldEnd: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onTransformLocal: (() -> Void)?
    var onTransformCloud: (() -> Void)?
    private(set) var failedSlots: Set<HotkeySlot> = []

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    func start() {
        installHandler()
        reload()
    }

    func reload() {
        unregisterAll()
        failedSlots = []
        for slot in HotkeySlot.allCases {
            register(slot, HotkeyBinding.load(key: slot.defaultsKey))
        }
        NotificationCenter.default.post(name: .parrotHotkeysChanged, object: nil)
    }

    private func register(_ slot: HotkeySlot, _ binding: HotkeyBinding?) {
        guard let binding else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x50525431), id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.carbonModifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            failedSlots.insert(slot)
        }
    }

    private func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs = []
    }

    private func installHandler() {
        guard handler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { center.handle(id: hotKeyID.id, released: released) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 2, &eventTypes,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func handle(id: UInt32, released: Bool) {
        switch HotkeySlot(rawValue: id) {
        case .dictationHold:
            if released { onDictationHoldEnd?() } else { onDictationHoldStart?() }
        case .dictation:
            if !released { onDictation?() }
        case .pasteLast:
            if !released { onPasteLast?() }
        case .transformLocal:
            if !released { onTransformLocal?() }
        case .transformCloud:
            if !released { onTransformCloud?() }
        case nil: break
        }
    }
}
