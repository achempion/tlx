import Observation
import XCTest
@testable import tlx

final class NamesTests: XCTestCase {
    private var directory: URL!
    private var store: Store!
    private var names: Names!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try Storage(path: directory.appending(path: "sync.db"), ownPublicKey: "me")
        store = try openStore()
        names = Names(me: "me")
    }

    override func tearDownWithError() throws {
        names = nil
        store = nil
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testRenamePersistsAndAllowsSpaces() throws {
        try names.setAlias(publicKey: "bob", name: "  Bob Smith \n", using: store)
        XCTAssertEqual(names.of("bob"), "Bob Smith")
        XCTAssertEqual(try openStore().aliases()["bob"], "Bob Smith")

        try names.setAlias(publicKey: "bob", name: "Robert", using: store)
        XCTAssertEqual(names.of("bob"), "Robert")
        XCTAssertEqual(try openStore().aliases()["bob"], "Robert")
    }

    func testDuplicateNameKeepsBothContactsUnchanged() throws {
        try names.setAlias(publicKey: "bob", name: "Bob", using: store)
        try names.setAlias(publicKey: "alice", name: "Alice", using: store)
        XCTAssertThrowsError(try names.setAlias(publicKey: "alice", name: " Bob ", using: store)) { error in
            guard case AliasError.nameTaken = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(names.aliases, ["bob": "Bob", "alice": "Alice"])
        XCTAssertEqual(try openStore().aliases(), names.aliases)
    }

    func testInvalidNamesKeepTheSavedName() throws {
        try names.setAlias(publicKey: "bob", name: "Bob", using: store)
        for name in [" \n\t ", "Bob\nSmith", "Bob\rSmith"] {
            XCTAssertThrowsError(try names.setAlias(publicKey: "bob", name: name, using: store))
        }
        XCTAssertEqual(names.of("bob"), "Bob")
        XCTAssertEqual(try store.aliases()["bob"], "Bob")
    }

    func testRemovalRestoresTheIdentifierAndFreesTheName() throws {
        let fallback = names.of("bob")
        try names.setAlias(publicKey: "bob", name: "Bob", using: store)
        try names.removeAlias(publicKey: "bob", using: store)
        XCTAssertEqual(names.of("bob"), fallback)
        XCTAssertNil(try openStore().aliases()["bob"])
        try names.setAlias(publicKey: "alice", name: "Bob", using: store)
        XCTAssertEqual(names.of("alice"), "Bob")
    }

    func testRenameNotifiesViewsAndUpdatesEveryChatTitle() throws {
        let chats = [chat("@first", participants: ["bob"]), chat("@second", participants: ["bob"]),
                     chat("@group", participants: ["bob", "alice"]), chat("topic@third", participants: ["bob", "alice"])]
        let changed = expectation(description: "Visible names change after saving")
        withObservationTracking {
            _ = chats.map { names.chat($0, among: chats) }
        } onChange: {
            changed.fulfill()
        }
        try names.setAlias(publicKey: "bob", name: "Bob", using: store)
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(names.chat(chats[0], among: chats), "Bob·firs")
        XCTAssertEqual(names.chat(chats[1], among: chats), "Bob·seco")
        XCTAssertEqual(names.chat(chats[2], among: chats), "Bob, \(names.of("alice"))")
        XCTAssertEqual(names.chat(chats[3], among: chats), "#topic")
        XCTAssertEqual(names.people(chats[3]), "Bob, \(names.of("alice"))")
    }

    func testFailedWritesDoNotChangeVisibleNames() throws {
        try names.setAlias(publicKey: "bob", name: "Bob", using: store)
        let db = try SQLite(path: directory.appending(path: "ui.db"))
        try db.execute("create trigger fail_save before insert on alias begin select raise(abort, 'write failed'); end;")
        try db.execute("create trigger fail_remove before delete on alias begin select raise(abort, 'write failed'); end;")
        XCTAssertThrowsError(try names.setAlias(publicKey: "bob", name: "Robert", using: store))
        XCTAssertThrowsError(try names.removeAlias(publicKey: "bob", using: store))
        XCTAssertEqual(names.of("bob"), "Bob")
        XCTAssertEqual(try store.aliases()["bob"], "Bob")
    }

    private func openStore() throws -> Store {
        try Store(ownPublicKey: "me", uiPath: directory.appending(path: "ui.db"), syncPath: directory.appending(path: "sync.db"))
    }

    private func chat(_ id: String, participants: [String]) -> Chat {
        Chat(id: id, lastSequence: 1, unread: 0, participants: participants, lastSender: "bob", lastClaimedAt: 0, lastBody: Data())
    }
}
