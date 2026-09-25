import Foundation

private let schema = """
pragma journal_mode = wal;

create table if not exists seen_participants (
    id integer primary key,
    chat_id text not null,
    public_key text not null,
    rejected_by_relay_at integer,
    unique (chat_id, public_key)
);

create table if not exists messages (
    sequence integer primary key,
    chat_id text not null,
    sender_id integer not null references seen_participants (id),
    claimed_at integer not null,
    relayed_at integer not null,
    body blob not null,
    unique (sender_id, claimed_at)
);

create table if not exists message_recipients (
    sequence integer not null references messages (sequence),
    seen_participant_id integer not null references seen_participants (id),
    primary key (sequence, seen_participant_id)
);

create table if not exists outbox (
    claimed_at integer primary key,
    chat_id text not null,
    recipient_public_keys text,
    body blob not null,
    sent_at integer,
    error text
);
"""

struct Message {
    let sequence: Int
    let chatId: String
    let recipientPublicKeys: [String]
    let senderPublicKey: String
    let claimedAt: Int
    let relayedAt: Int
    let body: Data
}

final class Storage {
    private let db: SQLite
    private let ownPublicKey: String

    init(path: URL, ownPublicKey: String) throws {
        db = try SQLite(path: path)
        self.ownPublicKey = ownPublicKey
        try db.execute(schema)
    }

    func lastSeenSequence() -> Int {
        (try? db.query("select coalesce(max(sequence), 0) from messages"))?.first?.int(0) ?? 0
    }

    func save(_ message: Message) throws {
        try db.execute("begin")
        do {
            let recipientIds = try message.recipientPublicKeys.map { try participantId(chatId: message.chatId, publicKey: $0) }
            let senderId = try participantId(chatId: message.chatId, publicKey: message.senderPublicKey)
            let inserted = try db.run("insert or ignore into messages values (?, ?, ?, ?, ?, ?)",
                                      [message.sequence, message.chatId, senderId, message.claimedAt, message.relayedAt, message.body])
            if inserted > 0 {
                for recipientId in recipientIds {
                    _ = try db.run("insert or ignore into message_recipients values (?, ?)", [message.sequence, recipientId])
                }
                for publicKey in message.recipientPublicKeys {
                    _ = try db.run("update seen_participants set rejected_by_relay_at = null where public_key = ?", [publicKey])
                }
                if message.senderPublicKey == ownPublicKey {
                    _ = try db.run("delete from outbox where claimed_at = ?", [message.claimedAt])
                }
            }
            try db.execute("commit")
        } catch {
            try? db.execute("rollback")
            throw error
        }
    }

    private func participantId(chatId: String, publicKey: String) throws -> Int {
        _ = try db.run("insert or ignore into seen_participants (chat_id, public_key) values (?, ?)", [chatId, publicKey])
        return try db.query("select id from seen_participants where chat_id = ? and public_key = ?", [chatId, publicKey])[0].int(0)
    }
}
