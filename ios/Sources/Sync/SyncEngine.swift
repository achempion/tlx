import Core
import Foundation

let syncDatabase = URL.applicationSupportDirectory.appending(path: "sync.db")

func foregroundSync(settings: Settings) async {
    do {
        try FileManager.default.createDirectory(at: syncDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let storage = try Storage(path: syncDatabase, ownPublicKey: settings.identity.publicKey)
        let relay = Relay(address: settings.address, identity: settings.identity)
        await listen(relay: relay, storage: storage, identity: settings.identity)
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
            if let message = decryptAndVerify(sequence: sequence, blob: blob, identity: identity) {
                try? storage.save(message)
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
    let recipientPublicKeys = words[2...].map(String.init).reduce(into: [String]()) { keys, key in
        if !keys.contains(key) {
            keys.append(key)
        }
    }
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
