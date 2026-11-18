import Intents
import UIKit

/// Yard Link's people, as iOS knows them.
///
/// A dispatch message donated as a message from a person arrives the way a
/// text does: with a face on the notification, a place in the share sheet,
/// and a Focus the driver can let through while everything else stays quiet.
enum MessageIntents {
    /// The identifiers the push payload and the phone agree on.
    enum Notification {
        static let category = "YARDLINK_MESSAGE"
        static let reply = "YARDLINK_REPLY"
        static let open = "YARDLINK_OPEN_THREAD"
    }

    /// A round badge of the person's initials, since Yard Link keeps no photos.
    static func avatar(for name: String) -> INImage? {
        let initials = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        let side = CGFloat(120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor(red: 0, green: 125 / 255, blue: 224 / 255, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
            let text = initials.isEmpty ? "?" : initials
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: side * 0.42, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2),
                withAttributes: attributes
            )
        }
        guard let data = drawn.pngData() else { return nil }
        return INImage(imageData: data)
    }

    /// The person a message came from or is going to. The handle is their
    /// Yard Link user id, which is stable and never shown.
    static func person(named name: String, handle: String?) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: handle ?? name, type: .unknown),
            nameComponents: nil,
            displayName: name,
            image: avatar(for: name),
            contactIdentifier: nil,
            customIdentifier: handle,
            isMe: false,
            suggestionType: .instantMessageAddress
        )
    }

    /// A message that has just come in, ready to dress the notification with.
    static func incoming(
        from senderName: String,
        handle: String?,
        body: String?,
        threadId: String?
    ) -> INSendMessageIntent {
        let sender = person(named: senderName, handle: handle)
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: nil,
            conversationIdentifier: threadId,
            serviceName: "Yard Link",
            sender: sender,
            attachments: nil
        )
        intent.setImage(avatar(for: senderName), forParameterNamed: \.sender)
        return intent
    }

    /// Tell iOS about a message, so the person becomes someone it knows.
    @discardableResult
    static func donate(_ intent: INSendMessageIntent, incoming: Bool) async -> Bool {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = incoming ? .incoming : .outgoing
        if let threadId = intent.conversationIdentifier { interaction.groupIdentifier = threadId }
        do {
            try await interaction.donate()
            return true
        } catch {
            return false
        }
    }
}
