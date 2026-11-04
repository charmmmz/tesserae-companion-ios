import SwiftUI
import TesseraeKit

struct CloudEntryOutcomeView: View {
    let completion: CloudEntryCompletion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch completion {
                case .finished(let batch):
                    Text(batch.kind == .photo ? "Photo Send" : "Current Page Refresh").font(.title2.bold())
                    Text("A generated frame does not confirm that the physical display has updated.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(batch.targets) { target in
                        let outcome = batch.results.first { $0.id == target.id }?.outcome
                        VStack(alignment: .leading, spacing: 6) {
                            Text(target.name).font(.headline)
                            Text(status(outcome)).font(.body)
                            if let message = message(outcome) { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tesseraeCard()
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("share-cloud-result-\(target.id)")
                    }
                    if let expiry = batch.mediaExpiresAt {
                        LabeledContent("Photo Available Until", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Results Available Until", value: batch.resultsExpireAt.formatted(date: .abbreviated, time: .shortened))
                    Text("Check uncertain displays before explicitly sending again in Tesserae Companion.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .retained(let input, let reason):
                    Label("Not Sent", systemImage: "tray.and.arrow.down").font(.title2.bold())
                    Text("This item has been kept. Open Tesserae Companion to review it and choose Continue.")
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Photo Available Until", value: input.expiresAt.formatted(date: .abbreviated, time: .shortened))
                case .inProgress:
                    Label("Send in Progress", systemImage: "clock").font(.title2.bold())
                    Text("Another system action is preparing or sending this item. View its result in Tesserae Companion. It will not be sent again automatically.")
                case .notConfirmed(_, let reason):
                    Label("Result Not Confirmed", systemImage: "exclamationmark.triangle").font(.title2.bold())
                    Text("Open Tesserae Companion to check this decision. It will not be sent again automatically.")
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("share-cloud-outcome")
    }

    private func status(_ outcome: CloudTargetOutcome?) -> String {
        switch outcome {
        case .generated(_, let warnings): String(localized: warnings.isEmpty ? "Frame Generated" : "Generated with Warnings")
        case .refused: String(localized: "Not Sent")
        case .unknown: String(localized: "Unknown")
        case .notAttempted, nil: String(localized: "Not Attempted")
        }
    }
    private func message(_ outcome: CloudTargetOutcome?) -> String? {
        switch outcome {
        case .generated(_, let warnings): warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        case .refused(_, let message, _), .unknown(_, let message): message
        default: nil
        }
    }
}
