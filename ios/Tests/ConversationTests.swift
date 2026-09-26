import CryptoKit
import XCTest
@testable import tlx

final class ConversationTests: XCTestCase {
    private var directory: URL!
    private var store: Store!
    private var storage: Storage!
    private let me = key(1)
    private let bob = key(2)
    private let alice = key(3)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = try Storage(path: directory.appending(path: "sync.db"), ownPublicKey: me)
        store = try openStore()
    }

    override func tearDownWithError() throws {
        store = nil
        storage = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testBareAndPrefixedPublicKeysAreTheSameContact() throws {
        XCTAssertEqual(try SSH.publicKey(bob), bob)
        XCTAssertEqual(try SSH.publicKey("  ssh-ed25519 \(bob) example@phone\n"), bob)
        XCTAssertEqual(try SSH.publicKey("ssh-ed25519\t\(bob)"), bob)
        let chat = try store.createChat(recipients: [bob, "ssh-ed25519 \(bob) phone"])
        XCTAssertEqual(chat.participants, [bob])
        XCTAssertEqual(try store.knownContacts(), [bob])
    }

    func testMalformedUnsupportedAndOwnKeysAreRejected() throws {
        for invalid in ["", "not-a-key", "ssh-rsa \(bob)", "ssh-ed25519 bad", "ssh-ed25519 \(bob)\nssh-ed25519 \(alice)"] {
            XCTAssertThrowsError(try SSH.publicKey(invalid))
        }
        XCTAssertThrowsError(try store.createChat(recipients: [me]))
        XCTAssertThrowsError(try store.createChat(recipients: [bob, me]))
        XCTAssertThrowsError(try store.createChat(recipients: []))
        XCTAssertThrowsError(try store.createChat(recipients: ["not-a-key"]))
        XCTAssertTrue(try store.chats().isEmpty)
    }

    func testChatsAndTopicsAreIndependentLocalDrafts() throws {
        let plain = try store.createChat(recipients: [bob])
        let first = try store.createChat(topic: " #launch ", recipients: [bob, alice])
        let second = try store.createChat(topic: "launch", recipients: [alice, bob])
        XCTAssertEqual(Set([plain.id, first.id, second.id]).count, 3)
        XCTAssertTrue(plain.id.hasPrefix("@"))
        XCTAssertTrue(first.id.hasPrefix("launch@"))
        XCTAssertTrue(first.isGroup)
        XCTAssertFalse(plain.isGroup)
        let restored = try openStore().chats()
        XCTAssertEqual(restored.count, 3)
        XCTAssertTrue(restored.allSatisfy(\.isDraft))
        XCTAssertEqual(Set(restored.first { $0.id == first.id }!.participants), Set([bob, alice]))
        XCTAssertTrue(try storage.unsentOutbox().isEmpty, "Creation must not send a message")
    }

    func testTopicValidationDoesNotCreatePartialDrafts() throws {
        for invalid in ["", "#", "two words", "one@two", "#one#two", "one\ntwo", "one\0two"] {
            XCTAssertThrowsError(try store.createChat(topic: invalid, recipients: [bob]))
        }
        XCTAssertTrue(try store.chats().isEmpty)
        XCTAssertEqual(try topicName("weekend-plans"), "weekend-plans")
    }

    func testDraftTextSurvivesReopeningAndPublishesLocalChanges() throws {
        let reader = try openStore()
        let syncVersion = reader.dataVersion()
        let uiVersion = reader.uiDataVersion()
        let chat = try store.createChat(recipients: [bob])
        let editor = try Composer(store: store, chatId: chat.id)
        editor.edit("First line\nSecond line\n")
        let reopened = try Composer(store: openStore(), chatId: chat.id)
        XCTAssertEqual(reopened.text, editor.text)
        XCTAssertEqual(try reader.chats()[0].draft, editor.text)
        XCTAssertEqual(reader.dataVersion(), syncVersion)
        XCTAssertNotEqual(reader.uiDataVersion(), uiVersion, "Offline drafts must invalidate the chat list")
        editor.edit("")
        XCTAssertEqual(try openStore().chats().count, 1, "An empty new conversation must retain its recipients")
    }

    func testEverySendBeforeConfirmationRetainsRecipientsAcrossRestart() throws {
        let chat = try store.createChat(recipients: [bob, alice])
        let first = try Composer(store: store, chatId: chat.id)
        first.edit("One")
        XCTAssertTrue(first.send())
        XCTAssertTrue(first.text.isEmpty)
        XCTAssertTrue(try store.draftText(chatId: chat.id).isEmpty)

        let second = try Composer(store: openStore(), chatId: chat.id)
        second.edit("Two")
        XCTAssertTrue(second.send())
        let outbox = try storage.unsentOutbox()
        XCTAssertEqual(outbox.count, 2)
        XCTAssertEqual(Set(outbox.map(\.claimedAt)).count, 2)
        XCTAssertTrue(outbox.allSatisfy { Set($0.recipientPublicKeys) == Set([bob, alice]) })
        let listed = try openStore().chats()
        XCTAssertEqual(listed.count, 1)
        XCTAssertFalse(listed[0].isDraft)
        XCTAssertEqual(listed[0].pending?.body, Data("Two".utf8))
        XCTAssertEqual(Set(listed[0].participants), Set([bob, alice]))
    }

    func testConfirmationMergesTheChatAndPreservesTheNextDraft() throws {
        let chat = try store.createChat(recipients: [bob, alice])
        let editor = try Composer(store: store, chatId: chat.id)
        editor.edit("First")
        XCTAssertTrue(editor.send())
        let outgoing = try storage.unsentOutbox()[0]
        editor.edit("Still writing the next message")
        // The relay accepted only Bob, so later replies must use the confirmed participants.
        try storage.save(Message(sequence: 1, chatId: chat.id, recipientPublicKeys: [me, bob], senderPublicKey: me,
                                 claimedAt: outgoing.claimedAt, relayedAt: Int(Date().timeIntervalSince1970), body: outgoing.body))
        let restored = try openStore()
        let listed = try restored.chats()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, chat.id)
        XCTAssertEqual(listed[0].participants, [bob])
        XCTAssertEqual(listed[0].draft, editor.text)
        XCTAssertNil(listed[0].pending)
        let next = try Composer(store: restored, chatId: chat.id)
        XCTAssertTrue(next.send())
        XCTAssertTrue(try storage.unsentOutbox()[0].recipientPublicKeys.isEmpty, "Confirmed chats use sync's recipient list")
        XCTAssertEqual(Set(try storage.recipientPublicKeys(chatId: chat.id)), Set([me, bob]))
        XCTAssertTrue(try restored.draftText(chatId: chat.id).isEmpty)
    }

    func testSendFailureRetainsBothVisibleAndSavedDraft() throws {
        let chat = try store.createChat(recipients: [bob])
        let editor = try Composer(store: store, chatId: chat.id)
        editor.edit("Do not lose this")
        let db = try SQLite(path: directory.appending(path: "sync.db"))
        try db.execute("create trigger fail_send before insert on outbox begin select raise(abort, 'write failed'); end;")
        XCTAssertFalse(editor.send())
        XCTAssertEqual(editor.text, "Do not lose this")
        XCTAssertEqual(try openStore().draftText(chatId: chat.id), editor.text)
        XCTAssertFalse(editor.failure.isEmpty)
        XCTAssertTrue(try storage.unsentOutbox().isEmpty)
    }

    func testDraftClearFailureRollsBackTheQueuedMessage() throws {
        let chat = try store.createChat(recipients: [bob])
        let editor = try Composer(store: store, chatId: chat.id)
        editor.edit("Keep until queued")
        let db = try SQLite(path: directory.appending(path: "ui.db"))
        try db.execute("create trigger fail_clear before update on draft when new.body = '' begin select raise(abort, 'write failed'); end;")
        XCTAssertFalse(editor.send())
        XCTAssertEqual(editor.text, "Keep until queued")
        XCTAssertEqual(try openStore().draftText(chatId: chat.id), editor.text)
        XCTAssertTrue(try storage.unsentOutbox().isEmpty)
    }

    func testFailedPendingConversationSurvivesRestart() throws {
        let chat = try store.createChat(topic: "launch", recipients: [bob])
        try store.send(chatId: chat.id, body: Data("Hello".utf8))
        let row = try storage.unsentOutbox()[0]
        try storage.markFailed(claimedAt: row.claimedAt, error: "not a relay member")
        let listed = try openStore().chats()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].participants, [bob])
        XCTAssertEqual(listed[0].pending?.error, "not a relay member")
        XCTAssertThrowsError(try store.discardDraft(chatId: chat.id))
    }

    func testContactPickerIncludesAliasesAndUnconfirmedRecipients() throws {
        _ = try store.setAlias(publicKey: alice, name: "Alice")
        _ = try store.createChat(recipients: [bob])
        XCTAssertEqual(Set(try store.knownContacts()), Set([alice, bob]))
    }

    func testDiscardRemovesOnlyUnsentDrafts() throws {
        let chat = try store.createChat(recipients: [bob])
        try store.saveDraft(chatId: chat.id, text: "Unsent")
        try store.discardDraft(chatId: chat.id)
        XCTAssertTrue(try openStore().chats().isEmpty)
        XCTAssertTrue(try store.draftText(chatId: chat.id).isEmpty)
    }

    func testChatListOpensBeforeTheFirstSyncInAFreshContainer() throws {
        let fresh = directory.appending(path: "Application Support")
        let first = try Store(ownPublicKey: me, uiPath: fresh.appending(path: "ui.db"), syncPath: fresh.appending(path: "sync.db"))
        XCTAssertTrue(try first.chats().isEmpty, "The chat list must read an empty sync.db it created itself")
        let syncing = try Storage(path: fresh.appending(path: "sync.db"), ownPublicKey: me)
        XCTAssertEqual(syncing.lastSeenSequence(), 0)
        XCTAssertTrue(try syncing.unsentOutbox().isEmpty)
    }

    private func openStore() throws -> Store {
        try Store(ownPublicKey: me, uiPath: directory.appending(path: "ui.db"), syncPath: directory.appending(path: "sync.db"))
    }
}

private func key(_ seed: UInt8) -> String {
    let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
    let wire = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + key.publicKey.rawRepresentation
    return wire.base64EncodedString()
}
