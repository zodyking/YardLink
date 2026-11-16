import MessageUI
import SwiftUI
import UIKit

/// The phone's own Messages sheet, opened with the message already written.
///
/// Yard Link never sends a text by itself: iOS hands the driver the standard
/// compose screen, they choose who it goes to and tap Send, and it leaves
/// from their own number. The app is told only whether it was sent.
struct MessageComposer: UIViewControllerRepresentable {
    /// Phone numbers to fill in. Empty lets the driver pick from Contacts.
    var recipients: [String] = []
    let body: String
    /// Photos to attach, already fetched from the server.
    var attachments: [(data: Data, fileName: String)] = []
    var onFinish: (Bool) -> Void = { _ in }

    /// False on a device with no SMS (and in the simulator), where the
    /// buttons that open this are hidden.
    static var isAvailable: Bool { MFMessageComposeViewController.canSendText() }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = context.coordinator
        composer.recipients = recipients.isEmpty ? nil : recipients
        composer.body = body
        if MFMessageComposeViewController.canSendAttachments() {
            for attachment in attachments {
                composer.addAttachmentData(attachment.data, typeIdentifier: "public.jpeg", filename: attachment.fileName)
            }
        }
        return composer
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            onFinish(result == .sent)
        }
    }
}
