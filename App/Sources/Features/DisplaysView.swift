import SwiftUI
import TesseraeKit

struct DisplaysView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.displays) { display in
                    NavigationLink {
                        DisplayDetailView(display: display)
                    } label: {
                        DisplayCard(
                            display: display,
                            preview: model.displayPreviews[display.id]
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("display-card-\(display.id)")
                    .task(id: model.previewGeneration) {
                        await model.loadDisplayPreview(display)
                    }
                }
            }
            .padding(16)
        }
        .overlay {
            if model.isRefreshing && model.displays.isEmpty {
                ProgressView("Loading displays…")
            } else if model.displays.isEmpty {
                ContentUnavailableView {
                    Label("No Displays", systemImage: "rectangle.slash")
                } description: {
                    Text("No displays were returned by this Tesserae server.")
                } actions: {
                    Button("Refresh") {
                        Task { await model.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .refreshable {
            await model.refresh()
        }
        .tesseraeScreenBackground()
    }
}

private struct DisplayCard: View {
    let display: DisplaySummary
    let preview: PreviewImageState?
    private let previewCanvasSize = CGSize(width: 112, height: 118)

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: display.freshnessSymbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(display.freshnessColor)
                        .accessibilityLabel(display.freshnessLabel)

                    Text(display.name)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .layoutPriority(1)
                }

                DisplayHardwareBadge(
                    presentation: display.hardwarePresentation
                )

                if display.hasPendingRender == true {
                    pendingBadge
                }

                HStack(spacing: 12) {
                    metric(
                        "battery.75percent",
                        display.batteryPercent.map { "\($0)%" } ?? "—"
                    )
                    metric(
                        "wifi",
                        display.rssiDBM.map { "\($0) dBm" } ?? "—"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            panelPreview
        }
        .tesseraeCard()
    }

    private var panelPreview: some View {
        let previewSize = display.panel.fittedPreviewSize(
            maxWidth: previewCanvasSize.width,
            maxHeight: previewCanvasSize.height
        )

        return ZStack {
            Color.clear

            PreviewArtwork(
                state: preview,
                placeholderSystemName: display.previewSymbol,
                placeholderLabel: "Display preview placeholder, \(display.panel.width) by \(display.panel.height), \(display.panel.orientation)",
                imageLabel: "Last-served device preview for \(display.name)",
                accessibilityIdentifier: "display-preview-\(display.id)",
                placeholderDetail: "\(display.panel.width) × \(display.panel.height)"
            )
            .frame(
                width: CGFloat(previewSize.width),
                height: CGFloat(previewSize.height)
            )
        }
        .frame(
            width: previewCanvasSize.width,
            height: previewCanvasSize.height
        )
    }

    private func metric(_ symbol: String, _ value: String) -> some View {
        Label(value, systemImage: symbol)
            .labelStyle(.titleAndIcon)
    }

    private var pendingBadge: some View {
        Label("Update pending", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(TesseraeTheme.ochre)
            .accessibilityHint(
                "A newer frame is waiting for this display to wake and fetch it."
            )
    }

}

private struct DisplayDetailView: View {
    @Environment(AppModel.self) private var model
    let display: DisplaySummary

    private var currentDisplay: DisplaySummary {
        model.displays.first(where: { $0.id == display.id }) ?? display
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                currentScreenCard

                detailCard(
                    "Connection & Power",
                    systemImage: "antenna.radiowaves.left.and.right"
                ) {
                    detailRow("Status") {
                        Label(
                            currentDisplay.freshnessLabel,
                            systemImage: currentDisplay.freshnessSymbol
                        )
                        .foregroundStyle(currentDisplay.freshnessColor)
                    }

                    detailRow("Last Seen") {
                        if let lastSeenAt = currentDisplay.lastSeenAt {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(lastSeenAt, style: .relative)
                                Text(
                                    lastSeenAt,
                                    format: .dateTime
                                        .year()
                                        .month()
                                        .day()
                                        .hour()
                                        .minute()
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Not reported")
                        }
                    }

                    detailRow("Battery") {
                        Text(
                            currentDisplay.batteryPercent.map { "\($0)%" }
                                ?? String(localized: "Not reported")
                        )
                    }

                    detailRow("Signal") {
                        Text(
                            currentDisplay.rssiDBM.map { "\($0) dBm" }
                                ?? String(localized: "Not reported")
                        )
                    }
                }

                detailCard("Hardware", systemImage: "cpu") {
                    detailRow("Manufacturer") {
                        Text(
                            currentDisplay.hardwarePresentation.brand?.displayName
                                ?? String(localized: "Not reported")
                        )
                    }

                    detailRow("Model") {
                        Text(
                            currentDisplay.hardwarePresentation.modelName
                                ?? String(localized: "Not reported")
                        )
                    }

                    detailRow("Firmware") {
                        Text(
                            currentDisplay.firmwareVersion
                                ?? String(localized: "Not reported")
                        )
                    }

                    detailRow("Device Type") {
                        Text(currentDisplay.kind)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    detailRow("Device ID") {
                        Text(currentDisplay.id)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                detailCard("Panel", systemImage: "rectangle.inset.filled") {
                    detailRow("Resolution") {
                        Text(
                            "\(currentDisplay.panel.width) × \(currentDisplay.panel.height)"
                        )
                        .monospacedDigit()
                    }

                    detailRow("Orientation") {
                        Text(currentDisplay.orientationLabel)
                    }

                    detailRow("Colour Gamut") {
                        Text(currentDisplay.gamutLabel)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(currentDisplay.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await model.refresh()
        }
        .task(id: model.previewGeneration) {
            await model.loadDisplayPreview(currentDisplay)
        }
        .tesseraeScreenBackground()
    }

    private var currentScreenCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("Current Screen", systemImage: "display")
                    .font(.headline)

                Spacer(minLength: 8)

                if currentDisplay.hasPendingRender == true {
                    Label(
                        "Update pending",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TesseraeTheme.ochre)
                    .accessibilityHint(
                        "A newer frame is waiting for this display to wake and fetch it."
                    )
                }
            }

            PreviewArtwork(
                state: model.displayPreviews[currentDisplay.id],
                placeholderSystemName: currentDisplay.previewSymbol,
                placeholderLabel: "Display preview placeholder, \(currentDisplay.panel.width) by \(currentDisplay.panel.height), \(currentDisplay.panel.orientation)",
                imageLabel: "Last-served device preview for \(currentDisplay.name)",
                accessibilityIdentifier: "display-detail-preview-\(currentDisplay.id)",
                placeholderDetail: "\(currentDisplay.panel.width) × \(currentDisplay.panel.height)"
            )
            .aspectRatio(currentDisplay.panelAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 380)
        }
        .tesseraeCard()
    }

    private func detailCard<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            content()
        }
        .tesseraeCard()
    }

    private func detailRow<Value: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            value()
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
    }
}

private extension DisplaySummary {
    var freshnessLabel: String {
        switch freshness {
        case .fresh: String(localized: "Recently seen")
        case .stale: String(localized: "Last seen earlier")
        case .unknown: String(localized: "Unknown")
        }
    }

    var freshnessSymbol: String {
        switch freshness {
        case .fresh: "checkmark.circle.fill"
        case .stale: "clock.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var freshnessColor: Color {
        switch freshness {
        case .fresh: TesseraeTheme.accent
        case .stale: TesseraeTheme.ochre
        case .unknown: .secondary
        }
    }

    var previewSymbol: String {
        panel.height > panel.width
            ? "rectangle.portrait.inset.filled"
            : "rectangle.inset.filled"
    }

    var panelAspectRatio: CGFloat {
        guard panel.height > 0 else { return 1 }
        return CGFloat(panel.width) / CGFloat(panel.height)
    }

    var orientationLabel: String {
        switch panel.orientation.lowercased() {
        case "portrait":
            String(localized: "Portrait")
        case "landscape":
            String(localized: "Landscape")
        default:
            panel.orientation.localizedCapitalized
        }
    }

    var gamutLabel: String {
        panel.gamut
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized
    }
}
