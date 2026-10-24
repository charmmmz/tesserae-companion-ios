import SwiftUI

/// One-time fallback for an unassociated display without a complete, unique MAC.
struct BluetoothRecordLinkView: View {
    @Environment(AppModel.self) private var model
    @Environment(NearbyDeviceManager.self) private var nearby
    let displayID: String

    var body: some View {
        if let serverID = model.activeInstance?.id,
           !nearby.displayRecords.manualLinkCandidates(for: displayID, serverID: serverID).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Bluetooth Device", selection: Binding(
                    get: { nearby.displayRecords.record(for: displayID, serverID: serverID)?.id ?? "" },
                    set: { nearby.displayRecords.link($0.isEmpty ? nil : $0, to: displayID, serverID: serverID) }
                )) {
                    Text("Not linked").tag("")
                    ForEach(nearby.displayRecords.manualLinkCandidates(for: displayID, serverID: serverID)) { record in
                        Text("\(record.name) · \(record.id)").tag(record.id)
                    }
                }
                .accessibilityIdentifier("bluetooth-record-link-\(displayID)")
                if let error = nearby.displayRecords.storageError {
                    Text(error).font(.footnote).foregroundStyle(TesseraeTheme.warning)
                }
            }
        }
    }
}

struct BluetoothModeLabel: View {
    var compact = false
    var body: some View {
        Label {
            Text(compact ? String(localized: "Bluetooth") : String(localized: "Bluetooth Mode"))
        } icon: {
            PhosphorIcon(name: "bluetooth", size: 13, color: .secondary)
        }
    }
}
