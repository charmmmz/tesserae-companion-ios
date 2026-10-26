import SwiftUI

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
