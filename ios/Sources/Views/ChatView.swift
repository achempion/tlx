import SwiftUI

private let groupWindow = 5 * 60 * 1_000_000_000
private let canvas = shade(light: 1, dark: 0.08)
private let bubble = shade(light: 0.93, dark: 0.17)

struct ChatView: View {
    let chat: Chat
    let title: String
    let names: Names

    @State private var store: Store?
    @State private var messages: [ChatMessage] = []
    @State private var pendings: [Pending] = []
    @State private var hasOlder = false
    @State private var readMarker = 0
    @State private var draft = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    if hasOlder {
                        Button("Load older") { loadOlder() }
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(entries) { entry in
                        row(entry).id(entry.id).padding(.top, entry.startsGroup ? 10 : 0)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.isEmpty) {
                if entries.contains(where: { $0.id == "new" }) {
                    proxy.scrollTo("new", anchor: .top)
                }
            }
            .onChange(of: pendings.count) { before, after in
                if after > before, let last = entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .background(canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if chat.isTopic {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline)
                        Text(names.people(chat)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Avatar(key: chat.participants.first ?? names.me, chat: chat.id, size: 32)
                }
            }
        }
        .task {
            guard let store = try? Store(ownPublicKey: names.me) else {
                return
            }
            self.store = store
            readMarker = store.lastRead(chatId: chat.id)
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
                    Avatar(key: entry.sender, chat: chat.id, size: 32).opacity(entry.startsGroup ? 1 : 0)
                }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    if entry.startsGroup && chat.isGroup && !mine {
                        Text(names.of(entry.sender))
                            .font(.subheadline.weight(.semibold))
                            .italic(names.aliases[entry.sender] == nil)
                            .foregroundStyle(color(of: entry.sender))
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
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(title)", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .modifier(Floating(shape: AnyShape(Capsule())))
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .modifier(Floating(shape: AnyShape(Circle())))
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // --- store ---

    private func reload() {
        guard let store else {
            return
        }
        messages = (try? store.messages(chatId: chat.id)) ?? []
        hasOlder = messages.count == page
        pendings = (try? store.pending(chatId: chat.id)) ?? []
        if let last = messages.last {
            store.markRead(chatId: chat.id, sequence: last.sequence)
        }
    }

    private func loadOlder() {
        guard let store, let oldest = messages.first else {
            return
        }
        let older = (try? store.messages(chatId: chat.id, before: oldest.sequence)) ?? []
        hasOlder = older.count == page
        messages = older + messages
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store else {
            return
        }
        try? store.send(chatId: chat.id, body: Data(text.utf8))
        draft = ""
        pendings = (try? store.pending(chatId: chat.id)) ?? []
    }
}

private func shade(light: CGFloat, dark: CGFloat) -> Color {
    Color(UIColor { UIColor(white: $0.userInterfaceStyle == .dark ? dark : light, alpha: 1) })
}

private struct Floating: ViewModifier {
    let shape: AnyShape

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            let rim = LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(rim, lineWidth: 0.5))
        }
    }
}
