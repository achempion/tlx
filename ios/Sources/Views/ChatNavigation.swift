import SwiftUI

enum ChatDestination: Hashable {
    case profile(String)
    case details(String)

    @ViewBuilder
    func link<Label: View>(chats: [Chat], names: Names, @ViewBuilder label: () -> Label) -> some View {
        #if targetEnvironment(macCatalyst)
        NavigationLink(value: self, label: label)
        #else
        NavigationLink { view(chats: chats, names: names) } label: { label() }
        #endif
    }

    @ViewBuilder
    func view(chats: [Chat], names: Names) -> some View {
        switch self {
        case .profile(let key):
            ProfileView(publicKey: key, names: names)
        case .details(let id):
            if let chat = chats.first(where: { $0.id == id }) {
                ChatDetailsView(chat: chat, chats: chats, names: names)
            } else {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }
}

struct ChatToolbar: ToolbarContent {
    let chat: Chat
    let chats: [Chat]
    let names: Names

    private var title: String { names.chat(chat, among: chats) }
    private var contactKey: String { chat.participants.first ?? names.me }

    var body: some ToolbarContent {
        #if targetEnvironment(macCatalyst)
        ToolbarItem(placement: .topBarLeading) {
            detailsLink {
                HStack(spacing: 10) {
                    Avatar(chat: chat, me: names.me, size: 36)
                    titleLabel(alignment: .leading)
                }
                .padding(.leading, 8)
            }
        }
        .withoutSharedBackground()
        #else
        ToolbarItem(placement: .principal) { detailsLink { titleLabel() } }
        if !chat.isGroup {
            ToolbarItem(placement: .topBarTrailing) {
                detailsLink { Avatar(chat: chat, me: names.me, size: 32) }
            }
        }
        #endif
    }

    private func titleLabel(alignment: HorizontalAlignment = .center) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(title).font(.headline).lineLimit(1)
            if chat.isGroup {
                Text(chat.isTopic ? names.people(chat) : "\(chat.participants.count + 1) participants")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func detailsLink<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        let destination = chat.isGroup ? ChatDestination.details(chat.id) : .profile(contactKey)
        return destination.link(chats: chats, names: names, label: label)
            .buttonStyle(.plain)
            .accessibilityLabel(chat.isGroup ? "Chat details for \(title)" : "Profile for \(names.of(contactKey))")
    }
}
