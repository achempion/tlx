import SwiftUI

struct SettingsView: View {
    @Binding var settings: Settings?

    var body: some View {
        Text("settings")
    }
}

struct ChatListView: View {
    let settings: Settings

    var body: some View {
        Text(settings.identity.publicKey)
    }
}
