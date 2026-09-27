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
