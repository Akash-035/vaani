import ApplicationServices
import Foundation

/// An Accessibility composition session bounded to the text inserted by GujType.
final class LiveTextComposition {
    private let element: AXUIElement
    private let insertionStart: Int
    private var composedUTF16Length = 0
    private var expectedValue: String
    private var valid = true

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

    /// Select and replace exactly the session-owned range, leaving earlier field contents intact.
    func replace(with text: String) -> Bool {
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
        var range = CFRange(location: insertionStart, length: composedUTF16Length)
        guard range.location >= 0, range.location + range.length <= expectedValue.utf16.count else { valid = false; return false }
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else { valid = false; return false }
        expectedValue = (expectedValue as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        composedUTF16Length = text.utf16.count
        var caret = CFRange(location: insertionStart + composedUTF16Length, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }
        return true
    }
}
