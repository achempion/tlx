import Core
import Foundation

let syncDatabase = URL.applicationSupportDirectory.appending(path: "sync.db")

func resetDatabases() {
    for database in [syncDatabase, uiDatabase] {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
        }
    }
}

func foregroundSync(settings: Settings) async {
    do {
        try FileManager.default.createDirectory(at: syncDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let relay = Relay(address: settings.address, identity: settings.identity)
        let receiving = try Storage(path: syncDatabase, ownPublicKey: settings.identity.publicKey)
        let sending = try Storage(path: syncDatabase, ownPublicKey: settings.identity.publicKey)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await listen(relay: relay, storage: receiving, identity: settings.identity) }
            group.addTask { await sendOutbox(relay: relay, storage: sending, identity: settings.identity) }
        }
    } catch {
        print("sync: \(error.localizedDescription)")
    }
}

func listen(relay: Relay, storage: Storage, identity: Identity) async {
    var lastSeen = storage.lastSeenSequence()
    while !Task.isCancelled {
        guard let blobs = try? await relay.get(after: lastSeen) else {
            try? await Task.sleep(for: .seconds(2))
            continue
        }
        for (sequence, blob) in blobs {
            lastSeen = sequence
            guard let message = decryptAndVerify(sequence: sequence, blob: blob, identity: identity) else {
                continue
            }
            do {
                try storage.save(message)
            } catch {
                print("message \(sequence): \(error.localizedDescription)")
            }
        }
    }
}

func decryptAndVerify(sequence: Int, blob: Data, identity: Identity) -> Message? {
    func drop(_ reason: String) -> Message? {
        print("message \(sequence): \(reason)")
        return nil
    }
    let newline = UInt8(ascii: "\n")
    guard let relayedAtEnd = blob.firstIndex(of: newline),
          let relayedAt = Int(String(decoding: blob[..<relayedAtEnd], as: UTF8.self)) else {
        return drop("no relayed_at line")
    }

    var error: NSError?
    guard let plaintext = CoreDecrypt(identity.privateKey, Data(blob[(relayedAtEnd + 1)...]), &error),
          let signatureStart = plaintext.range(of: Data("-----BEGIN SSH SIGNATURE-----".utf8), options: .backwards) else {
        return drop("cannot decrypt or not signed")
    }
    let signedContent = Data(plaintext[..<signatureStart.lowerBound])
    let signature = Data(plaintext[signatureStart.lowerBound...])

    let firstLineEnd = signedContent.firstIndex(of: newline) ?? signedContent.endIndex
    let words = String(decoding: signedContent[..<firstLineEnd], as: UTF8.self).split(whereSeparator: \.isWhitespace)
    guard words.count >= 3, words[1].allSatisfy({ $0.isASCII && $0.isNumber }), let claimedAt = Int(words[1]) else {
        return drop("first line must be CHAT CLAIMED_AT RECIPIENT_KEY...")
    }
    let recipientPublicKeys = unique(words[2...].map(String.init))
    guard recipientPublicKeys.contains(identity.publicKey) else {
        return drop("our key is not listed")
    }

    let senderPublicKey = CoreVerify(signedContent, signature, recipientPublicKeys.joined(separator: " "), &error)
    guard error == nil else {
        return drop("invalid signature")
    }

    let body = firstLineEnd < signedContent.endIndex ? Data(signedContent[(firstLineEnd + 1)...]) : Data()
    return Message(sequence: sequence, chatId: String(words[0]), recipientPublicKeys: recipientPublicKeys,
                   senderPublicKey: senderPublicKey, claimedAt: claimedAt, relayedAt: relayedAt, body: body)
}

func sendOutbox(relay: Relay, storage: Storage, identity: Identity) async {
    while !Task.isCancelled {
        for row in (try? storage.unsentOutbox()) ?? [] {
            let listed = row.recipientPublicKeys.isEmpty
                ? (try? storage.recipientPublicKeys(chatId: row.chatId)) ?? [] : row.recipientPublicKeys
            var recipients = unique([identity.publicKey] + listed)
            var result = Relay.PutResult(error: "no other deliverable recipients")
            while recipients.count > 1 {
                guard let blob = signAndEncrypt(chatId: row.chatId, claimedAt: row.claimedAt,
                                                recipientPublicKeys: recipients, body: row.body, identity: identity) else {
                    result = Relay.PutResult(error: "cannot sign or encrypt")
                    break
                }
                guard let attempt = try? await relay.put(recipientPublicKeys: recipients, blob: blob) else {
                    result = Relay.PutResult()          // could not reach the relay: the row waits for a later pass
                    break
                }
                result = attempt
                if attempt.rejectedPublicKeys.isEmpty {
                    break
                }
                try? storage.markRejected(publicKeys: attempt.rejectedPublicKeys)
                recipients.removeAll { attempt.rejectedPublicKeys.contains($0) }
                result = Relay.PutResult(error: "no other deliverable recipients")
            }
            if result.accepted {
                try? storage.markSent(claimedAt: row.claimedAt)
            } else if let error = result.error {
                try? storage.markFailed(claimedAt: row.claimedAt, error: error)
            }
        }
        try? await Task.sleep(for: .seconds(1))
    }
}

func signAndEncrypt(chatId: String, claimedAt: Int, recipientPublicKeys: [String], body: Data, identity: Identity) -> Data? {
    let signedContent = Data("\(chatId) \(claimedAt) \(recipientPublicKeys.joined(separator: " "))\n".utf8) + body
    var error: NSError?
    guard let signature = CoreSign(identity.privateKey, signedContent, &error),
          let blob = CoreEncrypt(recipientPublicKeys.joined(separator: " "), signedContent + signature, &error) else {
        return nil
    }
    return blob
}

func unique(_ keys: [String]) -> [String] {
    keys.reduce(into: []) { unique, key in
        if !unique.contains(key) {
            unique.append(key)
        }
    }
}
