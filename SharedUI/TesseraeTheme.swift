import Foundation
import Observation
import SwiftUI
import UIKit

enum TesseraeTheme {
    // Paper palette from Tesserae 0.448.0. These dynamic colours also work in
    // the Share Extension, which does not bundle the main app's asset catalog.
    // Keep AccentColor.colorset in sync for system surfaces that read it.
    // Foreground tint needs contrast on paper and soft selection surfaces.
    static let accent = adaptive(light: 0xB03227, dark: 0xE98476)
    // Solid actions keep white labels legible in both appearances.
    static let accentFill = adaptive(light: 0xB8352A, dark: 0xC13C30)
    static let accentOnPaper = Color(red: 176 / 255, green: 50 / 255, blue: 39 / 255)
    static let accentSoft = adaptive(light: 0xF3DCD6, dark: 0x3B211D)
    static let background = adaptive(light: 0xEEEAE1, dark: 0x151412)
    static let surface = adaptive(light: 0xFFFDF8, dark: 0x22211E)
    static let surfaceInset = adaptive(light: 0xF1ECE1, dark: 0x1E1D1B)

    // Status is independent of branding, even where the light red matches.
    // Selection and actions use accent; a completed operation uses success.
    static let success = adaptive(light: 0x3D7A3A, dark: 0x8DBF7F)
    static let warning = adaptive(light: 0x805808, dark: 0xD9B45A)
    static let danger = adaptive(light: 0xB8352A, dark: 0xE58474)
    static let info = adaptive(light: 0x2B4E9B, dark: 0x7C9BE0)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct TesseraeBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme
    let size: CGFloat

    var body: some View {
        Image("TesseraeLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .overlay {
                if colorScheme == .dark {
                    // The mark stays ink/red/paper in both appearances. Only
                    // its edge changes, using the upstream tile's 72/256 radius.
                    RoundedRectangle(cornerRadius: size * 72 / 256)
                        .strokeBorder(
                            Color(red: 237 / 255, green: 233 / 255, blue: 223 / 255)
                                .opacity(0.3),
                            lineWidth: 1
                        )
                }
            }
            .accessibilityHidden(true)
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
            TesseraeTheme.accentFill,
            in: shape
        )
        .clipShape(shape)
        .contentShape(.dragPreview, shape)
    }
}

private struct TesseraeScreenBackdrop: View {
    var body: some View {
        TesseraeTheme.background
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TesseraeCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                TesseraeTheme.surface,
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let name: String
    let resolution: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24))
                .foregroundStyle(isSelected ? TesseraeTheme.accent : .secondary)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout())
            layout {
                Text(name)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Text(resolution)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(resolution)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    let topPadding: CGFloat
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
                    .padding(.top, topPadding)
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
                    .foregroundStyle(TesseraeTheme.info)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(TesseraeTheme.success)
            case let .progress(fraction):
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .tint(TesseraeTheme.info)
                } else {
                    ProgressView()
                        .tint(TesseraeTheme.info)
                }
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(TesseraeTheme.warning)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(TesseraeTheme.danger)
            }
        }
    }

    private func color(for kind: TesseraeMessageKind) -> Color {
        switch kind {
        case .info, .progress:
            TesseraeTheme.info
        case .success:
            TesseraeTheme.success
        case .warning:
            TesseraeTheme.warning
        case .error:
            TesseraeTheme.danger
        }
    }
}

private struct TesseraeMessageCenterInsetModifier: ViewModifier {
    let topPadding: CGFloat

    func body(content: Content) -> some View {
        // Reserve actual layout space outside navigation containers. A safe-area
        // inset alone can still overlap their toolbar on compact presentations.
        VStack(spacing: 0) {
            TesseraeMessageCenterHost(topPadding: topPadding)
                .padding(.horizontal, 16)
            content
        }
        .tesseraeScreenBackground()
    }
}

extension View {
    func tesseraeMessageCenterInset(topPadding: CGFloat = 8) -> some View {
        modifier(TesseraeMessageCenterInsetModifier(topPadding: topPadding))
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

// Segmented controls keep a fixed height; menus let accessibility text wrap.
private struct TesseraeAdaptivePickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}

extension View {
    func tesseraeAdaptivePickerStyle() -> some View {
        modifier(TesseraeAdaptivePickerStyle())
    }
}
