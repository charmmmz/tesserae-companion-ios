import SwiftUI
import TesseraeKit

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.jobs.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Dashboard and photo sends will appear here.")
                )
            } else {
                List(model.jobs) { job in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: job.kind == .imagePush ? "photo" : "rectangle.grid.2x2")
                            .font(.title3)
                            .foregroundStyle(TesseraeTheme.accent)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.label ?? fallbackTitle(job.kind))
                                .font(.headline)
                            Text(model.displayNames(for: job.targetDeviceIDs))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let failure = job.error {
                                Text(failure.message)
                                    .font(.caption)
                                    .foregroundStyle(TesseraeTheme.terracotta)
                            }
                            Text(job.createdAt, format: .dateTime.hour().minute())
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        Label(statusLabel(job), systemImage: statusSymbol(job))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor(job))
                            .labelStyle(.titleAndIcon)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .tesseraeScreenBackground()
    }

    private func fallbackTitle(_ kind: PushJobKind) -> String {
        kind == .imagePush
            ? String(localized: "Photo")
            : String(localized: "Dashboard")
    }

    private func statusLabel(_ job: PushJob) -> String {
        switch job.status {
        case .accepted: String(localized: "Queued")
        case .running: String(localized: "Sending")
        case .succeeded:
            job.result?.status == .quiet
                ? String(localized: "Quiet")
                : String(localized: "Published")
        case .failed: String(localized: "Failed")
        }
    }

    private func statusSymbol(_ job: PushJob) -> String {
        switch job.status {
        case .accepted: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded:
            job.result?.status == .quiet ? "moon.fill" : "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ job: PushJob) -> Color {
        switch job.status {
        case .accepted, .running: TesseraeTheme.ochre
        case .succeeded: job.result?.status == .quiet ? .indigo : TesseraeTheme.accent
        case .failed: TesseraeTheme.terracotta
        }
    }
}
