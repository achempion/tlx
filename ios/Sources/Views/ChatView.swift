import SwiftUI

private let groupingIntervalNanoseconds = 5 * 60 * 1_000_000_000
private let canvas = shade(light: 1, dark: 0.08)
private let bubble = shade(light: 0.93, dark: 0.17)
private let maximumBubbleWidth: CGFloat = 520
#if targetEnvironment(macCatalyst)
private let contentInsets = EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20)
#else
private let contentInsets = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
#endif

struct ChatView: View {
    let chat: Chat
    let chats: [Chat]
    let names: Names
    var focusComposer = false

    private var title: String { names.chat(chat, among: chats) }

    @State private var store: Store?
    @State private var messages: [ChatMessage] = []
    @State private var pendings: [Pending] = []
    @State private var hasOlder = false
    @State private var readMarker = 0
    @State private var editor: Composer?
    @State private var failure = ""
    @State private var didFocus = false
    @State private var scrollID: String?
    @State private var pageAnchor: String?
    @State private var bottomSequence = -1
    @State private var openedUnread = false
    @Environment(\.scenePhase) private var scenePhase
    #if targetEnvironment(macCatalyst)
    @State private var composerFocused = false
    #else
    @FocusState private var composerFocused: Bool
    #endif

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(spacing: 3) {
                    if hasOlder {
                        Color.clear.frame(height: 1)
                            .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY >= viewport.frame(in: .global).minY - 200 } action: {
                                if $0 { loadOlder() }
                            }
                    }
                    ForEach(entries) { entry in
                        row(entry).id(entry.id).padding(.top, entry.startsGroup ? 10 : 0)
                            .onGeometryChange(for: Bool.self) { entry.id == "new" && viewport.frame(in: .global).intersects($0.frame(in: .global)) } action: {
                                if $0 { openedUnread = true }
                            }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onGeometryChange(for: Int.self) { viewport.frame(in: .global).contains($0.frame(in: .global)) ? messages.last?.sequence ?? 0 : -1 } action: {
                            bottomSequence = $0
                            markViewed()
                        }
                }
                .scrollTargetLayout()
                .padding(contentInsets)
            }
            .scrollPosition(id: $scrollID, anchor: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .defaultScrollAnchor(openedUnread || entries.contains(where: { $0.id == "new" }) ? nil : .bottom)
            .onChange(of: messages.first?.sequence) {
                if let pageAnchor { self.pageAnchor = nil; Task { await Task.yield(); scrollID = pageAnchor } }
            }
            .overlay(alignment: .bottom) {
                if bottomSequence < 0 && messages.contains(where: { $0.sequence > readMarker && $0.sender != names.me }) {
                    Button("↓ New messages") { Task { await Task.yield(); scrollID = "bottom" } }
                        .padding(10).background(.regularMaterial, in: Capsule())
                }
            }
            .onChange(of: messages.isEmpty) {
                if entries.contains(where: { $0.id == "new" }) { scrollID = "new" }
            }
            .onChange(of: pendings.count) { before, after in
                if after > before { scrollID = "bottom" }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .background(canvas)
        #if !targetEnvironment(macCatalyst)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: scenePhase) { markViewed() }
        .onDisappear { bottomSequence = -1 }
        #if !targetEnvironment(macCatalyst)
        .toolbar { ChatToolbar(chat: chat, chats: chats, names: names) }
        #endif
        .task {
            if store == nil {
                do {
                    let store = try Store(ownPublicKey: names.me)
                    editor = try Composer(store: store, chatId: chat.id)
                    self.store = store
                    readMarker = store.lastRead(chatId: chat.id)
                } catch {
                    failure = "Couldn’t open the conversation: \(error.localizedDescription)"
                    return
                }
            }
            guard let store else { return }
            if focusComposer && !didFocus {
                composerFocused = true
                didFocus = true
            }
            var version = -1
            while !Task.isCancelled {
                let current = store.dataVersion()
                if current != version {
                    version = current
                    reload()
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    private func profileLink<Label: View>(_ key: String, @ViewBuilder label: () -> Label) -> some View {
        ChatDestination.profile(key).link(chats: chats, names: names, label: label)
            .buttonStyle(.plain).accessibilityLabel("Profile for \(names.of(key))")
    }

    private struct Entry: Identifiable {
        let id: String
        let sender: String
        let claimedAt: Int
        var text = ""
        var time = ""
        var status: String?
        var failed = false
        var startsGroup = false
        var endsGroup = false
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        var linePlaced = false
        let complete = !hasOlder || messages.contains { $0.sequence <= readMarker }
        func add(_ entry: Entry) {
            var entry = entry
            entry.startsGroup = entries.last.map { $0.sender != entry.sender || !(0..<groupingIntervalNanoseconds).contains(entry.claimedAt - $0.claimedAt) } ?? true
            if entry.startsGroup, let last = entries.indices.last {
                entries[last].endsGroup = true
            }
            entries.append(entry)
        }
        for message in messages {
            if complete && !linePlaced && message.sequence > readMarker && message.sender != names.me {
                add(Entry(id: "new", sender: "", claimedAt: 0))
                linePlaced = true
            }
            add(Entry(id: "m\(message.sequence)", sender: message.sender, claimedAt: message.claimedAt,
                      text: preview(message.body), time: when(message.claimedAt)))
        }
        for pending in pendings {
            add(Entry(id: "p\(pending.claimedAt)", sender: names.me, claimedAt: pending.claimedAt, text: preview(pending.body),
                      status: pending.error ?? (pending.sent ? "sent" : "sending…"), failed: pending.error != nil))
        }
        if let last = entries.indices.last {
            entries[last].endsGroup = true
        }
        return entries
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        if entry.id == "new" {
            HStack(spacing: 8) {
                Rectangle().frame(height: 0.5)
                Text("new").font(.caption)
                Rectangle().frame(height: 0.5)
            }
            .foregroundStyle(.tint)
        } else {
            let mine = entry.sender == names.me
            let footer = entry.status ?? (entry.endsGroup ? entry.time : "")
            HStack(alignment: .top, spacing: 8) {
                if mine {
                    Spacer(minLength: 48)
                } else if chat.isGroup {
                    if entry.startsGroup {
                        profileLink(entry.sender) { Avatar(key: entry.sender, chat: chat.id, size: 32) }
                    } else {
                        Color.clear.frame(width: 32, height: 32)
                    }
                }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    if entry.startsGroup && chat.isGroup && !mine {
                        profileLink(entry.sender) {
                            Text(names.of(entry.sender))
                                .font(.subheadline.weight(.semibold))
                                .italic(names.aliases[entry.sender] == nil)
                                .foregroundStyle(color(of: entry.sender))
                        }
                    }
                    Text(entry.text)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(mine ? Color.white : .primary)
                        .background(mine ? Color.accentColor : bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if !footer.isEmpty {
                        Text(footer).font(.caption).foregroundStyle(entry.failed ? Color.red : .secondary)
                    }
                }
                .frame(maxWidth: maximumBubbleWidth, alignment: mine ? .trailing : .leading)
                if !mine {
                    Spacer(minLength: 48)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !failure.isEmpty {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
            if let editor {
                ChatComposerView(title: title, editor: editor, focused: $composerFocused, onSend: send)
            }
        }
        .padding(.horizontal, contentInsets.leading)
        .padding(.bottom, contentInsets.bottom)
    }

    // --- store ---

    private func markViewed() {
        guard scenePhase == .active, bottomSequence > readMarker, openedUnread || !entries.contains(where: { $0.id == "new" }) else { return }
        store?.markRead(chatId: chat.id, sequence: bottomSequence)
        readMarker = store?.lastRead(chatId: chat.id) ?? readMarker
        Task { await removeDeliveredNotifications(chatId: chat.id, upTo: readMarker) }
    }

    private func reload() {
        guard let store else {
            return
        }
        if let incoming = try? store.messages(chatId: chat.id, after: messages.last?.sequence) {
            if messages.isEmpty { hasOlder = incoming.count == page }
            messages += incoming
            if !incoming.isEmpty && bottomSequence >= 0 { Task { await Task.yield(); scrollID = "bottom" } }
        }
        pendings = (try? store.pending(chatId: chat.id)) ?? []
    }

    private func loadOlder() {
        guard let store, let oldest = messages.first else {
            return
        }
        guard let older = try? store.messages(chatId: chat.id, before: oldest.sequence) else { return }
        pageAnchor = scrollID
        scrollID = nil
        hasOlder = older.count == page
        messages = older + messages
    }

    private func send() {
        guard let store, editor?.send() == true else { return }
        pendings = (try? store.pending(chatId: chat.id)) ?? []
    }
}

private func shade(light: CGFloat, dark: CGFloat) -> Color {
    Color(UIColor { UIColor(white: $0.userInterfaceStyle == .dark ? dark : light, alpha: 1) })
}
