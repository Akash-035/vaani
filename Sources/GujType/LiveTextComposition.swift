import ApplicationServices
import Foundation

/// Diff on extended grapheme clusters, then translate to Accessibility's UTF-16
/// coordinates. Never split a vowel sign, combining mark, surrogate pair or emoji.
struct LiveTextEdit: Equatable {
    let range: NSRange
    let replacement: String

    static func between(_ previous: String, _ next: String) -> LiveTextEdit? {
        guard previous != next else { return nil }
        let old = Array(previous), new = Array(next)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let start = String(old.prefix(prefix)).utf16.count
        let removed = String(old[prefix..<(old.count - suffix)]).utf16.count
        return LiveTextEdit(range: NSRange(location: start, length: removed),
                            replacement: String(new[prefix..<(new.count - suffix)]))
    }
}

/// Provider-final phrases are immutable. Stability is only a presentation policy:
/// withheld words are always restored by the final event, never thrown away.
struct LiveTranscriptPresentation {
    private(set) var committed = ""
    private(set) var draft = ""

    mutating func receive(_ text: String, isFinal: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal { committed = joined(committed, text); draft = "" }
        else { draft = text }
    }

    var preview: String { joined(committed, draft) }

    func editorText(holdLastWord: Bool) -> String {
        guard holdLastWord, !draft.isEmpty else { return preview }
        // Romanized partials change spelling frequently. Wait for the following
        // word (or finalization) before exposing their trailing word to the editor.
        let words = draft.split(whereSeparator: { $0.isWhitespace })
        guard words.count > 1 else { return committed }
        let boundary = words[words.count - 1].startIndex
        return joined(committed, String(draft[..<boundary]).trimmingCharacters(in: .whitespaces))
    }

    private func joined(_ first: String, _ second: String) -> String {
        [first, second].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// An Accessibility composition session bounded to the text inserted by GujType.
final class LiveTextComposition {
    private let element: AXUIElement
    private let insertionStart: Int
    private var composedUTF16Length = 0
    private var expectedValue: String
    private var valid = true
    private var composedText = ""
    private var protectedUTF16Length = 0

    private init(element: AXUIElement, insertionStart: Int, value: String) {
        self.element = element
        self.insertionStart = insertionStart
        expectedValue = value
    }

    static func begin() -> LiveTextComposition? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != "AXSecureTextField" else { return nil }
        for attribute in [kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute] {
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(focused, attribute as CFString, &settable) == .success,
                  settable.boolValue else { return nil }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
              let selectedRangeValue, CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else { return nil }
        let selectedAXValue = selectedRangeValue as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(selectedAXValue, .cfRange, &selectedRange) else { return nil }
        // Start with an empty selection to avoid overwriting existing user text.
        guard selectedRange.length == 0 else { return nil }
        return LiveTextComposition(element: focused, insertionStart: selectedRange.location, value: text)
    }

    /// Append without selecting, or replace only the smallest changed range.
    /// Completed phrases are protected from every subsequent edit.
    func replace(with text: String, committedUTF16Length: Int = 0) -> Bool {
        guard valid else { return false }
        var focused: CFTypeRef?, value: CFTypeRef?, selection: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        var selected = CFRange()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, element),
              AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              value as? String == expectedValue,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
              AXValueGetValue(selection as! AXValue, .cfRange, &selected),
              selected.location == insertionStart + composedUTF16Length, selected.length == 0 else {
            valid = false; return false
        }
        guard committedUTF16Length >= protectedUTF16Length,
              committedUTF16Length <= text.utf16.count else { valid = false; return false }
        guard let edit = LiveTextEdit.between(composedText, text) else {
            protectedUTF16Length = committedUTF16Length
            return true
        }
        guard edit.range.location >= protectedUTF16Length else { valid = false; return false }
        var range = CFRange(location: insertionStart + edit.range.location, length: edit.range.length)
        guard range.location >= 0, range.location + range.length <= expectedValue.utf16.count else { valid = false; return false }
        let appending = edit.range.location == composedUTF16Length && edit.range.length == 0
        if !appending {
            guard let rangeValue = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else { valid = false; return false }
        }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, edit.replacement as CFTypeRef) == .success else { valid = false; return false }
        expectedValue = (expectedValue as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: edit.replacement)
        composedText = text
        composedUTF16Length = text.utf16.count
        protectedUTF16Length = committedUTF16Length
        var caret = CFRange(location: insertionStart + composedUTF16Length, length: 0)
        // Appending already places the caret at the end. Avoid a redundant AX
        // selection update; it can cause extra scrolling and visible flashing.
        if !appending {
            guard let caretValue = AXValueCreate(.cfRange, &caret),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue) == .success else { valid = false; return false }
        }
        return true
    }
}
