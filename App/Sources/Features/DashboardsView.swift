import SwiftUI
import TesseraeKit

struct DashboardsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.sortedDashboards) { dashboard in
                    dashboardCard(dashboard)
                }
            }
            .padding(16)
        }
        .refreshable {
            await model.refresh()
        }
        .tesseraeScreenBackground()
    }

    private func dashboardCard(_ dashboard: DashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dashboard.name)
                        .font(.title3.bold())
                    Text("\(dashboard.kind.rawValue.capitalized) · \(model.displayNames(for: dashboard.deviceIDs))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.toggleFavorite(dashboard.id)
                } label: {
                    Image(
                        systemName: model.favoriteDashboardIDs.contains(dashboard.id)
                            ? "star.fill"
                            : "star"
                    )
                    .foregroundStyle(
                        model.favoriteDashboardIDs.contains(dashboard.id)
                            ? TesseraeTheme.ochre
                            : .secondary
                    )
                }
                .accessibilityLabel(
                    model.favoriteDashboardIDs.contains(dashboard.id)
                        ? "Remove from favourites"
                        : "Add to favourites"
                )
            }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [TesseraeTheme.accentSoft, TesseraeTheme.paper],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 132)
                .overlay {
                    Image(systemName: dashboard.kind == .canvas ? "scribble.variable" : "square.grid.2x2")
                        .font(.system(size: 38))
                        .foregroundStyle(TesseraeTheme.accent)
                }
                .accessibilityLabel("Dashboard preview placeholder")

            Button {
                Task { await model.push(dashboard) }
            } label: {
                HStack {
                    if model.activeOperationIDs.contains(dashboard.id) {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text("Send Now")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                dashboard.deviceIDs.isEmpty
                    || model.activeOperationIDs.contains(dashboard.id)
            )
        }
        .tesseraeCard()
    }
}

