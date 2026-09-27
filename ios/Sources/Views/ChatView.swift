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
    let session: ChatSession
    let chats: [Chat]
    let names: Names
    var focusComposer = false

    private var title: String { names.chat(chat, among: chats) }

    @State private var didApplyInitialFocus = false
    @State private var scrollID: String?
    @State private var paginationAnchor: String?
    @State private var bottomScrollRequest = 0
    @State private var visibleBottomSequence: Int?
    @Environment(\.scenePhase) private var scenePhase
    #if targetEnvironment(macCatalyst)
    @State private var composerFocused = false
    #else
    @FocusState private var composerFocused: Bool
    #endif

    var body: some View {
        transcript
            .safeAreaInset(edge: .bottom) {
                ChatComposerView(title: title, editor: session.editor, focused: $composerFocused,
                                 onSend: { _ = session.send() })
                    .padding(.horizontal, contentInsets.leading)
                    .padding(.bottom, contentInsets.bottom)
                    .onAppear {
                        if focusComposer && !didApplyInitialFocus {
                            composerFocused = true
                            didApplyInitialFocus = true
                        }
                    }
            }
            .background(canvas)
            .onChange(of: scenePhase) { markViewed() }
            .onDisappear { visibleBottomSequence = nil }
            #if !targetEnvironment(macCatalyst)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ChatToolbar(chat: chat, chats: chats, names: names) }
            #endif
            .task {
                while !Task.isCancelled {
                    if session.refresh() && visibleBottomSequence != nil { bottomScrollRequest += 1 }
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
    }

    private var transcript: some View {
        let lastSequence = session.messages.last?.sequence ?? 0
        return ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    // Lazy row estimates shift the scroll position when the composer grows.
                    VStack(spacing: 3) {
                        if session.hasOlder {
                            Color.clear.frame(height: 1)
                                .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY >= viewport.frame(in: .global).minY - 200 } action: {
                                    if $0 { loadOlder() }
                                }
                        }
                        ForEach(entries) { entry in
                            row(entry).padding(.top, entry.startsGroup ? 10 : 0)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onGeometryChange(for: Int?.self) { viewport.frame(in: .global).contains($0.frame(in: .global)) ? lastSequence : nil } action: {
                                visibleBottomSequence = $0
                                markViewed()
                            }
                    }
                    .scrollTargetLayout()
                    .padding(contentInsets)
                }
                .scrollPosition(id: $scrollID, anchor: .top)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                .defaultScrollAnchor(.bottom)
                .onChange(of: session.messages.first?.sequence) {
                    if let paginationAnchor {
                        proxy.scrollTo(paginationAnchor, anchor: .top)
                        self.paginationAnchor = nil
                    }
                }
                .overlay(alignment: .bottom) {
                    if visibleBottomSequence == nil && session.messages.contains(where: { $0.sequence > session.readMarker && $0.sender != names.me }) {
                        Button("↓ New messages") { bottomScrollRequest += 1 }
                            .padding(10).background(.regularMaterial, in: Capsule())
                    }
                }
                .onChange(of: session.pendings.count) { before, after in
                    if after > before { bottomScrollRequest += 1 }
                }
            }
            .onChange(of: bottomScrollRequest) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
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

    private var canShowUnreadDivider: Bool {
        guard let openingReadMarker = session.openingReadMarker else { return false }
        return !session.hasOlder || session.messages.contains { $0.sequence <= openingReadMarker }
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        var dividerAfter = canShowUnreadDivider ? session.openingReadMarker : nil
        func add(_ entry: Entry) {
            var entry = entry
            entry.startsGroup = entries.last.map {
                $0.sender != entry.sender || !(0..<groupingIntervalNanoseconds).contains(entry.claimedAt - $0.claimedAt)
            } ?? true
            if entry.startsGroup, let last = entries.indices.last {
                entries[last].endsGroup = true
            }
            entries.append(entry)
        }
        for message in session.messages {
            if let marker = dividerAfter, message.sequence > marker && message.sender != names.me {
                add(Entry(id: "new", sender: "", claimedAt: 0))
                dividerAfter = nil
            }
            add(Entry(id: "m\(message.sequence)", sender: message.sender, claimedAt: message.claimedAt,
                      text: preview(message.body), time: when(message.claimedAt)))
        }
        for pending in session.pendings {
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

    private func markViewed() {
        guard scenePhase == .active, let visibleBottomSequence, visibleBottomSequence > session.readMarker else { return }
        session.markRead(upTo: visibleBottomSequence)
        Task { await removeDeliveredNotifications(chatId: chat.id, upTo: session.readMarker) }
    }

    private func loadOlder() {
        guard let oldest = session.messages.first else { return }
        let anchor = scrollID ?? "m\(oldest.sequence)"
        if session.loadOlder() { paginationAnchor = anchor }
    }
}

private func shade(light: CGFloat, dark: CGFloat) -> Color {
    Color(UIColor { UIColor(white: $0.userInterfaceStyle == .dark ? dark : light, alpha: 1) })
}
