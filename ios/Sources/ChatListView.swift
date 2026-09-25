import SwiftUI

struct ChatListView: View {
    let settings: Settings

    @State private var status = "Waiting for messages…"

    var body: some View {
        VStack(spacing: 12) {
            Text(settings.identity.publicKey).font(.footnote.monospaced())
            Text(status)
        }
        .padding()
        .task {
            do {
                let blobs = try await Relay(address: settings.address, identity: settings.identity).get(after: 0)
                status = "\(blobs.count) messages waiting"
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
