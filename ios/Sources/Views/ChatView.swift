import SwiftUI

private let groupingIntervalNanoseconds = 5 * 60 * 1_000_000_000
private let canvas = shade(light: 1, dark: 0.08)
private let bubble = shade(light: 0.93, dark: 0.17)
private let maximumBubbleWidth: CGFloat = 520
#if targetEnvironment(macCatalyst)
private let contentInsets = EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20)
private let chatOpensWithPush = false
#else
private let contentInsets = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
private let chatOpensWithPush = true
#endif
private let transcriptEnd = "end"

struct ChatView: View {
    let chat: Chat
    let session: ChatSession
    let chats: [Chat]
    let names: Names
    var focusComposer = false

    private var title: String { names.chat(chat, among: chats) }

    @State private var didApplyInitialFocus = false
    @State private var isStickingToBottom = chatOpensWithPush
    @State private var bottomScrollRequest = 0
    @State private var visibleBottomSequence: Int?
    @State private var messageSelection = MessageSelectionRegistry()
    @Environment(\.scenePhase) private var scenePhase
    #if targetEnvironment(macCatalyst)
    @State private var composerFocused = false
    @State private var windowActive = false
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
            #if targetEnvironment(macCatalyst)
            .background(MacWindowActivity(visibleChat: visibleBottomSequence == nil ? nil : chat.id) { windowActive = $0 })
            .onChange(of: windowActive) { markViewed() }
            #else
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
                                .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY >= viewport.frame(in: .global).minY } action: {
                                    if $0 && !isStickingToBottom { session.loadOlder() }
                                }
                        }
                        ForEach(entries) { entry in
                            row(entry).padding(.top, entry.startsGroup ? 10 : 0)
                        }
                        Color.clear.frame(height: 1)
                            .onGeometryChange(for: Int?.self) { viewport.frame(in: .global).contains($0.frame(in: .global)) ? lastSequence : nil } action: {
                                visibleBottomSequence = $0
                                markViewed()
                            }
                            .padding(.bottom, contentInsets.bottom)
                            .id(transcriptEnd)
                    }
                    .padding(EdgeInsets(top: contentInsets.top, leading: contentInsets.leading, bottom: 0, trailing: contentInsets.trailing))
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .bottom)
                    .background {
                        Color.clear.contentShape(Rectangle()).onTapGesture { clearTranscriptFocus() }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .modifier(StickToBottom(isSticking: $isStickingToBottom) { proxy.scrollTo(transcriptEnd, anchor: .bottom) })
                .onChange(of: session.messages.first?.sequence) { previousFirst, _ in
                    if let previousFirst { proxy.scrollTo(Entry.messageID(previousFirst), anchor: .top) }
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
            .onChange(of: bottomScrollRequest) { withAnimation { proxy.scrollTo(transcriptEnd, anchor: .bottom) } }
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

        static func messageID(_ sequence: Int) -> String { "m\(sequence)" }
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
            add(Entry(id: Entry.messageID(message.sequence), sender: message.sender, claimedAt: message.claimedAt,
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
                    SelectableMessageText(text: entry.text, mine: mine, selectionRegistry: messageSelection)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(mine ? Color.accentColor : bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
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

    private func clearTranscriptFocus() {
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        messageSelection.clear()
    }

    private func markViewed() {
        #if targetEnvironment(macCatalyst)
        guard windowActive else { return }
        #endif
        guard scenePhase == .active, let visibleBottomSequence, visibleBottomSequence > session.readMarker else { return }
        session.markRead(upTo: visibleBottomSequence)
        Task { await removeDeliveredNotifications(chatId: chat.id, upTo: session.readMarker) }
    }
}

private struct StickToBottom: ViewModifier {
    @Binding var isSticking: Bool
    let scrollToBottom: () -> Void

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
            guard isSticking, !new.isAtBottom else { return }
            if new.layoutChanged(since: old) {
                withTransaction(\.disablesAnimations, true, scrollToBottom)
            } else if new.isInWindow {
                isSticking = false
            }
        }
    }
}

private extension ScrollGeometry {
    var distanceToBottom: CGFloat { contentSize.height - containerSize.height - contentInsets.top - contentOffset.y }
    var isAtBottom: Bool { distanceToBottom <= 0.5 }
    var isInWindow: Bool { contentInsets.bottom > 0 }

    func layoutChanged(since old: ScrollGeometry) -> Bool {
        contentSize != old.contentSize || containerSize != old.containerSize || contentInsets != old.contentInsets
    }
}

private let messageLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
private let maximumLinkDetectionLength = 32_768

final class MessageSelectionRegistry {
    private weak var selectedView: UITextView?

    func selectionChanged(in view: UITextView) {
        if view.selectedRange.length > 0 {
            selectedView = view
        } else if selectedView === view {
            selectedView = nil
        }
    }

    func clear() {
        guard let view = selectedView else { return }
        selectedView = nil
        view.selectedRange = NSRange(location: view.selectedRange.location, length: 0)
    }

    func remove(_ view: UITextView) {
        if selectedView === view { selectedView = nil }
    }
}

func linkedMessageText(_ text: String) -> NSAttributedString {
    let source = text as NSString
    let result = NSMutableAttributedString(string: text)
    guard source.length <= maximumLinkDetectionLength, let messageLinkDetector else {
        return result
    }

    for match in messageLinkDetector.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        guard NSMaxRange(match.range) <= source.length else { continue }
        let label = source.substring(with: match.range)
        let lowercasedLabel = label.lowercased()
        guard lowercasedLabel.hasPrefix("http://") || lowercasedLabel.hasPrefix("https://"),
              let url = URL(string: label), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"), url.host?.isEmpty == false else {
            continue
        }

        result.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
    }
    return result
}

struct SelectableMessageText: UIViewRepresentable {
    let text: String
    let mine: Bool
    let selectionRegistry: MessageSelectionRegistry?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    init(text: String, mine: Bool, selectionRegistry: MessageSelectionRegistry? = nil) {
        self.text = text
        self.mine = mine
        self.selectionRegistry = selectionRegistry
    }

    final class MessageTextView: UITextView {
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { selectedRange = NSRange(location: selectedRange.location, length: 0) }
            return resigned
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: String?
        var mine: Bool?
        var dynamicTypeSize: DynamicTypeSize?
        var legibilityWeight: LegibilityWeight?
        var measuredSizes: [(maxWidth: CGFloat, size: CGSize)] = []
        var selectionRegistry: MessageSelectionRegistry?

        init(selectionRegistry: MessageSelectionRegistry?) {
            self.selectionRegistry = selectionRegistry
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selectionRegistry?.selectionChanged(in: textView)
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            UITextItem.MenuConfiguration(preview: nil, menu: defaultMenu)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selectionRegistry: selectionRegistry) }

    func makeUIView(context: Context) -> UITextView {
        let view = MessageTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if context.coordinator.selectionRegistry !== selectionRegistry {
            context.coordinator.selectionRegistry?.remove(view)
            context.coordinator.selectionRegistry = selectionRegistry
            selectionRegistry?.selectionChanged(in: view)
        }
        guard context.coordinator.text != text || context.coordinator.mine != mine ||
              context.coordinator.dynamicTypeSize != dynamicTypeSize ||
              context.coordinator.legibilityWeight != legibilityWeight else { return }
        context.coordinator.text = text
        context.coordinator.mine = mine
        context.coordinator.dynamicTypeSize = dynamicTypeSize
        context.coordinator.legibilityWeight = legibilityWeight
        context.coordinator.measuredSizes.removeAll()

        let content = NSMutableAttributedString(attributedString: linkedMessageText(text))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let traits = UITraitCollection(traitsFrom: [view.traitCollection,
                                                   UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))])
        let preferredFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let font = legibilityWeight == .bold
            ? UIFont(descriptor: preferredFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? preferredFont.fontDescriptor,
                     size: preferredFont.pointSize)
            : preferredFont
        content.addAttributes([
            .font: font,
            .foregroundColor: mine ? UIColor.white : UIColor.label,
            .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: content.length))
        view.linkTextAttributes = [
            .foregroundColor: mine ? UIColor.white : UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        view.tintColor = mine ? .black : nil
        view.attributedText = content
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.selectionRegistry?.remove(view)
        view.delegate = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let maxWidth = max(1, min(proposal.width ?? maximumBubbleWidth, maximumBubbleWidth))
        let lineHeight = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        if maxWidth < lineHeight {
            return CGSize(width: maxWidth, height: ceil(lineHeight))
        }
        if let cached = context.coordinator.measuredSizes.first(where: { $0.maxWidth == maxWidth }) {
            return cached.size
        }
        let bounds = uiView.attributedText.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let width = min(maxWidth, max(1, ceil(bounds.width) + 1))
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let size = CGSize(width: width, height: ceil(height))
        if context.coordinator.measuredSizes.count == 4 {
            context.coordinator.measuredSizes.removeFirst()
        }
        context.coordinator.measuredSizes.append((maxWidth, size))
        return size
    }
}

private func shade(light: CGFloat, dark: CGFloat) -> Color {
    Color(UIColor { UIColor(white: $0.userInterfaceStyle == .dark ? dark : light, alpha: 1) })
}
