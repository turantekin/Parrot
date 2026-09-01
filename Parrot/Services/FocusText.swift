import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Read/write the frontmost field's selection. Used so dictation and
/// transforms land in the text field the user is actually typing in.
enum FocusText {
    enum Delivery: Equatable {
        case inserted
        case copied
    }

    static func resolveSource(selected: String?, clipboard: String?) -> String? {
        let sel = selected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sel.isEmpty { return sel }
        let clip = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clip.isEmpty ? nil : clip
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func selectedText() -> String? {
        guard isTrusted, let focused = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }

    static var autoPasteEnabled: Bool {
        UserDefaults.standard.object(forKey: FeatureProcessing.autoPasteKey) as? Bool ?? true
    }

    /// Copy always. When auto-paste is on, replace the focused selection
    /// (or synthesize ⌘V) so the words land in the field the user is in.
    @discardableResult
    static func deliver(_ text: String) -> Delivery {
        ClipboardOut.copy(text)
        guard autoPasteEnabled else { return .copied }
        _ = ensureTrusted()
        if replaceSelection(text) { return .inserted }
        if pasteCommand() { return .inserted }
        return .copied
    }

    static func replaceSelection(_ text: String) -> Bool {
        guard isTrusted, let focused = focusedElement() else { return false }
        return AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success
    }

    static func pasteCommand() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success else {
            return nil
        }
        return (focused as! AXUIElement)
    }
}
