import SwiftUI
import TesseraeKit

struct DisplaysView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                instanceHeader

                ForEach(model.displays) { display in
                    DisplayCard(display: display)
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

    private var instanceHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(TesseraeTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeInstance?.name ?? "Tesserae")
                    .font(.headline)
                Text(connectionDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(.green)
                .frame(width: 9, height: 9)
                .accessibilityLabel("Connected")
        }
        .tesseraeCard()
    }

    private var connectionDescription: String {
        model.connectionMode == .live
            ? String(localized: "Connected through Companion API")
            : String(localized: "Connected locally · Demo data")
    }
}

private struct DisplayCard: View {
    let display: DisplaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(display.name)
                        .font(.title3.bold())
                    Text(display.kind)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(freshnessLabel, systemImage: freshnessSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(freshnessColor)
            }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TesseraeTheme.accentSoft.gradient)
                .frame(height: 112)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.inset.filled")
                            .font(.title)
                        Text("\(display.panel.width) × \(display.panel.height)")
                            .font(.caption.monospaced())
                    }
                    .foregroundStyle(TesseraeTheme.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Display preview placeholder, \(display.panel.width) by \(display.panel.height)")

            HStack {
                metric("battery.75percent", display.batteryPercent.map { "\($0)%" } ?? "—")
                Spacer()
                metric("wifi", display.rssiDBM.map { "\($0) dBm" } ?? "—")
                Spacer()
                metric("rotate.right", display.panel.orientation.capitalized)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .tesseraeCard()
    }

    private func metric(_ symbol: String, _ value: String) -> some View {
        Label(value, systemImage: symbol)
            .labelStyle(.titleAndIcon)
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
