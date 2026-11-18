import Messages
import SwiftUI
import UIKit

/// Yard Link inside the Messages app: the driver picks what to say about the
/// run they are on, and it goes into the thread as a card the other person can
/// read at a glance.
final class MessagesViewController: MSMessagesAppViewController {
    private var hosted: UIHostingController<TripShareView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        present(for: presentationStyle)
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        present(for: presentationStyle)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        hosted?.rootView = view(for: presentationStyle)
    }

    private func present(for style: MSMessagesAppPresentationStyle) {
        let root = view(for: style)
        if let hosted {
            hosted.rootView = root
            return
        }
        let controller = UIHostingController(rootView: root)
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        hosted = controller
    }

    private func view(for style: MSMessagesAppPresentationStyle) -> TripShareView {
        TripShareView(
            snapshot: SharedStore.loadSnapshot(),
            compact: style == .compact,
            onExpand: { [weak self] in self?.requestPresentationStyle(.expanded) },
            onSend: { [weak self] card in self?.insert(card) }
        )
    }

    /// Put the card in the thread, ready for the driver to hit send. Messages
    /// never sends on an app's say-so, which is as it should be.
    private func insert(_ card: TripCard) {
        guard let conversation = activeConversation else { return }
        let layout = MSMessageTemplateLayout()
        layout.image = card.image
        layout.caption = card.caption
        layout.subcaption = card.subcaption
        layout.trailingSubcaption = card.trailing

        let message = MSMessage(session: conversation.selectedMessage?.session ?? MSSession())
        message.layout = layout
        message.summaryText = card.summary
        var address = URLComponents()
        address.queryItems = card.query
        message.url = address.url

        conversation.insert(message) { [weak self] _ in
            self?.requestPresentationStyle(.compact)
        }
    }
}
