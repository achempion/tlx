import SwiftUI

struct ChatListView: View {
    let settings: Settings
    let notifier: Notifier

    @State private var chats: [Chat] = []
    @State private var names: Names
    @State private var store: Store?
    @State private var creation: NewConversation?
    @State private var createdChat: Chat?
    @State private var openedChat: Chat?
    @State private var focusComposerOnOpen = false
    @State private var failure = ""

    init(settings: Settings, notifier: Notifier) {
        self.settings = settings
        self.notifier = notifier
        _names = State(initialValue: Names(me: settings.identity.publicKey))
    }

    var body: some View {
        List(chats) { chat in
            Button {
                focusComposerOnOpen = false
                openedChat = chat
            } label: {
                ChatListRow(chat: chat, chats: chats, names: names, isSelected: openedChat?.id == chat.id)
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
                .id(chat.id)
        }
        .onChange(of: notifier.chatToOpen) { openChatFromNotification() }
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
        openChatFromNotification()
    }

    private func openChatFromNotification() {
        guard let id = notifier.chatToOpen, let chat = chats.first(where: { $0.id == id }) else { return }
        notifier.chatToOpen = nil
        focusComposerOnOpen = false
        openedChat = chat
    }

    private func discard(_ chat: Chat) {
        do {
            try store?.discardDraft(chatId: chat.id)
            reload()
        } catch {
            failure = error.localizedDescription
        }
    }
}
