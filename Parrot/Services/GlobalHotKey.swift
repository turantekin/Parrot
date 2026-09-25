import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut that works while another app (Zoom, Meet)
/// is in front. Uses Carbon's `RegisterEventHotKey`, which — unlike a global
/// NSEvent monitor — needs no Accessibility permission and works in the
/// sandbox: the app only learns that ITS combo was pressed, never other keys.
///
/// Registration is explicit and short-lived: RecordingManager holds the combo
/// only while a call records, so it never shadows the key in other apps the
/// rest of the time.
final class GlobalHotKey {

    struct Combo: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        /// Menu-style glyphs for help text and Settings ("⌃⌥M").
        let display: String

        static let markMoment = Combo(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(controlKey | optionKey),
            display: "⌃⌥M"
        )
    }

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    private var action: (() -> Void)?

    /// Carbon calls back through a C function pointer that can't capture
    /// context, so live registrations are looked up by id. Only touched on
    /// the main thread (register/unregister come from the main actor, and
    /// application-target hot-key events are delivered on the main thread).
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    /// "PRRT" — our hot-key signature, so we never act on another's event.
    private static let signature: OSType = 0x5052_5254

    init() {
        id = Self.nextID
        Self.nextID += 1
    }

    deinit { unregister() }

    var isRegistered: Bool { hotKeyRef != nil }

    /// Registers `combo`; `action` runs on the main thread on each press.
    /// Returns false if the system refused (the combo is taken by another app).
    @discardableResult
    func register(_ combo: Combo, action: @escaping () -> Void) -> Bool {
        unregister()
        Self.installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Parrot: global shortcut \(combo.display) unavailable (status \(status))")
            return false
        }
        hotKeyRef = ref
        self.action = action
        Self.registry[id] = self
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        action = nil
        Self.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard read == noErr, hkID.signature == GlobalHotKey.signature,
                  let hotKey = GlobalHotKey.registry[hkID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            hotKey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = (status == noErr)
    }
}
