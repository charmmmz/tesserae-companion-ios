import SwiftUI

struct ActivityCard<Header: View, Details: View>: View {
    var spacing: CGFloat = 12
    var hasShadow = false
    @ViewBuilder let header: Header
    @ViewBuilder let details: Details

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) {
            header
            details
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
        .clipShape(shape)
        .shadow(color: hasShadow ? .black.opacity(0.05) : .clear, radius: 9, y: 4)
        .contentShape(shape)
    }
}

enum ActivityCardMetrics {
    static let previewSize = CGSize(width: 112, height: 118)
}

struct ActivityCardRow<Summary: View, Artwork: View>: View {
    @ViewBuilder let summary: Summary
    @ViewBuilder let artwork: Artwork

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) { summary }
                .frame(maxWidth: .infinity, alignment: .leading)
            artwork
        }
    }
}

struct ActivityDisclosureButton<Label: View>: View {
    let isExpanded: Bool
    let expandHint: LocalizedStringKey
    let collapseHint: LocalizedStringKey
    let onToggle: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { onToggle() }
        } label: {
            label.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityHint(Text(isExpanded ? collapseHint : expandHint))
    }
}

struct ActivityFilterMenu: View {
    @Binding var filter: ActivityFilter

    var body: some View {
        Menu {
            Picker("Activity Filter", selection: $filter) {
                Text("All").tag(ActivityFilter.all)
                    .accessibilityIdentifier("activity-filter-all")
                Text("Needs Attention").tag(ActivityFilter.needsAttention)
                    .accessibilityIdentifier("activity-filter-needs-attention")
            }
        } label: {
            Label("Filter Activity", systemImage: filter == .all
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityValue(filter.label)
        .accessibilityIdentifier("activity-filter")
    }
}

struct ActivityStatusBadge: View {
    let label: String
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(.thinMaterial, in: Circle())
            .accessibilityLabel(Text(label))
            .allowsHitTesting(false)
    }
}

struct ActivityExpandedPhoto: View {
    let image: UIImage
    var maximumHeight: CGFloat = 420

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        FittedPreviewLayout(aspectRatio: image.size.width / image.size.height, maximumHeight: maximumHeight) {
            Image(uiImage: image).resizable().scaledToFit()
        }
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.055), in: shape)
        .clipShape(shape)
    }
}
