import SwiftUI

private let groupWindow = 5 * 60 * 1_000_000_000
private let canvas = shade(light: 1, dark: 0.08)
private let bubble = shade(light: 0.93, dark: 0.17)

struct ChatView: View {
    let chat: Chat
    let chats: [Chat]
    let names: Names
    var focusComposer = false

    private var title: String { names.chat(chat, among: chats) }
    private var contactKey: String { chat.participants.first ?? names.me }

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
    @FocusState private var composerFocused: Bool

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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollPosition(id: $scrollID, anchor: .top)
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
                scrollID = entries.contains(where: { $0.id == "new" }) ? "new" : "bottom"
            }
            .onChange(of: pendings.count) { before, after in
                if after > before { scrollID = "bottom" }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .background(canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { markViewed() }
        .onDisappear { bottomSequence = -1 }
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink {
                    if chat.isGroup {
                        ChatDetailsView(chat: chat, chats: chats, names: names)
                    } else {
                        ProfileView(publicKey: contactKey, names: names)
                    }
                } label: {
                    VStack(spacing: 0) {
                        Text(title).font(.headline).lineLimit(1)
                        if chat.isGroup {
                            Text(chat.isTopic ? names.people(chat) : "\(chat.participants.count + 1) participants")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chat.isGroup ? "Chat details for \(title)" : "Profile for \(names.of(contactKey))")
            }
            if !chat.isGroup {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ProfileView(publicKey: contactKey, names: names)
                    } label: {
                        Avatar(key: contactKey, chat: chat.id, size: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile for \(names.of(contactKey))")
                }
            }
        }
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

    // --- rows ---

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
            entry.startsGroup = entries.last.map { $0.sender != entry.sender || !(0..<groupWindow).contains(entry.claimedAt - $0.claimedAt) } ?? true
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
                    NavigationLink {
                        ProfileView(publicKey: entry.sender, names: names)
                    } label: {
                        Avatar(key: entry.sender, chat: chat.id, size: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile for \(names.of(entry.sender))")
                    .opacity(entry.startsGroup ? 1 : 0)
                    .allowsHitTesting(entry.startsGroup)
                    .accessibilityHidden(!entry.startsGroup)
                }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    if entry.startsGroup && chat.isGroup && !mine {
                        NavigationLink {
                            ProfileView(publicKey: entry.sender, names: names)
                        } label: {
                            Text(names.of(entry.sender))
                                .font(.subheadline.weight(.semibold))
                                .italic(names.aliases[entry.sender] == nil)
                                .foregroundStyle(color(of: entry.sender))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Profile for \(names.of(entry.sender))")
                    }
                    Text(entry.text)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(mine ? Color.accentColor : .primary)
                        .background(mine ? Color.accentColor.opacity(0.18) : bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if !footer.isEmpty {
                        Text(footer).font(.caption).foregroundStyle(entry.failed ? Color.red : .secondary)
                    }
                }
                if !mine {
                    Spacer(minLength: 48)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            let error = editor?.failure.isEmpty == false ? editor?.failure ?? "" : failure
            if !error.isEmpty {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(title)", text: Binding(get: { editor?.text ?? "" }, set: { editor?.edit($0) }), axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .disabled(editor == nil)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .modifier(Floating(shape: AnyShape(RoundedRectangle(cornerRadius: 22)), interactive: false))
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Send message")
                .modifier(Floating(shape: AnyShape(Circle())))
                .disabled(editor?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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

private struct Floating: ViewModifier {
    let shape: AnyShape
    var interactive = true

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.background {
                    Color.clear.glassEffect(.regular, in: shape).allowsHitTesting(false)
                }
            }
        } else {
            let rim = LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(rim, lineWidth: 0.5).allowsHitTesting(false))
        }
    }
}
