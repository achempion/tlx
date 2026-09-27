import SwiftUI

struct ChatListRow: View {
    let chat: Chat
    let chats: [Chat]
    let names: Names
    let isSelected: Bool

    private var metadataColor: Color {
        #if targetEnvironment(macCatalyst)
        isSelected ? Color.primary.opacity(0.7) : .secondary
        #else
        .secondary
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(chat: chat, me: names.me)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(names.chat(chat, among: chats))
                        .fontWeight(chat.unread > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer()
                    Text(when(chat.lastClaimedAt))
                        .font(.caption)
                        .foregroundStyle(metadataColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(chat.pending?.error != nil && chat.draft.isEmpty ? Color.red : metadataColor)
                        .lineLimit(1)
                    Spacer()
                    if chat.unread > 0 {
                        Text("\(chat.unread)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var previewText: String {
        if !chat.draft.isEmpty { return "Draft: " + chat.draft }
        if chat.isDraft { return "Draft" }
        if let pending = chat.pending {
            let status = pending.error != nil ? "Failed to send" : (pending.sent ? "Sent" : "Sending…")
            return status + " · " + preview(pending.body)
        }
        let body = preview(chat.lastBody)
        return chat.isGroup && !chat.lastSender.isEmpty ? names.of(chat.lastSender) + ": " + body : body
    }
}
