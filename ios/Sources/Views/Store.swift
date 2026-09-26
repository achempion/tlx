import CryptoKit
import Foundation
import Observation

let uiDatabase = URL.applicationSupportDirectory.appending(path: "ui.db")

private let schema = """
create table if not exists read (chat_id text primary key, sequence integer not null);
create table if not exists alias (public_key text primary key, name text not null unique);
create table if not exists setting (key text primary key, value text not null);
create table if not exists draft (
    chat_id text primary key,
    recipient_public_keys text,
    body text not null default '',
    updated_at integer not null
);
"""

struct Chat: Identifiable, Hashable {
    let id: String
    let lastSequence: Int
    let unread: Int
    let participants: [String]
    let lastSender: String
    let lastClaimedAt: Int
    let lastBody: Data
    var draft = ""
    var pending: Pending?
    var isTopic: Bool { !chatTag(id).isEmpty }
    var isGroup: Bool { isTopic || participants.count > 1 }
    var isDraft: Bool { lastSequence == 0 && pending == nil }
}

struct ChatMessage: Identifiable {
    let sequence: Int
    let sender: String
    let claimedAt: Int
    let body: Data
    var id: Int { sequence }
}

struct Pending: Identifiable, Hashable {
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
        _ = try Storage(path: syncPath, ownPublicKey: ownPublicKey)   // creates the sync tables before the first sync does
        db = try SQLite(path: uiPath)
        _ = try db.run("attach database ? as d", [syncPath.path])
        try db.execute(schema)
    }

    func dataVersion() -> Int {
        (try? db.query("pragma d.data_version"))?.first?.int(0) ?? 0
    }

    func uiDataVersion() -> Int {
        (try? db.query("pragma main.data_version"))?.first?.int(0) ?? 0
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
                    where u.chat_id = m.chat_id and u.sequence > coalesce(r.sequence, 0) and q.public_key != ?),
                   m.relayed_at
            from d.messages m
            join d.seen_participants p on p.id = m.sender_id
            left join read r on r.chat_id = m.chat_id
            where m.sequence = (select max(sequence) from d.messages where chat_id = m.chat_id)
            order by m.sequence desc
            """, [me])
        let confirmed = Dictionary(uniqueKeysWithValues: rows.map { ($0.text(0), $0) })
        let drafts = Dictionary(uniqueKeysWithValues: try db.query("select chat_id, recipient_public_keys, body, updated_at from draft")
            .map { ($0.text(0), $0) })
        let outbox = Dictionary(uniqueKeysWithValues: try db.query("""
            select o.chat_id, o.claimed_at, o.body, o.sent_at is not null, o.error, o.recipient_public_keys
            from d.outbox o where o.claimed_at = (select max(claimed_at) from d.outbox where chat_id = o.chat_id)
            """).map { ($0.text(0), $0) })
        let ids = Set(confirmed.keys).union(drafts.keys).union(outbox.keys)
        var chats: [(activity: Double, chat: Chat)] = []
        for id in ids {
            let message = confirmed[id]
            let local = drafts[id]
            let pending: Pending? = outbox[id].map {
                Pending(claimedAt: $0.int(1), body: $0.blob(2), sent: $0.int(3) == 1,
                        error: $0.text(4).isEmpty ? nil : $0.text(4))
            }
            let people: [String]
            if message != nil {
                people = participants[id] ?? []
            } else {
                let listed = (local?.text(1) ?? "") + " " + (outbox[id]?.text(5) ?? "")
                people = Array(Set(listed.split(whereSeparator: \.isWhitespace).map(String.init))).filter { $0 != me }.sorted()
            }
            let claimedAt: Int = pending?.claimedAt ?? message?.int(3) ?? local?.int(3) ?? 0
            let body: Data = pending?.body ?? message?.blob(4) ?? Data()
            let chat = Chat(id: id, lastSequence: message?.int(1) ?? 0, unread: message?.int(5) ?? 0, participants: people,
                            lastSender: pending != nil ? me : (message?.text(2) ?? ""),
                            lastClaimedAt: claimedAt, lastBody: body, draft: local?.text(2) ?? "", pending: pending)
            let localActivity = Double(max(local?.int(3) ?? 0, pending?.claimedAt ?? 0)) / 1e9
            let activity = max(Double(message?.int(6) ?? 0), localActivity)
            chats.append((activity, chat))
        }
        chats.sort {
            if $0.activity != $1.activity { return $0.activity > $1.activity }
            if $0.chat.lastSequence != $1.chat.lastSequence { return $0.chat.lastSequence > $1.chat.lastSequence }
            return $0.chat.id < $1.chat.id
        }
        return chats.map(\.chat)
    }

    func messages(chatId: String, before: Int? = nil, after: Int? = nil) throws -> [ChatMessage] {
        let rows = try db.query("select m.sequence, p.public_key, m.claimed_at, m.body "
                                + "from d.messages m join d.seen_participants p on p.id = m.sender_id "
                                + "where m.chat_id = ? and (? is null or m.sequence < ?) and m.sequence > ? order by m.sequence desc limit ?",
                                [chatId, before, before, after ?? 0, after == nil ? page : -1])
        return rows.reversed().map { ChatMessage(sequence: $0.int(0), sender: $0.text(1), claimedAt: $0.int(2), body: $0.blob(3)) }
    }

    func pending(chatId: String) throws -> [Pending] {
        try db.query("select claimed_at, body, sent_at is not null, error from d.outbox where chat_id = ? order by claimed_at", [chatId])
            .map { Pending(claimedAt: $0.int(0), body: $0.blob(1), sent: $0.int(2) == 1, error: $0.text(3).isEmpty ? nil : $0.text(3)) }
    }

    func send(chatId: String, body: Data, recipients: [String]? = nil) throws {
        try db.execute("begin immediate")
        do {
            let confirmed = try !db.query("select 1 from d.messages where chat_id = ? limit 1", [chatId]).isEmpty
            var listed = recipients?.joined(separator: " ")
            if listed == nil && !confirmed {
                listed = try db.query("select recipient_public_keys from draft where chat_id = ?", [chatId]).first?.text(0)
                if listed?.isEmpty != false {
                    listed = try db.query("select recipient_public_keys from d.outbox where chat_id = ? "
                                          + "and recipient_public_keys is not null order by claimed_at desc limit 1", [chatId]).first?.text(0)
                }
                guard listed?.isEmpty == false else { throw ChatCreationError.noRecipients }
            }
            let newest = try db.query("select coalesce(max(claimed_at), 0) from d.outbox")[0].int(0)
            lastClaimedAt = max(Int(Date().timeIntervalSince1970 * 1_000_000_000), max(lastClaimedAt, newest) + 1)
            _ = try db.run("insert into d.outbox (claimed_at, chat_id, recipient_public_keys, body) values (?, ?, ?, ?)",
                           [lastClaimedAt, chatId, listed, body])
            if confirmed {
                _ = try db.run("delete from draft where chat_id = ?", [chatId])
            } else {
                _ = try db.run("update draft set body = '', updated_at = ? where chat_id = ?", [lastClaimedAt, chatId])
            }
            try db.execute("commit")
        } catch {
            try? db.execute("rollback")
            throw error
        }
    }

    func createChat(topic: String? = nil, recipients: [String]) throws -> Chat {
        let tag = try topic.map(topicName) ?? ""
        let people = try Array(Set(recipients.map(SSH.publicKey))).sorted()
        guard !people.isEmpty else { throw ChatCreationError.noRecipients }
        guard !people.contains(me) else { throw ChatCreationError.ownKey }
        let id = tag + "@" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let now = Int(Date().timeIntervalSince1970 * 1_000_000_000)
        _ = try db.run("insert into draft (chat_id, recipient_public_keys, updated_at) values (?, ?, ?)",
                       [id, people.joined(separator: " "), now])
        return Chat(id: id, lastSequence: 0, unread: 0, participants: people, lastSender: "", lastClaimedAt: now, lastBody: Data())
    }

    func draftText(chatId: String) throws -> String {
        try db.query("select body from draft where chat_id = ?", [chatId]).first?.text(0) ?? ""
    }

    func saveDraft(chatId: String, text: String) throws {
        if text.isEmpty {
            _ = try db.run("update draft set body = '' where chat_id = ?", [chatId])
            _ = try db.run("delete from draft where chat_id = ? and recipient_public_keys is null", [chatId])
        } else {
            _ = try db.run("insert into draft (chat_id, body, updated_at) values (?, ?, ?) "
                            + "on conflict (chat_id) do update set body = excluded.body, updated_at = excluded.updated_at",
                           [chatId, text, Int(Date().timeIntervalSince1970 * 1_000_000_000)])
        }
    }

    func discardDraft(chatId: String) throws {
        let removed = try db.run("delete from draft where chat_id = ? "
                                + "and not exists (select 1 from d.messages where chat_id = ?) "
                                + "and not exists (select 1 from d.outbox where chat_id = ?)", [chatId, chatId, chatId])
        guard removed > 0 else { throw ChatCreationError.alreadyStarted }
    }

    func knownContacts() throws -> [String] {
        var keys = Set(try db.query("select public_key from d.seen_participants union select public_key from alias").map { $0.text(0) })
        for row in try db.query("select recipient_public_keys from draft union select recipient_public_keys from d.outbox") {
            keys.formUnion(row.text(0).split(whereSeparator: \.isWhitespace).map(String.init))
        }
        return keys.filter { $0 != me }.sorted()
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
        let shared = chats.filter { chatTag($0.id) == tag && (tag.isEmpty ? Set($0.participants) == Set(chat.participants) : true) }.count > 1
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
