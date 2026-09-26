import CryptoKit
import XCTest
@testable import tlx

final class NotificationTests: XCTestCase {
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
        store = try Store(ownPublicKey: me, uiPath: directory.appending(path: "ui.db"), syncPath: directory.appending(path: "sync.db"))
    }

    override func tearDownWithError() throws {
        store = nil
        storage = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testSaveReportsOnlyNewMessages() throws {
        let message = self.message(1, chat: "@one", from: bob, to: [me, bob], "hi")
        XCTAssertTrue(try storage.save(message))
        XCTAssertFalse(try storage.save(message))
        XCTAssertEqual(storage.lastSeenSequence(), 1)
    }

    func testAnnouncesOthersMessagesInChatsButNotTopics() throws {
        let messages = [
            message(1, chat: "@one", from: bob, to: [me, bob], "hi"),
            message(2, chat: "launch@two", from: bob, to: [me, bob], "topic talk"),
            message(3, chat: "@one", from: me, to: [me, bob], "my own reply"),
            message(4, chat: "@group", from: alice, to: [me, bob, alice], "  group note\n"),
        ]
        for message in messages { try storage.save(message) }
        _ = try store.setAlias(publicKey: bob, name: "Bob")
        let names = Names(me: me, aliases: try store.aliases())

        let requests = try announcements(for: messages, store: store)
        XCTAssertEqual(requests.map(\.identifier), ["m1", "m4"])
        XCTAssertEqual(requests[0].content.title, "Bob")
        XCTAssertEqual(requests[0].content.subtitle, "")
        XCTAssertEqual(requests[0].content.body, "hi")
        XCTAssertEqual(requests[0].content.threadIdentifier, "@one")
        XCTAssertEqual(requests[1].content.title, "Bob, \(names.of(alice))")
        XCTAssertEqual(requests[1].content.subtitle, names.of(alice))
        XCTAssertEqual(requests[1].content.body, "group note")
        XCTAssertEqual(requests[1].content.threadIdentifier, "@group")
        XCTAssertTrue(try announcements(for: [messages[1], messages[2]], store: store).isEmpty)
    }

    private func message(_ sequence: Int, chat: String, from sender: String, to recipients: [String], _ text: String) -> Message {
        Message(sequence: sequence, chatId: chat, recipientPublicKeys: recipients, senderPublicKey: sender,
                claimedAt: sequence, relayedAt: sequence, body: Data(text.utf8))
    }
}

private func key(_ seed: UInt8) -> String {
    let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
    let wire = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + key.publicKey.rawRepresentation
    return wire.base64EncodedString()
}
