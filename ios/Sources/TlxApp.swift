import SwiftUI

struct Settings {
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

    var body: some Scene {
        WindowGroup {
            if let settings {
                ChatListView(settings: settings)
            } else {
                SettingsView(settings: $settings)
            }
        }
    }
}
