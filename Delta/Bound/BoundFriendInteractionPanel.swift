import UIKit

/// A child overlay leaves VBA-M running (and presence fresh) while suppressing
/// gameplay inputs. Presenting a full-screen controller would pause the core.
@MainActor
final class BoundFriendInteractionPanel: UIView {
    private let card = UIStackView()
    private weak var session: BoundFriendInteractionSession?
    var name: (() -> String)?
    var willOpen: (() -> Void)?
    private var wasOpen = false
    init(session: BoundFriendInteractionSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessibilityViewIsModal = true
        accessibilityIdentifier = "bound.friend-interaction"
        card.axis = .vertical; card.spacing = 14
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = .init(top: 22, leading: 22, bottom: 22, trailing: 22)
        let scroll = UIScrollView()
        addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(card); card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor).withPriority(.defaultLow),
            card.centerXAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerYAnchor),
            card.topAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            card.bottomAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            card.widthAnchor.constraint(equalToConstant: 340).withPriority(.defaultHigh),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12)
        ])
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(session:)") }
    func render() {
        guard let session else { isHidden = true; return }
        let open = session.blocksGameplay
        if open && !wasOpen { willOpen?() }
        wasOpen = open; isHidden = !open
        guard open else { return }
        superview?.bringSubviewToFront(self)
        card.arrangedSubviews.forEach { card.removeArrangedSubview($0); $0.removeFromSuperview() }
        label(name?() ?? "Friend", style: .headline, id: "title")
        switch session.phase {
        case .idle, .playing: break
        case .choosing:
            label("Send an invitation", style: .title2, id: "status")
            label("Friendly battles use your current party. Your game is restored afterward. Trades are invitations only.", style: .footnote, id: "availability")
            for activity in BoundFriendInteractionPacket.Activity.allCases {
                button(activity.title, id: activity.rawValue) { [weak session] in session?.request(activity) }
            }
            button("Cancel", id: "cancel") { [weak session] in session?.cancel() }
        case .incoming:
            label(session.message, style: .title2, id: "status")
            label("Friendly battles use your current party. Your game is restored afterward. Trades are invitations only.", style: .footnote, id: "availability")
            button("Accept invitation", id: "accept") { [weak session] in session?.accept() }
            button("Decline", id: "decline") { [weak session] in session?.decline() }
        case .outgoing, .confirming, .connecting:
            label(session.message, style: .title2, id: "status")
            button("Cancel", id: "cancel") { [weak session] in session?.cancel() }
        case .agreed:
            label(session.message, style: .title2, id: "status")
            label("Trading Pokémon is not available yet.", style: .footnote, id: "availability")
            button("Return to game", id: "close") { [weak session] in session?.cancel() }
        case .ended:
            label(session.message, style: .title2, id: "status")
            button("Return to game", id: "close") { [weak session] in session?.cancel() }
        }
        UIAccessibility.post(notification: .screenChanged, argument: card.arrangedSubviews.first)
    }
    private func label(_ text: String, style: UIFont.TextStyle, id: String) {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "bound.friend-interaction.\(id)"
        card.addArrangedSubview(label)
    }
    private func button(_ title: String, id: String, action: @escaping () -> Void) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title; configuration.cornerStyle = .medium
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = "bound.friend-interaction.\(id)"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        card.addArrangedSubview(button)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint { self.priority = priority; return self }
}
