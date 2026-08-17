import Foundation
import Observation
import SwiftUI

enum TesseraeTheme {
    static let accent = Color(red: 13 / 255, green: 140 / 255, blue: 126 / 255)
    static let darkAccent = Color(red: 45 / 255, green: 212 / 255, blue: 191 / 255)
    static let accentSoft = Color(red: 230 / 255, green: 243 / 255, blue: 241 / 255)
    static let paper = Color(red: 241 / 255, green: 240 / 255, blue: 236 / 255)
    static let darkPaper = Color(red: 14 / 255, green: 16 / 255, blue: 21 / 255)
    static let ochre = Color(red: 186 / 255, green: 134 / 255, blue: 43 / 255)
    static let terracotta = Color(red: 180 / 255, green: 91 / 255, blue: 65 / 255)

    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkPaper : paper
    }
}

enum TesseraeHaptic: Equatable {
    case selection
    case alignment
    case success
    case warning
    case error
    case lightImpact
    case rigidImpact

    var sensoryFeedback: SensoryFeedback {
        switch self {
        case .selection:
            .selection
        case .alignment:
            .alignment
        case .success:
            .success
        case .warning:
            .warning
        case .error:
            .error
        case .lightImpact:
            .impact(weight: .light, intensity: 0.55)
        case .rigidImpact:
            .impact(flexibility: .rigid, intensity: 0.8)
        }
    }
}

struct TesseraeHapticEvent: Equatable {
    private(set) var revision = 0
    private(set) var feedback: TesseraeHaptic?

    mutating func trigger(_ feedback: TesseraeHaptic) {
        revision &+= 1
        self.feedback = feedback
    }
}

enum TesseraeHapticSettings {
    static let enabledKey = "interaction.haptics.enabled"

    static var isEnabled: Bool {
        get {
            let defaults = sharedDefaults
            guard defaults.object(forKey: enabledKey) != nil else { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            sharedDefaults.set(newValue, forKey: enabledKey)
        }
    }

    private static var sharedDefaults: UserDefaults {
        guard
            let appGroup = Bundle.main.object(
                forInfoDictionaryKey: "TesseraeAppGroupIdentifier"
            ) as? String,
            let defaults = UserDefaults(suiteName: appGroup)
        else {
            return .standard
        }
        return defaults
    }
}

private struct TesseraeHapticFeedbackModifier: ViewModifier {
    let event: TesseraeHapticEvent

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: event) { oldValue, newValue in
            guard
                TesseraeHapticSettings.isEnabled,
                oldValue.revision != newValue.revision
            else {
                return nil
            }
            return newValue.feedback?.sensoryFeedback
        }
    }
}

extension View {
    func tesseraeHapticFeedback(
        trigger event: TesseraeHapticEvent
    ) -> some View {
        modifier(TesseraeHapticFeedbackModifier(event: event))
    }
}

enum TesseraeComposerLayout {
    static let pagePadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let contentCardSpacing: CGFloat = 12
    static let controlCardSpacing: CGFloat = 10
    static let selectionCardSpacing: CGFloat = 8
}

struct ReorderDragPreview<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return Label {
            Text(title)
        } icon: {
            icon()
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            TesseraeTheme.accent.opacity(0.9),
            in: shape
        )
        .clipShape(shape)
        .contentShape(.dragPreview, shape)
    }
}

private struct TesseraeScreenBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private let gridSpacing: CGFloat = 24

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .top) {
                TesseraeTheme.background(for: colorScheme)

                ambientGlow

                Canvas { context, size in
                    let lineWidth = 1 / displayScale
                    let pixelOffset = lineWidth / 2
                    var grid = Path()

                    for x in stride(
                        from: pixelOffset,
                        through: size.width,
                        by: gridSpacing
                    ) {
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    }

                    for y in stride(
                        from: pixelOffset,
                        through: size.height,
                        by: gridSpacing
                    ) {
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }

                    context.stroke(
                        grid,
                        with: .color(gridColor),
                        lineWidth: lineWidth
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var ambientGlow: some View {
        let accent = colorScheme == .dark
            ? TesseraeTheme.darkAccent
            : TesseraeTheme.accent
        let opacity = colorScheme == .dark ? 0.10 : 0.05

        return Rectangle()
            .fill(
                EllipticalGradient(
                    gradient: Gradient(stops: [
                        .init(
                            color: accent.opacity(opacity),
                            location: 0
                        ),
                        .init(
                            color: accent.opacity(0),
                            location: 0.55
                        ),
                        .init(color: .clear, location: 1)
                    ]),
                    center: UnitPoint(x: 0.5, y: -0.2),
                    startRadiusFraction: 0,
                    endRadiusFraction: 1
                )
            )
    }

    private var gridColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.015)
            : Color(red: 16 / 255, green: 12 / 255, blue: 8 / 255)
                .opacity(0.03)
    }
}

private struct TesseraeCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                colorScheme == .dark
                    ? Color(red: 24 / 255, green: 27 / 255, blue: 34 / 255)
                    : .white,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}

extension View {
    func tesseraeCard() -> some View {
        modifier(TesseraeCardModifier())
    }

    func tesseraeScreenBackground() -> some View {
        modifier(TesseraeScreenBackgroundModifier())
    }

    @ViewBuilder
    func tesseraeModalChromeButtonStyle() -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.plain)
        }
#else
        buttonStyle(.plain)
#endif
    }
}

struct TesseraeDisplaySelectionRow: View {
    let name: String
    let resolution: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? TesseraeTheme.accent : .secondary)
            Text(name)
                .foregroundStyle(.primary)
            Spacer()
            Text(resolution)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

struct TesseraeMessageCapsule<Leading: View, Trailing: View>: View {
    let message: String
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 20, height: 20)

            Text(message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            trailing
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }
}

enum TesseraeMessageKind: Equatable {
    case info
    case success
    case progress(fraction: Double?)
    case warning
    case error
}

enum TesseraeMessageLifetime: Equatable {
    case automatic(seconds: Double)
    case persistent
}

enum TesseraeMessagePriority: Int {
    case low = 0
    case normal = 100
    case high = 200
    case critical = 300
}

struct TesseraeMessageAction {
    let title: String
    let perform: @MainActor () -> Void
}

struct TesseraeMessage: Identifiable {
    let id: String
    let text: String
    let kind: TesseraeMessageKind
    let lifetime: TesseraeMessageLifetime
    let priority: TesseraeMessagePriority
    let systemImage: String?
    let accessibilityIdentifier: String?
    let accessibilityText: String?
    let accessibilityHint: String?
    let haptic: TesseraeHaptic?
    let tapAction: (@MainActor () -> Void)?
    let action: TesseraeMessageAction?

    init(
        id: String,
        text: String,
        kind: TesseraeMessageKind = .info,
        lifetime: TesseraeMessageLifetime = .automatic(seconds: 3),
        priority: TesseraeMessagePriority = .normal,
        systemImage: String? = nil,
        accessibilityIdentifier: String? = nil,
        accessibilityText: String? = nil,
        accessibilityHint: String? = nil,
        haptic: TesseraeHaptic? = nil,
        tapAction: (@MainActor () -> Void)? = nil,
        action: TesseraeMessageAction? = nil
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.lifetime = lifetime
        self.priority = priority
        self.systemImage = systemImage
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityText = accessibilityText
        self.accessibilityHint = accessibilityHint
        self.haptic = haptic
        self.tapAction = tapAction
        self.action = action
    }
}

@MainActor
@Observable
final class TesseraeMessageCenter {
    private struct Entry {
        var message: TesseraeMessage
        let sequence: Int
        var revision: Int
    }

    private var entries: [Entry] = []
    private var nextSequence = 0
    private var activeHostIDs: [UUID] = []
    @ObservationIgnored private var dismissalTask: Task<Void, Never>?
    @ObservationIgnored private var dismissalMarker: String?
    @ObservationIgnored private var automaticMessageHostID: UUID?

    var currentMessage: TesseraeMessage? {
        currentEntry?.message
    }

    var queuedCount: Int {
        entries.count
    }

    func post(_ message: TesseraeMessage) {
        if let index = entries.firstIndex(where: {
            $0.message.id == message.id
        }) {
            entries[index].message = message
            entries[index].revision += 1
        } else {
            entries.append(
                Entry(message: message, sequence: nextSequence, revision: 0)
            )
            nextSequence += 1
        }
        scheduleCurrentDismissal()
    }

    func dismiss(id: String) {
        entries.removeAll { $0.message.id == id }
        scheduleCurrentDismissal()
    }

    func dismissAll() {
        entries = []
        scheduleCurrentDismissal()
    }

    func activateHost(id: UUID) {
        let previousHostID = activeHostIDs.last
        activeHostIDs.removeAll { $0 == id }
        activeHostIDs.append(id)

        if let previousHostID,
           previousHostID != id,
           automaticMessageHostID == previousHostID,
           let message = currentMessage,
           case .automatic = message.lifetime
        {
            dismiss(id: message.id)
        } else {
            scheduleCurrentDismissal()
        }
    }

    func deactivateHost(id: UUID) {
        activeHostIDs.removeAll { $0 == id }

        if automaticMessageHostID == id,
           let message = currentMessage,
           case .automatic = message.lifetime
        {
            dismiss(id: message.id)
        } else {
            scheduleCurrentDismissal()
        }
    }

    func isActiveHost(id: UUID) -> Bool {
        activeHostIDs.last == id
    }

    private var orderedEntries: [Entry] {
        entries.sorted { left, right in
            if left.message.priority.rawValue != right.message.priority.rawValue {
                return left.message.priority.rawValue
                    > right.message.priority.rawValue
            }
            return left.sequence < right.sequence
        }
    }

    private var currentEntry: Entry? {
        orderedEntries.first
    }

    private func scheduleCurrentDismissal() {
        guard let entry = currentEntry,
              case let .automatic(seconds) = entry.message.lifetime
        else {
            dismissalTask?.cancel()
            dismissalTask = nil
            dismissalMarker = nil
            automaticMessageHostID = nil
            return
        }

        guard let hostID = activeHostIDs.last else {
            dismissalTask?.cancel()
            dismissalTask = nil
            dismissalMarker = nil
            automaticMessageHostID = nil
            return
        }

        let marker = "\(entry.sequence)|\(entry.revision)|\(hostID.uuidString)"
        guard dismissalMarker != marker else { return }

        dismissalTask?.cancel()
        dismissalMarker = marker
        automaticMessageHostID = hostID
        let message = entry.message

        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self?.currentMessage?.id == message.id
            else { return }
            self?.dismiss(id: message.id)
        }
    }
}

private struct TesseraeMessageCenterHost: View {
    @Environment(TesseraeMessageCenter.self) private var center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hostID = UUID()
    @State private var hapticEvent = TesseraeHapticEvent()

    var body: some View {
        ZStack {
            if center.isActiveHost(id: hostID),
               let message = center.currentMessage
            {
                presentedMessage(message)
                    .id(message.id)
                    .transition(messageTransition)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: center.currentMessage?.id)
        .tesseraeHapticFeedback(trigger: hapticEvent)
        .onAppear {
            center.activateHost(id: hostID)
        }
        .onDisappear {
            center.deactivateHost(id: hostID)
        }
        .onChange(of: presentationRevision) { _, _ in
            guard center.isActiveHost(id: hostID),
                  let haptic = center.currentMessage?.haptic
            else {
                return
            }
            hapticEvent.trigger(haptic)
        }
    }

    private var presentationRevision: String {
        guard let message = center.currentMessage else { return "none" }
        return "\(message.id)|\(message.text)|\(String(describing: message.kind))"
    }

    private var messageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    }

    @ViewBuilder
    private func presentedMessage(_ message: TesseraeMessage) -> some View {
        if let tapAction = message.tapAction {
            Button(action: tapAction) {
                capsule(message, showsDisclosure: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(message.accessibilityText ?? message.text)
            )
            .accessibilityHint(Text(message.accessibilityHint ?? ""))
            .accessibilityIdentifier(message.accessibilityIdentifier ?? message.id)
        } else {
            capsule(message, showsDisclosure: false)
                .accessibilityElement(children: message.action == nil ? .combine : .contain)
                .accessibilityLabel(
                    Text(message.accessibilityText ?? message.text)
                )
                .accessibilityIdentifier(message.accessibilityIdentifier ?? message.id)
        }
    }

    private func capsule(
        _ message: TesseraeMessage,
        showsDisclosure: Bool
    ) -> some View {
        TesseraeMessageCapsule(message: message.text) {
            statusGlyph(for: message)
        } trailing: {
            if let action = message.action {
                Button(action.title, action: action.perform)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(TesseraeTheme.accent)
            } else if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 400)
    }

    @ViewBuilder
    private func statusGlyph(for message: TesseraeMessage) -> some View {
        if let systemImage = message.systemImage {
            Image(systemName: systemImage)
                .foregroundStyle(color(for: message.kind))
        } else {
            switch message.kind {
            case .info:
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(TesseraeTheme.accent)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(TesseraeTheme.accent)
            case let .progress(fraction):
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                } else {
                    ProgressView()
                }
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(TesseraeTheme.ochre)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(TesseraeTheme.terracotta)
            }
        }
    }

    private func color(for kind: TesseraeMessageKind) -> Color {
        switch kind {
        case .info, .success, .progress:
            TesseraeTheme.accent
        case .warning:
            TesseraeTheme.ochre
        case .error:
            TesseraeTheme.terracotta
        }
    }
}

private struct TesseraeMessageCenterOverlayModifier: ViewModifier {
    let topPadding: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            TesseraeMessageCenterHost()
                .padding(.horizontal, 16)
                .safeAreaPadding(.top, topPadding)
        }
    }
}

extension View {
    func tesseraeMessageCenterOverlay(topPadding: CGFloat = 8) -> some View {
        modifier(TesseraeMessageCenterOverlayModifier(topPadding: topPadding))
    }
}


private struct TesseraeScreenBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            TesseraeScreenBackdrop()
                .ignoresSafeArea()
        }
    }
}
