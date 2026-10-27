import SwiftUI
import UIKit

private struct TesseraeWindowMessagesEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var tesseraeWindowMessagesEnabled: Bool {
        get { self[TesseraeWindowMessagesEnabledKey.self] }
        set { self[TesseraeWindowMessagesEnabledKey.self] = newValue }
    }
}

/// A separate, non-key window keeps notifications below the scene's status area
/// even when SwiftUI presents a sheet. Page hosts still own lifetime and haptics.
private struct TesseraeMessageWindowBridge: UIViewRepresentable {
    let center: TesseraeMessageCenter
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(center: center) }

    func makeUIView(context: Context) -> WindowProbe {
        let probe = WindowProbe()
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = false
        probe.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return probe
    }

    func updateUIView(_ uiView: WindowProbe, context: Context) {
        context.coordinator.appearance = colorScheme
        context.coordinator.attach(to: uiView.window)
    }

    static func dismantleUIView(_ uiView: WindowProbe, coordinator: Coordinator) {
        uiView.onWindowChange = nil
        coordinator.close()
    }

    final class WindowProbe: UIView {
        var onWindowChange: (@MainActor (UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        let center: TesseraeMessageCenter
        var appearance: ColorScheme = .light
        private var overlay: MessageWindow?

        init(center: TesseraeMessageCenter) { self.center = center }

        func attach(to source: UIWindow?) {
            guard let source, let scene = source.windowScene else { return }
            if overlay?.windowScene !== scene {
                close()
                let window = MessageWindow(windowScene: scene)
                window.messageCenter = center
                window.backgroundColor = .clear
                window.isOpaque = false
                window.windowLevel = UIWindow.Level(rawValue: source.windowLevel.rawValue + 1)
                let host = UIHostingController(rootView: MessageWindowContent(center: center) {
                    [weak window, weak center] frame in
                    window?.messageFrame = frame
                    center?.windowMessageFrame = frame
                })
                host.view.backgroundColor = .clear
                window.rootViewController = host
                overlay = window
            }
            guard let overlay else { return }
            if overlay.frame != source.frame { overlay.frame = source.frame }
            overlay.overrideUserInterfaceStyle = appearance == .dark ? .dark : .light
            overlay.isHidden = false
        }

        func close() {
            overlay?.isHidden = true
            overlay = nil
            center.windowMessageFrame = .zero
        }
    }
}

private final class MessageWindow: UIWindow {
    weak var messageCenter: TesseraeMessageCenter?
    // Retain geometry across host handoffs; hitTest checks current visibility.
    var messageFrame: CGRect = .zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard messageFrame.contains(point), let center = messageCenter, center.hasActiveHost,
              let message = center.currentMessage,
              message.tapAction != nil || message.action != nil else { return nil }
        return super.hitTest(point, with: event)
    }
}

private struct MessageWindowContent: View {
    let center: TesseraeMessageCenter
    let frameChanged: (CGRect) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if center.hasActiveHost, let message = center.currentMessage {
                TesseraePresentedMessage(message: message, frameChanged: frameChanged)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    func tesseraeWindowMessageOverlay(center: TesseraeMessageCenter) -> some View {
        background(TesseraeMessageWindowBridge(center: center))
            .environment(\.tesseraeWindowMessagesEnabled, true)
    }
}
