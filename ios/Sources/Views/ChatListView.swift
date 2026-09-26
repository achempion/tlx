import SwiftUI

struct ChatListView: View {
    let settings: Settings

    @State private var chats: [Chat] = []
    @State private var names: Names
    @State private var store: Store?
    @State private var creation: NewConversation?
    @State private var createdChat: Chat?
    @State private var openedChat: Chat?
    @State private var focusComposerOnOpen = false
    @State private var failure = ""

    init(settings: Settings) {
        self.settings = settings
        _names = State(initialValue: Names(me: settings.identity.publicKey))
    }

    var body: some View {
        List(chats) { chat in
            Button {
                focusComposerOnOpen = false
                openedChat = chat
            } label: {
                row(chat)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .swipeActions(allowsFullSwipe: false) {
                if chat.isDraft {
                    Button("Discard draft", role: .destructive) { discard(chat) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if chats.isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New chat", systemImage: "bubble.left.and.bubble.right") { creation = .chat }
                    Button("New topic", systemImage: "number") { creation = .topic }
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
                .accessibilityLabel("New conversation")
            }
        }
        .sheet(item: $creation, onDismiss: {
            if let createdChat {
                focusComposerOnOpen = true
                openedChat = createdChat
                self.createdChat = nil
            }
        }) { mode in
            NewConversationView(mode: mode, names: names) { chat in
                createdChat = chat
                reload()
            }
        }
        .navigationDestination(item: $openedChat) { chat in
            ChatView(chat: chat, chats: chats, names: names, focusComposer: focusComposerOnOpen)
        }
        .alert("Couldn’t update chats", isPresented: Binding(get: { !failure.isEmpty }, set: { if !$0 { failure = "" } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure)
        }
        .task(id: settings) {
            do {
                store = try Store(ownPublicKey: settings.identity.publicKey)
            } catch {
                failure = error.localizedDescription
                return
            }
            guard let store else { return }
            var version = -1
            var uiVersion = -1
            while !Task.isCancelled {
                let current = store.dataVersion()
                let currentUI = store.uiDataVersion()
                if current != version || currentUI != uiVersion {
                    version = current
                    uiVersion = currentUI
                    reload()
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    private func reload() {
        guard let store else { return }
        do {
            chats = try store.chats()
            names.aliases = try store.aliases()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func discard(_ chat: Chat) {
        do {
            try store?.discardDraft(chatId: chat.id)
            reload()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func row(_ chat: Chat) -> some View {
            HStack(spacing: 12) {
                avatar(chat)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(names.chat(chat, among: chats))
                            .fontWeight(chat.unread > 0 ? .semibold : .regular)
                            .lineLimit(1)
                        Spacer()
                        Text(when(chat.lastClaimedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if chat.isGroup && !chat.lastSender.isEmpty && chat.draft.isEmpty {
                        Text(names.of(chat.lastSender))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary(chat))
                            .font(.subheadline)
                            .foregroundStyle(chat.pending?.error != nil && chat.draft.isEmpty ? Color.red : .secondary)
                            .lineLimit(1)
                        Spacer()
                        if chat.unread > 0 {
                            Text("\(chat.unread)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.tint, in: Capsule())
                        }
                    }
                }
            }
            .padding(.vertical, 2)
    }

    private func summary(_ chat: Chat) -> String {
        if !chat.draft.isEmpty { return "Draft: " + chat.draft }
        if chat.isDraft { return "Draft" }
        if let pending = chat.pending {
            let status = pending.error != nil ? "Failed to send" : (pending.sent ? "Sent" : "Sending…")
            return status + " · " + preview(pending.body)
        }
        return preview(chat.lastBody)
    }

    private func avatar(_ chat: Chat) -> some View {
        Avatar(key: chat.isTopic ? chat.id : (chat.participants.first ?? settings.identity.publicKey), chat: chat.id, topic: chat.isTopic)
    }
}
