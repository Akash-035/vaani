import XCTest
@testable import GujType

final class LiveTextTests: XCTestCase {
    func testAppendDoesNotSelectExistingWords() {
        XCTAssertEqual(LiveTextEdit.between("I want", "I want to go"),
                       LiveTextEdit(range: NSRange(location: 6, length: 0), replacement: " to go"))
        XCTAssertNil(LiveTextEdit.between("I want", "I want"))
    }

    func testCorrectionPreservesUnchangedSuffix() {
        let edit = LiveTextEdit.between("Meet on Monday please", "Meet on Tuesday please")!
        XCTAssertEqual(apply(edit, to: "Meet on Monday please"), "Meet on Tuesday please")
        XCTAssertEqual(edit.range.location, 8)
        XCTAssertFalse(edit.replacement.contains("please"))
        XCTAssertLessThan(edit.range.length, "Monday please".utf16.count)
    }

    func testUnicodeEditsAreWholeGraphemesAndUseUTF16Coordinates() {
        for (old, new) in [
            ("હું ક", "હું કિ"), ("मैं क", "मैं कि"),
            ("👩🏽‍💻 hello", "👩🏽‍💻 help"), ("cafe", "café"),
            ("नमस्ते दुनिया", "नमस्ते"), ("", "ગુજરાતી")
        ] {
            let edit = LiveTextEdit.between(old, new)!
            XCTAssertEqual(apply(edit, to: old), new)
            var boundaries: Set<Int> = [0]
            var offset = 0
            for character in old { offset += String(character).utf16.count; boundaries.insert(offset) }
            XCTAssertTrue(boundaries.contains(edit.range.location))
            XCTAssertTrue(boundaries.contains(edit.range.location + edit.range.length))
        }
    }

    func testFinalPhrasesRemainOutsideLaterCorrectionRanges() {
        var presentation = LiveTranscriptPresentation()
        presentation.receive("First phrase.", isFinal: true)
        let committed = presentation.committed
        presentation.receive("Next phrass", isFinal: false)
        let previous = presentation.editorText(holdLastWord: false)
        presentation.receive("Next phrase", isFinal: false)
        let next = presentation.editorText(holdLastWord: false)
        let edit = LiveTextEdit.between(previous, next)!
        XCTAssertGreaterThanOrEqual(edit.range.location, committed.utf16.count)
        XCTAssertEqual(presentation.committed, committed)
        presentation.receive("Next phrase.", isFinal: true)
        XCTAssertEqual(presentation.preview, "First phrase. Next phrase.")
        XCTAssertEqual(presentation.draft, "")
    }

    func testRomanizedTailWaitsButFinalIsNeverTruncated() {
        var presentation = LiveTranscriptPresentation()
        presentation.receive("mera", isFinal: false)
        XCTAssertEqual(presentation.editorText(holdLastWord: true), "")
        presentation.receive("mera kibord", isFinal: false)
        XCTAssertEqual(presentation.editorText(holdLastWord: true), "mera")
        presentation.receive("mera keyboard hai", isFinal: true)
        XCTAssertEqual(presentation.editorText(holdLastWord: true), "mera keyboard hai")
        presentation.receive("aur", isFinal: false)
        XCTAssertEqual(presentation.editorText(holdLastWord: true), "mera keyboard hai")
        presentation.receive("aur", isFinal: true)
        XCTAssertEqual(presentation.editorText(holdLastWord: true), "mera keyboard hai aur")
    }

    func testDraftRetractionAndEmptyFinalDoNotEraseCommittedPhrase() {
        var presentation = LiveTranscriptPresentation()
        presentation.receive("Done.", isFinal: true)
        presentation.receive("noise", isFinal: false)
        presentation.receive("", isFinal: true)
        XCTAssertEqual(presentation.preview, "Done.")
    }

    private func apply(_ edit: LiveTextEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
}
