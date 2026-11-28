import SwiftUI
import TesseraeKit

struct DisplayNextInLineCard<Content: View>: View {
    let displayID: String
    @ViewBuilder let content: Content

    var body: some View {
        DisplayDetailCard(title: "Next in Line", systemImage: "clock.arrow.circlepath") {
            content
        }
        .accessibilityIdentifier("display-next-update-\(displayID)")
    }
}

struct DisplayNextUpdateContent: View {
    let name: String
    var reason: String?
    let scheduledAt: Date?
    let effect: DeviceUpcomingEffect
    let certainty: DeviceUpcomingCertainty?
    var progress: (start: Date, end: Date)?

    private var accent: Color { certainty == .scheduled ? TesseraeTheme.info : TesseraeTheme.warning }

    var body: some View {
        if let scheduledAt {
            TimelineView(.animation) { context in
                content(now: context.date, scheduledAt: scheduledAt)
            }
        } else {
            content(now: .now, scheduledAt: nil)
        }
    }

    private func content(now: Date, scheduledAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    if let reason {
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if let scheduledAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        timing(scheduledAt, now: now)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent)
                        Text(scheduledAt, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            if let progress {
                let total = max(progress.end.timeIntervalSince(progress.start), 1)
                ProgressView(value: min(max(now.timeIntervalSince(progress.start), 0), total), total: total)
                    .tint(accent)
                    .accessibilityLabel("Time until next update")
            }

            HStack(spacing: 8) {
                Image(systemName: effect.displaySymbol)
                Text(effect == .changeScreen ? String(localized: "Changes the screen") : String(localized: "Refreshes the current screen"))
                if let certainty, certainty != .scheduled {
                    Text("·")
                    Text(certainty == .estimated ? String(localized: "Estimated") : String(localized: "Conditional"))
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func timing(_ scheduledAt: Date, now: Date) -> some View {
        if scheduledAt <= now.addingTimeInterval(10) {
            Text("Waiting for display…")
        } else {
            Text(scheduledAt, style: .relative)
        }
    }
}

extension DeviceUpcomingEffect {
    var displaySymbol: String {
        switch self {
        case .changeScreen: "arrow.left.arrow.right.square"
        case .refreshScreen: "arrow.clockwise"
        }
    }
}

struct DisplayScreenCarousel<CurrentHeader: View, Current: View, Next: View>: View {
    private enum Page: Hashable { case current, next }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Page = .current
    @State private var hapticEvent = TesseraeHapticEvent()

    let displayID: String
    let currentTitle: String
    let panelAspectRatio: CGFloat
    let hasNext: Bool
    let nextRenderedAt: Date?
    @ViewBuilder let currentHeader: CurrentHeader
    @ViewBuilder let current: Current
    @ViewBuilder let next: Next

    private var visiblePage: Page { hasNext ? selection : .current }

    var body: some View {
        header

        TabView(selection: Binding(get: { visiblePage }, set: { selection = $0 })) {
            current.tag(Page.current)
            if hasNext {
                next.tag(Page.next)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .aspectRatio(panelAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 380)
        .accessibilityIdentifier("display-screen-carousel-\(displayID)")

        if hasNext {
            HStack(spacing: 7) {
                indicator(.current, title: currentTitle)
                indicator(.next, title: String(localized: "Next Screen"))
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("display-screen-page-indicator-\(displayID)")
            .onChange(of: selection) { _, _ in hapticEvent.trigger(.selection) }
            .tesseraeHapticFeedback(trigger: hapticEvent)
        }
    }

    private var header: some View {
        ZStack(alignment: .leading) {
            currentHeader
                .opacity(visiblePage == .current ? 1 : 0)
                .allowsHitTesting(visiblePage == .current)
                .accessibilityHidden(visiblePage != .current)

            HStack(spacing: 10) {
                Label("Next Screen", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(TesseraeTheme.warning)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if let nextRenderedAt {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Rendered").font(.caption2).foregroundStyle(.secondary)
                        Text(nextRenderedAt, style: .relative).font(.caption.weight(.medium))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity)
            .opacity(visiblePage == .next ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(visiblePage != .next)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: visiblePage)
        .onChange(of: hasNext) { _, available in
            if !available { selection = .current }
        }
    }

    private func indicator(_ page: Page, title: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = page }
        } label: {
            Capsule()
                .fill(visiblePage == page ? TesseraeTheme.accent : Color.secondary.opacity(0.28))
                .frame(width: visiblePage == page ? 20 : 7, height: 7)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visiblePage)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(visiblePage == page ? .isSelected : [])
    }
}
