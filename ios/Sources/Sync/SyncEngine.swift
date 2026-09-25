import Foundation

let syncDatabase = URL.applicationSupportDirectory.appending(path: "sync.db")

func foregroundSync(settings: Settings) async {
    guard let storage = try? Storage(path: syncDatabase, ownPublicKey: settings.identity.publicKey) else {
        return
    }
    let relay = Relay(address: settings.address, identity: settings.identity)
    await listen(relay: relay, storage: storage, identity: settings.identity)
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
    nil
}
