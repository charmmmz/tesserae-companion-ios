import SwiftUI
import TesseraeKit

struct DisplaysView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.displays) { display in
                    DisplayCard(
                        display: display,
                        preview: model.displayPreviews[display.id]
                    )
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
                Text(display.name)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                DisplayHardwareBadge(
                    presentation: display.hardwarePresentation
                )

                Label(freshnessLabel, systemImage: freshnessSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(freshnessColor)

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

                Label(display.panel.orientation.capitalized, systemImage: "rotate.right")
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
                placeholderSystemName: previewSymbol,
                placeholderLabel: "Display preview placeholder, \(display.panel.width) by \(display.panel.height), \(display.panel.orientation)",
                imageLabel: "Latest device-specific preview for \(display.name)",
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

    private var previewSymbol: String {
        display.panel.height > display.panel.width
            ? "rectangle.portrait.inset.filled"
            : "rectangle.inset.filled"
    }

    private var freshnessLabel: String {
        switch display.freshness {
        case .fresh: String(localized: "Recently seen")
        case .stale: String(localized: "Last seen earlier")
        case .unknown: String(localized: "Unknown")
        }
    }

    private var freshnessSymbol: String {
        switch display.freshness {
        case .fresh: "checkmark.circle.fill"
        case .stale: "clock.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var freshnessColor: Color {
        switch display.freshness {
        case .fresh: TesseraeTheme.accent
        case .stale: TesseraeTheme.ochre
        case .unknown: .secondary
        }
    }
}
