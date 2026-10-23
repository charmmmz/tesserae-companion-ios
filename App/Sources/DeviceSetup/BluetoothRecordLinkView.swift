import SwiftUI

/// IDs from older firmware can differ between BLE and the server. Only the user
/// establishes that association; names and MAC suffixes are never identity proofs.
struct BluetoothRecordLinkView: View {
    @Environment(AppModel.self) private var model
    @Environment(NearbyDeviceManager.self) private var nearby
    @State private var forgettingRecord = false
    let displayID: String

    var body: some View {
        if let serverID = model.activeInstance?.id, !nearby.displayRecords.records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Bluetooth Device", selection: Binding(
                    get: { nearby.displayRecords.record(for: displayID, serverID: serverID)?.id ?? "" },
                    set: { nearby.displayRecords.link($0.isEmpty ? nil : $0, to: displayID, serverID: serverID) }
                )) {
                    Text("Not linked").tag("")
                    ForEach(nearby.displayRecords.records) { record in
                        Text("\(record.name) · \(record.id)").tag(record.id)
                    }
                }
                .accessibilityIdentifier("bluetooth-record-link-\(displayID)")
                Text("Link only if this is the same physical display. Records are saved on this iPhone or iPad.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let record = nearby.displayRecords.record(for: displayID, serverID: serverID) {
                    Button("Forget Bluetooth Record", role: .destructive) { forgettingRecord = true }
                        .confirmationDialog("Forget Bluetooth Record?", isPresented: $forgettingRecord) {
                            Button("Forget Bluetooth Record", role: .destructive) {
                                nearby.displayRecords.remove(deviceID: record.id)
                            }
                        } message: {
                            Text("This removes the saved mode, voltage, and photo preview from this device.")
                        }
                }
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
