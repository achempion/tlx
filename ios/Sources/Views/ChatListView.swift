import SwiftUI

struct ChatListView: View {
    @Binding var settings: Settings
    let notifier: Notifier

    @State private var chats: [Chat] = []
    @State private var names: Names
    @State private var sidebarStore: Store?
    // SQLite data_version only observes writes from other connections.
    @State private var sessionStore: Store?
    @State private var session: ChatSession?
    @State private var creation: NewConversation?
    #if targetEnvironment(macCatalyst)
    @State private var detailPath: [ChatDestination] = []
    #else
    @State private var createdChat: Chat?
    #endif
    @State private var openedChat: Chat?
    @State private var focusComposerOnOpen = false
    @State private var failure = ""
    @State private var showingSettings = false

    init(settings: Binding<Settings>, notifier: Notifier) {
        _settings = settings
        self.notifier = notifier
        _names = State(initialValue: Names(me: settings.wrappedValue.identity.publicKey))
    }

    var body: some View {
        navigation
        #if !targetEnvironment(macCatalyst)
        .sheet(item: $creation, onDismiss: openCreatedChat) { mode in NavigationStack { newConversation(mode) } }
        #endif
        .onChange(of: notifier.chatToOpen) { openChatFromNotification() }
        .alert("Couldn’t update chats", isPresented: Binding(get: { !failure.isEmpty }, set: { if !$0 { failure = "" } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure)
        }
        .task(id: settings) {
            open(nil)
            sidebarStore = nil
            sessionStore = nil
            do {
                sidebarStore = try Store(ownPublicKey: settings.identity.publicKey)
                sessionStore = try Store(ownPublicKey: settings.identity.publicKey)
            } catch {
                failure = error.localizedDescription
                return
            }
            guard let sidebarStore else { return }
            var loadedDataVersion: Int?
            var loadedUIDataVersion: Int?
            while !Task.isCancelled {
                let current = sidebarStore.dataVersion()
                let currentUI = sidebarStore.uiDataVersion()
                if current != loadedDataVersion || currentUI != loadedUIDataVersion {
                    loadedDataVersion = current
                    loadedUIDataVersion = currentUI
                    reload()
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    @ViewBuilder
    private var navigation: some View {
        #if targetEnvironment(macCatalyst)
        NavigationSplitView {
            chatList
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            NavigationStack(path: $detailPath) {
                Group {
                    if let chat = selectedChat {
                        conversation(chat)
                    } else {
                        ContentUnavailableView("Select a chat", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                // The header supplies the title. Changing the hidden native title rebuilds the Mac toolbar.
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .background(MacWindowTitleHidden())
                .toolbar {
                    if let chat = selectedChat {
                        ChatToolbar(chat: chat, chats: chats, names: names)
                    }
                }
                .navigationDestination(for: ChatDestination.self) { $0.view(chats: chats, names: names) }
                .navigationDestination(isPresented: $showingSettings) { settingsView }
                .navigationDestination(item: $creation) { newConversation($0) }
            }
            .background(MacSidebarConfiguration())
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        #else
        NavigationStack {
            chatList
                .navigationDestination(item: $openedChat) { opened in
                    conversation(chats.first { $0.id == opened.id } ?? opened)
                }
                .navigationDestination(isPresented: $showingSettings) { settingsView }
        }
        #endif
    }

    private var selectedChat: Chat? { chats.first(where: { $0.id == openedChat?.id }) }

    private var settingsView: some View {
        SettingsView(settings: Binding($settings))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var settingsButton: some View {
        Button { creation = nil; showingSettings = true } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Settings")
    }

    private var chatList: some View {
        selectableList
        .navigationTitle("Chats")
        .toolbarTitleDisplayMode(.inlineLarge)
        #if targetEnvironment(macCatalyst)
        .listStyle(.sidebar)
        .background(MacSidebarConfiguration())
        .contentMargins(.top, 8, for: .scrollContent)
        .contentMargins(.horizontal, 8, for: .scrollContent)
        .tint(Color(uiColor: .secondarySystemFill))
        #else
        .listStyle(.plain)
        #endif
        .overlay {
            if chats.isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .toolbar {
            #if targetEnvironment(macCatalyst)
            macToolbar.withoutSharedBackground()
            #else
            ToolbarItem(placement: .topBarTrailing) { newConversationMenu }
            ToolbarItem(placement: .topBarTrailing) { settingsButton }
            #endif
        }
    }

    @ViewBuilder
    private var selectableList: some View {
        #if targetEnvironment(macCatalyst)
        List(selection: Binding<String?>(
            get: { openedChat?.id },
            set: { id in
                if let chat = chats.first(where: { $0.id == id }) { open(chat) }
            }
        )) { chatRows }
        #else
        List { chatRows }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Text("Chats").font(.headline)
        }
        ToolbarItem(placement: .topBarLeading) { settingsButton }
        ToolbarItem(placement: .topBarTrailing) { newConversationMenu }
    }
    #endif

    private var newConversationMenu: some View {
        Menu {
            Button("New chat", systemImage: "bubble.left.and.bubble.right") { startCreation(.chat) }
            Button("New topic", systemImage: "number") { startCreation(.topic) }
        } label: {
            Label("New", systemImage: "square.and.pencil")
        }
        .accessibilityLabel("New conversation")
        .menuIndicator(.hidden)
        .help("New chat or topic")
    }

    private var chatRows: some View {
        ForEach(chats) { chat in
            let row = ChatListRow(chat: chat, chats: chats, names: names, isSelected: openedChat?.id == chat.id)
            Group {
                #if targetEnvironment(macCatalyst)
                row
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .foregroundStyle(.primary)
                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                #else
                Button { open(chat) } label: {
                    row.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #endif
            }
            .listRowSeparator(.hidden)
            .swipeActions(allowsFullSwipe: false) {
                if chat.isDraft {
                    Button("Discard draft", role: .destructive) { discard(chat) }
                }
            }
        }
    }

    @ViewBuilder
    private func conversation(_ chat: Chat) -> some View {
        if let session, session.chatId == chat.id {
            let content = ChatView(chat: chat, session: session, chats: chats, names: names, focusComposer: focusComposerOnOpen)
                .id(chat.id)
            #if targetEnvironment(macCatalyst)
            MacChatContent(content: content)
            #else
            content
            #endif
        }
    }

    private func startCreation(_ mode: NewConversation) {
        showingSettings = false
        creation = mode
    }

    private func open(_ chat: Chat?, focusingComposer: Bool = false) {
        let preparedSession: ChatSession?
        do {
            if let chat {
                guard let sessionStore else { return }
                preparedSession = openedChat?.id == chat.id ? session : try ChatSession(store: sessionStore, chatId: chat.id)
            } else {
                preparedSession = nil
            }
        } catch {
            failure = error.localizedDescription
            return
        }
        var transaction = Transaction()
        #if targetEnvironment(macCatalyst)
        transaction.disablesAnimations = true
        #endif
        withTransaction(transaction) {
            #if targetEnvironment(macCatalyst)
            detailPath = []
            #endif
            creation = nil
            showingSettings = false
            focusComposerOnOpen = focusingComposer
            session = preparedSession
            openedChat = chat
        }
    }

    private func newConversation(_ mode: NewConversation) -> some View {
        NewConversationView(mode: mode, names: names) { chat in
            reload()
            #if targetEnvironment(macCatalyst)
            open(chat, focusingComposer: true)
            #else
            createdChat = chat
            #endif
        }
    }

    #if !targetEnvironment(macCatalyst)
    private func openCreatedChat() {
        guard let createdChat else { return }
        self.createdChat = nil
        open(createdChat, focusingComposer: true)
    }
    #endif

    private func reload() {
        guard let sidebarStore else { return }
        do {
            chats = try sidebarStore.chats()
            names.aliases = try sidebarStore.aliases()
        } catch {
            failure = error.localizedDescription
        }
        openChatFromNotification()
    }

    private func openChatFromNotification() {
        guard let id = notifier.chatToOpen, let chat = chats.first(where: { $0.id == id }) else { return }
        notifier.chatToOpen = nil
        open(chat)
    }

    private func discard(_ chat: Chat) {
        do {
            try sidebarStore?.discardDraft(chatId: chat.id)
            reload()
            if openedChat?.id == chat.id { open(nil) }
        } catch {
            failure = error.localizedDescription
        }
    }
}
