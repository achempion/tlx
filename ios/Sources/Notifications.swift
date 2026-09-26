import OSLog
import UIKit
import UserNotifications

private let log = Logger(subsystem: "com.achempion.tlx", category: "notifications")
private let notificationsEnabledKey = "notifications_enabled"

var notificationsEnabled: Bool {
    UserDefaults.standard.bool(forKey: notificationsEnabledKey)
}

@discardableResult
func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
    let granted = enabled ? await authorizationGranted() : false
    UserDefaults.standard.set(granted, forKey: notificationsEnabledKey)
    log.info("notifications \(enabled ? "requested" : "turned off"), granted: \(granted)")
    return granted
}

private func authorizationGranted() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
}

func notificationsDenied() async -> Bool {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
}

func notify(about saved: [Message], me: String) async {
    guard !saved.isEmpty, notificationsEnabled,
          await MainActor.run(body: { UIApplication.shared.applicationState == .background }),
          let store = try? Store(ownPublicKey: me), let requests = try? announcements(for: saved, store: store) else {
        return
    }
    log.info("announcing \(requests.count) of \(saved.count) new messages")
    for request in requests {
        try? await UNUserNotificationCenter.current().add(request)
    }
}

func announcements(for saved: [Message], store: Store) throws -> [UNNotificationRequest] {
    let fromOthersOutsideTopics = saved.filter { $0.senderPublicKey != store.me && chatTag($0.chatId).isEmpty }
    guard !fromOthersOutsideTopics.isEmpty else { return [] }
    let chats = try store.chats()
    let names = Names(me: store.me, aliases: try store.aliases())
    return fromOthersOutsideTopics.compactMap { message in
        guard let chat = chats.first(where: { $0.id == message.chatId }) else { return nil }
        let content = UNMutableNotificationContent()
        content.title = names.chat(chat, among: chats)
        if chat.isGroup {
            content.subtitle = names.of(message.senderPublicKey)
        }
        content.body = String(preview(message.body).prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
        content.sound = .default
        content.threadIdentifier = chat.id
        return UNNotificationRequest(identifier: "m\(message.sequence)", content: content, trigger: nil)
    }
}
