import BackgroundTasks
import SwiftUI
import UserNotifications

let refreshTaskIdentifier = "com.achempion.tlx.refresh"
private let lingerAfterBackgrounding: Duration = .seconds(25)

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
    @State private var engine = Engine()
    @State private var notifier: Notifier
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let notifier = Notifier()
        _notifier = State(initialValue: notifier)
        UNUserNotificationCenter.current().delegate = notifier
    }

    var body: some Scene {
        WindowGroup {
            if let settings {
                NavigationStack {
                    ChatListView(settings: settings, notifier: notifier)
                        .navigationTitle("Chats")
                        .toolbarTitleDisplayMode(.inlineLarge)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink {
                                    SettingsView(settings: $settings)
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                        }
                }
                .id(settings.identity.publicKey)
            } else {
                SettingsView(settings: $settings)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: engine.activate(settings)
            case .background: engine.linger()
            default: break
            }
        }
        .onChange(of: settings) { engine.activate(settings) }
        .backgroundTask(.appRefresh(refreshTaskIdentifier)) {
            if let settings = Settings.load() {
                await notify(about: await backgroundSync(settings: settings), me: settings.identity.publicKey)
            }
            scheduleRefresh()
        }
    }
}

func scheduleRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
    request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
    try? BGTaskScheduler.shared.submit(request)
}

@MainActor
final class Engine {
    private var settings: Settings?
    private var sync: Task<Void, Never>?
    private var lingerTimer: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    func activate(_ settings: Settings?) {
        lingerTimer?.cancel()
        lingerTimer = nil
        endBackgroundTask()
        guard sync == nil || settings != self.settings else { return }
        sync?.cancel()
        self.settings = settings
        sync = settings.map { settings in
            Task {
                await foregroundSync(settings: settings) { await notify(about: $0, me: settings.identity.publicKey) }
            }
        }
    }

    func linger() {
        guard sync != nil else { return }
        scheduleRefresh()
        backgroundTask = UIApplication.shared.beginBackgroundTask { [self] in stop() }
        lingerTimer = Task { [self] in
            try? await Task.sleep(for: lingerAfterBackgrounding)
            if !Task.isCancelled { stop() }
        }
    }

    private func stop() {
        sync?.cancel()
        sync = nil
        lingerTimer = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
