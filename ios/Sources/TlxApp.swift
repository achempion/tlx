import SwiftUI

struct Settings: Equatable {
    var identity: Identity
    var address: RelayAddress

    static func load() -> Settings? {
        guard let identity = Identity.load(), let address = RelayAddress.load() else {
            return nil
        }
        return Settings(identity: identity, address: address)
    }

    func save() throws {
        try identity.save()
        address.save()
    }
}

@main
struct TlxApp: App {
    @State private var settings = Settings.load()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if let settings {
                NavigationStack {
                    ChatListView(settings: settings)
                        .navigationTitle("Chats")
                        .toolbar {
                            NavigationLink("Settings") {
                                SettingsView(settings: $settings)
                            }
                        }
                }
                .id(settings.identity.publicKey)
                .task(id: scenePhase == .active ? settings : nil) {
                    guard scenePhase == .active else {
                        return
                    }
                    await foregroundSync(settings: settings)
                }
            } else {
                SettingsView(settings: $settings)
            }
        }
    }
}
