import SwiftUI

struct ChatListView: View {
    let settings: Settings

    @State private var count = 0

    var body: some View {
        VStack(spacing: 12) {
            Text(settings.identity.publicKey).font(.footnote.monospaced())
            Text("\(count) messages synced")
        }
        .padding()
        .task {
            while !Task.isCancelled {
                count = (try? SQLite(path: syncDatabase).query("select count(*) from messages").first?.int(0)) ?? 0
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
