#if targetEnvironment(macCatalyst)
import UIKit
import XCTest
@testable import tlx

@MainActor
final class MacComposerTests: XCTestCase {
    func testReturnAcceptsMarkedTextBeforeSending() throws {
        let field = MacComposerField.TextView()
        var sends = 0
        field.onSend = { sends += 1 }
        field.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(field.markedTextRange)
        let command = try XCTUnwrap(field.keyCommands?.first { $0.input == "\r" && $0.modifierFlags.isEmpty })

        field.perform(command.action, with: command)
        XCTAssertEqual(field.text, "候補")
        XCTAssertNil(field.markedTextRange)
        XCTAssertEqual(sends, 0)

        field.perform(command.action, with: command)
        XCTAssertEqual(sends, 1)
    }

    func testShiftReturnPreservesMarkedTextBeforeAddingNewline() throws {
        let field = MacComposerField.TextView()
        var sends = 0
        field.onSend = { sends += 1 }
        field.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0))
        let command = try XCTUnwrap(field.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == .shift })

        field.perform(command.action, with: command)
        XCTAssertEqual(field.text, "候補\n")
        XCTAssertNil(field.markedTextRange)
        XCTAssertEqual(sends, 0)
    }
}
#endif
