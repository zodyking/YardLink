import Intents
import UserNotifications

/// Dresses an incoming dispatch message as a message from a person before iOS
/// shows it: the sender's face on the notification, their name on the banner,
/// and a conversation the driver can let through a Focus.
///
/// Anything that is not a message, or any step that will not work, falls back
/// to the notice exactly as the server sent it. A driver never loses a notice
/// because this could not dress it up.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var plain: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        handler = contentHandler
        let content = request.content
        plain = content

        guard content.categoryIdentifier == MessageIntents.Notification.category else {
            contentHandler(content)
            return
        }

        let info = content.userInfo
        let senderName = (info["senderName"] as? String)?.trimmingCharacters(in: .whitespaces)
        let intent = MessageIntents.incoming(
            from: senderName?.isEmpty == false ? senderName! : content.title,
            handle: info["senderUserId"] as? String,
            body: content.body,
            threadId: info["threadId"] as? String
        )

        Task {
            await MessageIntents.donate(intent, incoming: true)
            contentHandler((try? content.updating(from: intent)) ?? content)
            self.handler = nil
        }
    }

    /// Apple is out of patience: show the plain notice rather than nothing.
    override func serviceExtensionTimeWillExpire() {
        if let handler, let plain { handler(plain) }
        handler = nil
    }
}
