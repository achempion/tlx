import Foundation
import Observation

/// Prepared before navigation changes, so the transcript and draft exist on their first frame.
@MainActor
@Observable
final class ChatSession {
    let chatId: String
    let editor: Composer
    let openingReadMarker: Int?
    private(set) var messages: [ChatMessage]
    private(set) var pendings: [Pending]
    private(set) var hasOlder: Bool
    private(set) var readMarker: Int
    private let store: Store
    private var loadedDataVersion: Int?

    init(store: Store, chatId: String) throws {
        let messages = try store.messages(chatId: chatId)
        let readMarker = store.lastRead(chatId: chatId)
        self.store = store
        self.chatId = chatId
        self.messages = messages
        pendings = try store.pending(chatId: chatId)
        editor = try Composer(store: store, chatId: chatId)
        hasOlder = messages.count == messagePageSize
        self.readMarker = readMarker
        openingReadMarker = messages.contains { $0.sequence > readMarker && $0.sender != store.me } ? readMarker : nil
    }

    func refresh() -> Bool {
        let current = store.dataVersion()
        guard current != loadedDataVersion else { return false }
        do {
            let incoming = try store.messages(chatId: chatId, after: messages.last?.sequence)
            let pending = try store.pending(chatId: chatId)
            if messages.isEmpty { hasOlder = incoming.count == messagePageSize }
            messages += incoming
            pendings = pending
            loadedDataVersion = current
            return !incoming.isEmpty
        } catch {
            return false
        }
    }

    @discardableResult
    func loadOlder() -> Bool {
        guard hasOlder, let oldest = messages.first,
              let older = try? store.messages(chatId: chatId, before: oldest.sequence) else { return false }
        hasOlder = older.count == messagePageSize
        messages = older + messages
        return !older.isEmpty
    }

    func send() -> Bool {
        guard editor.send() else { return false }
        loadedDataVersion = nil // Own writes don't advance data_version.
        if let pending = try? store.pending(chatId: chatId) { pendings = pending }
        return true
    }

    func markRead(upTo sequence: Int) {
        guard sequence > readMarker else { return }
        store.markRead(chatId: chatId, sequence: sequence)
        readMarker = store.lastRead(chatId: chatId)
    }
}
