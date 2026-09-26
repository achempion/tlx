import SwiftUI

struct ChatDetailsView: View {
    let chat: Chat
    let chats: [Chat]
    let names: Names

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Avatar(key: chat.id, topic: true, size: 88)
                        .accessibilityHidden(true)
                    Text(names.chat(chat, among: chats))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }
            Section("Participants") {
                ForEach(chat.participants + [names.me], id: \.self) { publicKey in
                    NavigationLink {
                        ProfileView(publicKey: publicKey, names: names)
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(key: publicKey, chat: chat.id)
                                .accessibilityHidden(true)
                            Text(names.of(publicKey))
                        }
                    }
                }
            }
        }
        .navigationTitle("Chat details")
        .navigationBarTitleDisplayMode(.inline)
    }
}
