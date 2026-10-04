import SwiftUI
import UIKit

@MainActor
@Observable
final class LineupEditingSession {
    enum ExitDestination {
        case back
        case close
    }

    var hasChanges = false
    var isSaving = false
    var pendingExit: ExitDestination?

    func canExit(to destination: ExitDestination) -> Bool {
        guard !isSaving else { return false }
        guard hasChanges else { return true }
        pendingExit = destination
        return false
    }
}

struct LineupExitProtection: ViewModifier {
    @Bindable var session: LineupEditingSession
    let onExit: (LineupEditingSession.ExitDestination) -> Void

    func body(content: Content) -> some View {
        content
            .background {
                LineupSheetDismissalObserver(
                    isDisabled: session.hasChanges || session.isSaving
                ) {
                    if session.canExit(to: .close) {
                        onExit(.close)
                    }
                }
                .frame(width: 0, height: 0)
            }
            .alert(
                "Discard Changes?",
                item: $session.pendingExit
            ) { destination in
                Button("Discard Changes", role: .destructive) {
                    session.hasChanges = false
                    onExit(destination)
                }
                Button("Keep Editing", role: .cancel) {}
            } message: { _ in
                Text("Your changes haven’t been saved.")
            }
    }
}

// iOS 18–26 has no SwiftUI callback for an attempted interactive dismissal.
// Observe the enclosing sheet so a nested picker cannot bypass draft protection.
private struct LineupSheetDismissalObserver: UIViewControllerRepresentable {
    let isDisabled: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isDisabled = isDisabled
        controller.onAttempt = onAttempt
        controller.install()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var isDisabled = false
        var onAttempt: () -> Void = {}
        private weak var observed: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?
        private var previousModalInPresentation = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            install()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        func install() {
            var ancestor = parent
            while let controller = ancestor {
                if controller.presentingViewController != nil,
                   let presentation = controller.presentationController {
                    if observed !== presentation {
                        restore()
                        observed = presentation
                        previousModalInPresentation = controller.isModalInPresentation
                    }
                    if presentation.delegate !== self {
                        previousDelegate = presentation.delegate
                        presentation.delegate = self
                    }
                    controller.isModalInPresentation = isDisabled
                    return
                }
                ancestor = controller.parent
            }
        }

        func restore() {
            if let observed, observed.delegate === self {
                observed.delegate = previousDelegate
                observed.presentedViewController.isModalInPresentation = previousModalInPresentation
            }
            observed = nil
            previousDelegate = nil
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !isDisabled && (previousDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if isDisabled {
                onAttempt()
            } else {
                previousDelegate?.presentationControllerDidAttemptToDismiss?(presentationController)
            }
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerWillDismiss?(presentationController)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerDidDismiss?(presentationController)
        }
    }
}
