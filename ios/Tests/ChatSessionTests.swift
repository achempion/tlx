import SwiftUI
import XCTest
@testable import tlx

@MainActor
final class ChatSessionTests: XCTestCase {
    func testPreparedSessionContainsLatestPageAndSavedComposerWithoutMarkingRead() throws {
        let fixture = try SessionFixture()
        try fixture.save(1...125)
        fixture.store.markRead(chatId: "@one", sequence: 100)
        try fixture.store.send(chatId: "@one", body: Data("Queued message".utf8))
        try fixture.store.saveDraft(chatId: "@one", text: "Next draft\nSecond line")
        let sidebar = try fixture.openStore()
        let uiVersion = sidebar.uiDataVersion()

        let session = try ChatSession(store: fixture.store, chatId: "@one")

        XCTAssertEqual(session.messages.map(\.sequence), Array(26...125))
        XCTAssertTrue(session.hasOlder)
        XCTAssertEqual(session.pendings.map(\.body), [Data("Queued message".utf8)])
        XCTAssertEqual(session.editor.text, "Next draft\nSecond line")
        XCTAssertEqual(session.readMarker, 100)
        XCTAssertEqual(session.openingReadMarker, 100)
        XCTAssertEqual(sidebar.lastRead(chatId: "@one"), 100)
        XCTAssertEqual(try sidebar.chats().first?.unread, 25)
        XCTAssertEqual(sidebar.uiDataVersion(), uiVersion, "Preparing a chat must not mark unseen messages read")
    }

    func testFirstRefreshIncludesMessagesCommittedAfterPreparationWithoutDuplicates() throws {
        let fixture = try SessionFixture()
        try fixture.save(1...1)
        let session = try ChatSession(store: fixture.store, chatId: "@one")

        try fixture.save(2...2)

        XCTAssertTrue(session.refresh())
        XCTAssertEqual(session.messages.map(\.sequence), [1, 2])
        XCTAssertFalse(session.refresh())
        XCTAssertEqual(session.messages.map(\.sequence), [1, 2])
    }

    func testSessionWritesInvalidateSidebarAndConfirmationPreservesNextDraft() throws {
        let fixture = try SessionFixture()
        try fixture.save(1...1)
        let sidebar = try fixture.openStore()
        let session = try ChatSession(store: fixture.store, chatId: "@one")
        let beforeEdit = sidebar.uiDataVersion()

        session.editor.edit("First message")

        XCTAssertNotEqual(sidebar.uiDataVersion(), beforeEdit)
        XCTAssertEqual(try sidebar.chats().first?.draft, "First message")
        let beforeSend = sidebar.dataVersion()
        XCTAssertTrue(session.send())
        XCTAssertNotEqual(sidebar.dataVersion(), beforeSend)
        XCTAssertEqual(session.pendings.count, 1)
        XCTAssertEqual(try sidebar.chats().first?.pending?.body, Data("First message".utf8))

        session.editor.edit("Keep the next draft")
        let queued = try XCTUnwrap(fixture.storage.unsentOutbox().first)
        try fixture.storage.save(Message(sequence: 2, chatId: "@one", recipientPublicKeys: [fixture.me, fixture.bob],
                                         senderPublicKey: fixture.me, claimedAt: queued.claimedAt, relayedAt: 2, body: queued.body))

        XCTAssertTrue(session.refresh())
        XCTAssertEqual(session.messages.map(\.sequence), [1, 2])
        XCTAssertTrue(session.pendings.isEmpty)
        XCTAssertEqual(session.editor.text, "Keep the next draft")
        XCTAssertEqual(try sidebar.chats().first?.draft, "Keep the next draft")

        let beforeRead = sidebar.uiDataVersion()
        session.markRead(upTo: 2)
        XCTAssertNotEqual(sidebar.uiDataVersion(), beforeRead)
        XCTAssertEqual(session.readMarker, 2)
        XCTAssertEqual(try sidebar.chats().first?.unread, 0)
        XCTAssertEqual(session.openingReadMarker, 0, "The opening divider must remain stable after marking read")
    }

    func testOlderPagesKeepOrderAndAnEmptyFinalPageStopsPagination() throws {
        let fixture = try SessionFixture()
        try fixture.save(1...200)
        let session = try ChatSession(store: fixture.store, chatId: "@one")
        XCTAssertEqual(session.messages.map(\.sequence), Array(101...200))

        XCTAssertTrue(session.loadOlder())
        XCTAssertEqual(session.messages.map(\.sequence), Array(1...200))
        XCTAssertTrue(session.hasOlder)
        XCTAssertFalse(session.loadOlder())
        XCTAssertFalse(session.hasOlder)
        XCTAssertEqual(session.messages.map(\.sequence), Array(1...200))
    }

    func testSessionsSharingTheirWriterKeepSeparateDraftsAndReadBoundaries() throws {
        let fixture = try SessionFixture()
        try fixture.save(1...1)
        try fixture.save(2...2, chatId: "@two")
        fixture.store.markRead(chatId: "@two", sequence: 2)
        let first = try ChatSession(store: fixture.store, chatId: "@one")
        first.editor.edit("Draft one")
        let second = try ChatSession(store: fixture.store, chatId: "@two")
        second.editor.edit("Draft two")
        let reopened = try ChatSession(store: fixture.store, chatId: "@one")

        XCTAssertEqual(first.editor.text, "Draft one")
        XCTAssertEqual(reopened.editor.text, "Draft one")
        XCTAssertEqual(second.editor.text, "Draft two")
        XCTAssertEqual(first.openingReadMarker, 0)
        XCTAssertNil(second.openingReadMarker)
        XCTAssertEqual(second.readMarker, 2)
    }
}

final class MessageTextTests: XCTestCase {
    @MainActor
    func testMessageViewAllowsRangeSelectionAndOnlyExplicitLinks() throws {
        let message = "Copy https://example.com"
        let host = UIHostingController(rootView: SelectableMessageText(text: message, mine: false)
            .environment(\.dynamicTypeSize, .medium).environment(\.legibilityWeight, .regular))
        host.loadViewIfNeeded()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        func findTextView(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView { return textView }
            return view.subviews.compactMap { findTextView(in: $0) }.first
        }
        let textView = try XCTUnwrap(findTextView(in: host.view))
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertEqual(textView.dataDetectorTypes, [])
        XCTAssertNotNil(textView.delegate)
        textView.selectedRange = NSRange(location: 0, length: 4)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 4))
        XCTAssertEqual(textView.selectedTextRange.flatMap(textView.text(in:)), "Copy")
        XCTAssertEqual(textView.attributedText.attribute(.link, at: 5, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
        let size = host.sizeThatFits(in: CGSize(width: 400, height: 1_000))
        XCTAssertGreaterThan(size.width, 20)
        XCTAssertLessThan(size.width, 400)
        XCTAssertGreaterThan(size.height, 10)

        #if !targetEnvironment(macCatalyst)
        let regularFont = try XCTUnwrap(textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #endif
        host.rootView = SelectableMessageText(text: message, mine: false)
            .environment(\.dynamicTypeSize, .medium).environment(\.legibilityWeight, .regular)
        host.view.layoutIfNeeded()
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 4), "Redraw must keep the selection")

        host.rootView = SelectableMessageText(text: message, mine: false)
            .environment(\.dynamicTypeSize, .accessibility3).environment(\.legibilityWeight, .bold)
        RunLoop.main.run(until: .now.addingTimeInterval(0.05))
        host.view.layoutIfNeeded()
        XCTAssertEqual((textView.delegate as? SelectableMessageText.Coordinator)?.dynamicTypeSize, .accessibility3)
        let largerFont = try XCTUnwrap(textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #if !targetEnvironment(macCatalyst)
        XCTAssertGreaterThan(largerFont.pointSize, regularFont.pointSize)
        #endif
        XCTAssertTrue(largerFont.fontDescriptor.symbolicTraits.contains(.traitBold))

        host.rootView = SelectableMessageText(text: message, mine: true)
            .environment(\.dynamicTypeSize, .medium).environment(\.legibilityWeight, .regular)
        RunLoop.main.run(until: .now.addingTimeInterval(0.05))
        host.view.layoutIfNeeded()
        XCTAssertEqual(textView.tintColor, .black, "Sent bubbles need a selection tint that contrasts with blue")

        XCTAssertTrue(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: 0, length: 4)
        window.endEditing(true)
        XCTAssertEqual(textView.selectedRange.length, 0, "Leaving a message clears its selection")
    }
}

final class MessageLinkTests: XCTestCase {
    private func links(in text: NSAttributedString) -> [String] {
        var links: [String] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            let label = (text.string as NSString).substring(with: range)
            links.append("\(label) -> \(url.absoluteString)")
        }
        return links
    }

    func testExplicitWebLinksPreserveMessageText() {
        let message = "Hi 🎉 https://example.com/path?x=1 and http://example.org."
        let rendered = linkedMessageText(message)

        XCTAssertEqual(rendered.string, message)
        XCTAssertEqual(links(in: rendered), [
            "https://example.com/path?x=1 -> https://example.com/path?x=1",
            "http://example.org -> http://example.org",
        ])
    }

    func testOtherSchemesAndImplicitAddressesStayPlain() {
        let message = "javascript:alert(1) file:///tmp/private mailto:a@example.com www.example.com https://safe.example"
        let rendered = linkedMessageText(message)

        XCTAssertEqual(rendered.string, message)
        XCTAssertEqual(links(in: rendered), ["https://safe.example -> https://safe.example"])
    }

    func testLinkBoundariesAndInvalidHosts() {
        let cases: [(String, [String])] = [
            ("HTTPS://EXAMPLE.COM", ["HTTPS://EXAMPLE.COM -> HTTPS://EXAMPLE.COM"]),
            ("https:// and http:///path", []),
            ("(https://example.com),", ["https://example.com -> https://example.com"]),
            ("https://one.example)(https://two.example", [
                "https://one.example -> https://one.example",
                "https://two.example -> https://two.example",
            ]),
        ]
        for (message, expected) in cases {
            let rendered = linkedMessageText(message)
            XCTAssertEqual(rendered.string, message)
            XCTAssertEqual(links(in: rendered), expected, message)
        }
    }

    func testOversizedMessageSkipsLinkDetection() {
        let message = String(repeating: "x", count: 32_769) + " https://example.com"
        let rendered = linkedMessageText(message)

        XCTAssertEqual(rendered.string, message)
        XCTAssertTrue(links(in: rendered).isEmpty)
    }
}

private final class SessionFixture {
    let directory: URL
    let me = testPublicKey(1)
    let bob = testPublicKey(2)
    var store: Store!
    var storage: Storage!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        storage = try Storage(path: directory.appending(path: "sync.db"), ownPublicKey: me)
        store = try openStore()
    }

    deinit {
        store = nil
        storage = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func openStore() throws -> Store {
        try Store(ownPublicKey: me, uiPath: directory.appending(path: "ui.db"), syncPath: directory.appending(path: "sync.db"))
    }

    func save(_ sequences: ClosedRange<Int>, chatId: String = "@one") throws {
        for sequence in sequences {
            try storage.save(Message(sequence: sequence, chatId: chatId, recipientPublicKeys: [me, bob], senderPublicKey: bob,
                                     claimedAt: sequence, relayedAt: sequence, body: Data("Message \(sequence)\nA second line".utf8)))
        }
    }
}
