import Foundation
import UserNotifications

/// Replying to dispatch from the notification itself, without unlocking into
/// the app — the only safe way to answer with a trailer behind you.
enum MessageNotification {
    static var category: UNNotificationCategory {
        let reply = UNTextInputNotificationAction(
            identifier: MessageIntents.Notification.reply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message dispatch"
        )
        let open = UNNotificationAction(
            identifier: MessageIntents.Notification.open,
            title: "Open",
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: MessageIntents.Notification.category,
            actions: [reply, open],
            intentIdentifiers: [],
            options: []
        )
    }

    private struct Outgoing: Encodable {
        let id: String
        let body: String
    }

    /// Send what the driver typed on the lock screen. A reply that cannot be
    /// sent says so on the lock screen rather than disappearing.
    @MainActor
    static func send(_ text: String, toThread threadId: String, senderName: String?) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard let api = AppModel.current?.api else {
            await warn(body)
            return
        }
        do {
            let _: SentMessage = try await api.post(
                "/api/messages/threads/\(threadId)",
                body: Outgoing(id: UUID().uuidString.lowercased(), body: body)
            )
            if let senderName {
                let intent = MessageIntents.incoming(
                    from: senderName,
                    handle: nil,
                    body: body,
                    threadId: threadId
                )
                await MessageIntents.donate(intent, incoming: false)
            }
        } catch {
            await warn(body)
        }
    }

    /// Put the unsent words back in front of the driver.
    private static func warn(_ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Reply not sent"
        content.body = "Open Yard Link to send it: \(body)"
        content.sound = .default
        content.userInfo = ["screen": "messages"]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
