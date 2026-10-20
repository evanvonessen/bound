import GameController
import SwiftUI
import UIKit

/// Hosts controller-driven reference content beneath a scoped controller event
/// controller so UIKit does not interpret stick/button input as focus movement.
struct BoundControllerInputHost<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        BoundControllerInputHostController(rootView: content)
    }
}

struct BoundControllerInputHostController<Content: View>: UIViewControllerRepresentable {
    let rootView: Content

    func makeUIViewController(context: Context) -> GCEventViewController {
        let eventController = GCEventViewController()
        eventController.controllerUserInteractionEnabled = false
        eventController.view.backgroundColor = .clear

        let hostingController = UIHostingController(rootView: hostedRootView(in: context))
        hostingController.safeAreaRegions = []
        hostingController.view.backgroundColor = .clear
        context.coordinator.hostingController = hostingController

        eventController.addChild(hostingController)
        eventController.view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: eventController.view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: eventController.view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: eventController.view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: eventController.view.bottomAnchor),
        ])
        hostingController.didMove(toParent: eventController)
        return eventController
    }

    func updateUIViewController(_ eventController: GCEventViewController, context: Context) {
        eventController.controllerUserInteractionEnabled = false
        context.coordinator.hostingController?.rootView = hostedRootView(in: context)
        context.coordinator.hostingController?.safeAreaRegions = []
        context.coordinator.hostingController?.view.backgroundColor = .clear
    }

    private func hostedRootView(in context: Context) -> AnyView {
        AnyView(rootView.environment(\.self, context.environment))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var hostingController: UIHostingController<AnyView>?
    }
}
