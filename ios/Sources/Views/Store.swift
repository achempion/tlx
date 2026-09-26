import CryptoKit
import Foundation
import Observation

let uiDatabase = URL.applicationSupportDirectory.appending(path: "ui.db")

private let schema = """
create table if not exists read (chat_id text primary key, sequence integer not null);
create table if not exists alias (public_key text primary key, name text not null unique);
create table if not exists setting (key text primary key, value text not null);
"""

struct Chat: Identifiable {
    let id: String
    let lastSequence: Int
    let unread: Int
    let participants: [String]
    let lastSender: String
    let lastClaimedAt: Int
    let lastBody: Data
    var isTopic: Bool { !chatTag(id).isEmpty }
    var isGroup: Bool { isTopic || participants.count > 1 }
}

struct ChatMessage: Identifiable {
    let sequence: Int
    let sender: String
    let claimedAt: Int
    let body: Data
    var id: Int { sequence }
}

struct Pending: Identifiable {
    let claimedAt: Int
    let body: Data
    let sent: Bool
    let error: String?
    var id: Int { claimedAt }
}

let page = 100

final class Store {
    private let db: SQLite
    let me: String
    private var lastClaimedAt = 0

    init(ownPublicKey: String, uiPath: URL = uiDatabase, syncPath: URL = syncDatabase) throws {
        me = ownPublicKey
        db = try SQLite(path: uiPath)
        _ = try db.run("attach database ? as d", [syncPath.path])
        try db.execute(schema)
    }

    func dataVersion() -> Int {
        (try? db.query("pragma d.data_version"))?.first?.int(0) ?? 0
    }

    func chats() throws -> [Chat] {
        var participants: [String: [String]] = [:]
        for row in try db.query("select chat_id, public_key from d.seen_participants "
                                + "where public_key != ? and rejected_by_relay_at is null order by id", [me]) {
            participants[row.text(0), default: []].append(row.text(1))
        }
        let rows = try db.query("""
            select m.chat_id, m.sequence, p.public_key, m.claimed_at, m.body,
                   (select count(*) from d.messages u join d.seen_participants q on q.id = u.sender_id
                    where u.chat_id = m.chat_id and u.sequence > coalesce(r.sequence, 0) and q.public_key != ?)
            from d.messages m
            join d.seen_participants p on p.id = m.sender_id
            left join read r on r.chat_id = m.chat_id
            where m.sequence = (select max(sequence) from d.messages where chat_id = m.chat_id)
            order by m.sequence desc
            """, [me])
        return rows.map { row in
            Chat(id: row.text(0), lastSequence: row.int(1), unread: row.int(5), participants: participants[row.text(0)] ?? [],
                 lastSender: row.text(2), lastClaimedAt: row.int(3), lastBody: row.blob(4))
        }
    }

    func messages(chatId: String, before: Int? = nil) throws -> [ChatMessage] {
        let rows = try db.query("select m.sequence, p.public_key, m.claimed_at, m.body "
                                + "from d.messages m join d.seen_participants p on p.id = m.sender_id "
                                + "where m.chat_id = ? and (? is null or m.sequence < ?) order by m.sequence desc limit ?",
                                [chatId, before, before, page])
        return rows.reversed().map { ChatMessage(sequence: $0.int(0), sender: $0.text(1), claimedAt: $0.int(2), body: $0.blob(3)) }
    }

    func pending(chatId: String) throws -> [Pending] {
        try db.query("select claimed_at, body, sent_at is not null, error from d.outbox where chat_id = ? order by claimed_at", [chatId])
            .map { Pending(claimedAt: $0.int(0), body: $0.blob(1), sent: $0.int(2) == 1, error: $0.text(3).isEmpty ? nil : $0.text(3)) }
    }

    func send(chatId: String, body: Data, recipients: [String]? = nil) throws {
        lastClaimedAt = max(Int(Date().timeIntervalSince1970 * 1_000_000_000), lastClaimedAt + 1)
        _ = try db.run("insert into d.outbox (claimed_at, chat_id, recipient_public_keys, body) values (?, ?, ?, ?)",
                       [lastClaimedAt, chatId, recipients?.joined(separator: " "), body])
    }

    func lastRead(chatId: String) -> Int {
        (try? db.query("select sequence from read where chat_id = ?", [chatId]))?.first?.int(0) ?? 0
    }

    func markRead(chatId: String, sequence: Int) {
        _ = try? db.run("insert into read (chat_id, sequence) values (?, ?) "
                        + "on conflict (chat_id) do update set sequence = max(sequence, excluded.sequence)", [chatId, sequence])
    }

    func aliases() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try db.query("select public_key, name from alias").map { ($0.text(0), $0.text(1)) })
    }

    func setAlias(publicKey: String, name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AliasError.emptyName }
        guard name.rangeOfCharacter(from: .newlines) == nil else { throw AliasError.multilineName }
        guard try db.query("select 1 from alias where name = ? and public_key != ?", [name, publicKey]).isEmpty else {
            throw AliasError.nameTaken
        }
        _ = try db.run("insert into alias (public_key, name) values (?, ?) "
                        + "on conflict (public_key) do update set name = excluded.name", [publicKey, name])
        return name
    }

    func removeAlias(publicKey: String) throws {
        _ = try db.run("delete from alias where public_key = ?", [publicKey])
    }
}

enum AliasError: LocalizedError {
    case emptyName, multilineName, nameTaken

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name."
        case .multilineName: "Keep the name on one line."
        case .nameTaken: "That name already belongs to another contact."
        }
    }
}

@Observable
final class Names {
    let me: String
    var aliases: [String: String]

    init(me: String, aliases: [String: String] = [:]) {
        self.me = me
        self.aliases = aliases
    }

    func setAlias(publicKey: String, name: String, using store: Store) throws {
        let saved = try store.setAlias(publicKey: publicKey, name: name)
        aliases[publicKey] = saved
    }

    func removeAlias(publicKey: String, using store: Store) throws {
        try store.removeAlias(publicKey: publicKey)
        aliases.removeValue(forKey: publicKey)
    }

    func of(_ publicKey: String) -> String {
        aliases[publicKey] ?? (publicKey == me ? "me" : String(fingerprint(publicKey).prefix(8)))
    }

    func people(_ chat: Chat) -> String {
        chat.participants.isEmpty ? "only me" : chat.participants.map(of).joined(separator: ", ")
    }

    func chat(_ chat: Chat, among chats: [Chat]) -> String {
        let tag = chatTag(chat.id)
        let name = tag.isEmpty ? people(chat) : "#\(tag)"
        let shared = chats.filter { chatTag($0.id) == tag && (tag.isEmpty ? $0.participants == chat.participants : true) }.count > 1
        return name + (shared ? "·\(chat.id.split(separator: "@").last?.prefix(4) ?? "")" : "")
    }
}

func fingerprint(_ publicKey: String) -> String {
    let keyBytes = Data(base64Encoded: publicKey) ?? Data(publicKey.utf8)
    return Data(SHA256.hash(data: keyBytes)).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func chatTag(_ chatId: String) -> String {
    chatId.contains("@") ? String(chatId.prefix { $0 != "@" }) : ""
}

func preview(_ body: Data) -> String {
    if let text = String(data: body, encoding: .utf8) {
        let control = text.prefix(4000).contains { character in
            guard let ascii = character.asciiValue else { return false }
            return ascii < 32 && character != "\n" && character != "\t"
        }
        if !control {
            return text.trimmingCharacters(in: .newlines)
        }
    }
    let types: [(magic: [UInt8], extension: String)] = [([0x89, 0x50, 0x4E, 0x47], "png"), ([0xFF, 0xD8], "jpg"), ([0x47, 0x49, 0x46, 0x38], "gif"), ([0x25, 0x50, 0x44, 0x46], "pdf")]
    let kind = types.first { body.starts(with: $0.magic) }?.extension ?? "bin"
    return "[\(kind) file, \(body.count.formatted()) bytes]"
}

func when(_ claimedAt: Int) -> String {
    let moment = Date(timeIntervalSince1970: Double(claimedAt) / 1e9)
    let calendar = Calendar.current
    if calendar.isDateInToday(moment) {
        return moment.formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDateInYesterday(moment) {
        return "Yesterday"
    }
    if calendar.component(.year, from: moment) == calendar.component(.year, from: .now) {
        return moment.formatted(.dateTime.month(.abbreviated).day())
    }
    return moment.formatted(.dateTime.month(.abbreviated).day().year())
}
