import AppKit
import ApplicationServices

final class FocusedTextInserter {
    func insert(_ text: String) -> String {
        let source = CGEventSource(stateID: .combinedSessionState)
        if AXIsProcessTrusted(), let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            event.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
            event.post(tap: .cghidEventTap)
            return "Accessibility typing"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let v = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        v?.flags = .maskCommand; v?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand; up?.post(tap: .cghidEventTap)
        return "clipboard paste"
    }

    /// Replaces only the unstable tail of a live transcript. This is intentionally opt-in:
    /// individual apps can interpret synthetic backspaces differently.
    func replaceLiveText(previous: String, with next: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let old = Array(previous)
        let new = Array(next)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in prefix..<old.count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
        let suffix = String(new[prefix...])
        guard !suffix.isEmpty else { return true }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { return false }
        event.keyboardSetUnicodeString(stringLength: suffix.utf16.count, unicodeString: Array(suffix.utf16))
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Append confirmed live words only. Unlike replacement, this can never erase text
    /// written before the current dictation started.
    func appendLiveText(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), !text.isEmpty,
              let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .combinedSessionState), virtualKey: 0, keyDown: true) else { return false }
        event.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
        event.post(tap: .cghidEventTap)
        return true
    }
}
