import SwiftUI

struct ChatListView: View {
    let settings: Settings

    @State private var chats: [Chat] = []
    @State private var names = Names(me: "", aliases: [:])

    var body: some View {
        List(chats) { chat in
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
                    }
                    if chat.isGroup {
                        Text(names.of(chat.lastSender))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(preview(chat.lastBody))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .overlay {
            if chats.isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .task(id: settings) {
            guard let store = try? Store(ownPublicKey: settings.identity.publicKey) else {
                return
            }
            var version = -1
            while !Task.isCancelled {
                let current = store.dataVersion()
                if current != version {
                    version = current
                    chats = (try? store.chats()) ?? []
                    names = Names(me: store.me, aliases: (try? store.aliases()) ?? [:])
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    private func avatar(_ chat: Chat) -> some View {
        Avatar(key: chat.isTopic ? chat.id : (chat.participants.first ?? settings.identity.publicKey), chat: chat.id, topic: chat.isTopic)
    }
}
