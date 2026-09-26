import Foundation
import Observation

@Observable
final class Composer {
    private(set) var text: String
    private(set) var failure = ""
    private let store: Store
    private let chatId: String

    init(store: Store, chatId: String) throws {
        self.store = store
        self.chatId = chatId
        text = try store.draftText(chatId: chatId)
    }

    func edit(_ text: String) {
        self.text = text
        do {
            try store.saveDraft(chatId: chatId, text: text)
            failure = ""
        } catch {
            failure = "Couldn’t save the draft: \(error.localizedDescription)"
        }
    }

    func send() -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        do {
            try store.send(chatId: chatId, body: Data(body.utf8))
            text = ""
            failure = ""
            return true
        } catch {
            failure = "Couldn’t send: \(error.localizedDescription)"
            return false
        }
    }
}

func topicName(_ input: String) throws -> String {
    var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.hasPrefix("#") { name.removeFirst() }
    guard !name.isEmpty else { throw ChatCreationError.emptyTopic }
    guard !name.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "#" }),
          name.rangeOfCharacter(from: .controlCharacters) == nil else { throw ChatCreationError.invalidTopic }
    return name
}

enum ChatCreationError: LocalizedError {
    case noRecipients, ownKey, alreadySelected, emptyTopic, invalidTopic, alreadyStarted

    var errorDescription: String? {
        switch self {
        case .noRecipients: "Choose at least one other person."
        case .ownKey: "This is your own public key. Choose someone else."
        case .alreadySelected: "This person is already selected."
        case .emptyTopic: "Enter a topic name."
        case .invalidTopic: "Use a short topic name without spaces, #, or @."
        case .alreadyStarted: "This conversation already has messages and can’t be discarded as a draft."
        }
    }
}
