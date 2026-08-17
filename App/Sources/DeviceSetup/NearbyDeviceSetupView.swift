import SwiftUI

struct NearbyDeviceSetupView: View {
    private enum Screen: Equatable {
        case introduction
        case authentication
        case connecting
        case wifi
        case maintenance
        case maintenanceAction
        case complete
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(NearbyDeviceManager.self) private var nearby
    @Environment(SetupNetworkStore.self) private var setupNetworks

    let device: NearbyTesseraeDevice

    @State private var screen: Screen = .introduction
    @State private var scannerPresented = false
    @State private var selectedSSID = ""
    @State private var customSSID = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var savePassword = false
    @State private var localError: String?
    @State private var pendingDestructiveAction: DestructiveAction?
    @State private var selectedDetent: PresentationDetent = .height(420)

    private enum DestructiveAction: String, Identifiable {
        case clearWiFi
        case factoryReset
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch screen {
                case .introduction: introduction
                case .authentication: authentication
                case .connecting: connecting
                case .wifi: wifiSetup
                case .maintenance: maintenance
                case .maintenanceAction: maintenanceAction
                case .complete: completion
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        nearby.dismissSuggestion(for: device)
                        nearby.disconnect()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(420), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(isSubmitting)
        .fullScreenCover(isPresented: $scannerPresented) {
            NavigationStack {
                DeviceSetupQRScanner { value in
                    do {
                        let code = try nearby.parseQRCode(value)
                        scannerPresented = false
                        screen = .connecting
                        nearby.connect(to: device, qrCode: code)
                    } catch {
                        localError = error.localizedDescription
                    }
                } onError: { message in
                    scannerPresented = false
                    localError = message
                }
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { scannerPresented = false }
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .alert("Unable to Continue", isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button("OK", role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "")
        }
        .confirmationDialog(
            destructiveDialogTitle,
            isPresented: Binding(
                get: { pendingDestructiveAction != nil },
                set: { if !$0 { pendingDestructiveAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch pendingDestructiveAction {
            case .clearWiFi:
                Button("Clear Wi-Fi Settings", role: .destructive) {
                    nearby.clearWiFi()
                }
            case .factoryReset:
                Button("Factory Reset Display", role: .destructive) {
                    nearby.factoryReset()
                }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingDestructiveAction == .clearWiFi
                 ? "The display will forget its Wi-Fi network and restart in setup mode. Its server configuration remains available."
                 : "This erases Wi-Fi, server, and display configuration. The display will restart as a new device.")
        }
        .onChange(of: nearby.connectionState) { _, state in
            switch state {
            case .ready:
                screen = device.mode == .maintenance ? .maintenance : .wifi
            case .configured:
                isSubmitting = false
                rememberConfiguredNetwork()
            case .performingMaintenanceAction:
                isSubmitting = true
                screen = .maintenanceAction
            case .restarting:
                isSubmitting = false
                screen = .maintenanceAction
            case .failed(let message):
                isSubmitting = false
                screen = .authentication
                localError = message
            default:
                break
            }
        }
        .onChange(of: screen) { _, newScreen in
            withAnimation(.snappy) {
                selectedDetent = newScreen == .introduction ? .height(420) : .large
            }
        }
    }

    private var introduction: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: device.mode == .setup
                  ? "display.badge.checkmark"
                  : "wrench.and.screwdriver")
                .font(.system(size: 58, weight: .medium))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text(device.mode == .setup
                     ? "New Tesserae Display Found"
                     : "Tesserae Maintenance Mode")
                    .font(.title2.bold())
                Text(device.name)
                    .font(.headline)
                Text(device.mode == .setup
                     ? "Set up Wi-Fi and connect this display to your Tesserae system."
                     : "View diagnostics, repair Wi-Fi, or reset this nearby display.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.activeInstance == nil {
                Label(
                    device.mode == .setup
                        ? "Connect this app to your Tesserae Server first, then return to set up the display."
                        : "Diagnostics and reset actions are available now. Connect this app to your Tesserae Server before changing Wi-Fi.",
                    systemImage: "server.rack"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if !model.supportsDeviceSetup && device.mode == .setup {
                Label(
                    "Your Tesserae Server needs an update before it can register displays from the app.",
                    systemImage: "arrow.down.app"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Button("Continue") { screen = .authentication }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    device.mode == .setup
                        && (model.activeInstance == nil || !model.supportsDeviceSetup)
                )
            Button("Not Now") {
                nearby.dismissSuggestion(for: device)
                dismiss()
            }
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .tesseraeScreenBackground()
    }

    private var authentication: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Verify This Display")
                    .font(.title2.bold())
                Text("Scan the code shown on the display. It is valid only for this maintenance session and is never saved.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button("Scan Setup Code", systemImage: "camera") {
                scannerPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Use 6-Digit Code Instead") {
                screen = .connecting
                nearby.connect(to: device, qrCode: nil)
            }
            .buttonStyle(.bordered)
            Text("iOS will ask for the code displayed on the Tesserae screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .tesseraeScreenBackground()
    }

    private var connecting: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text(nearby.statusMessage ?? "Connecting securely…")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Keep your iPhone close to the display.")
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tesseraeScreenBackground()
    }

    private var wifiSetup: some View {
        Form {
            Section {
                if nearby.networks.isEmpty {
                    HStack {
                        ProgressView()
                        Text(nearby.statusMessage ?? "Scanning…")
                            .foregroundStyle(.secondary)
                    }
                    Button("Scan Again") { nearby.scanWiFi() }
                } else {
                    ForEach(nearby.networks) { network in
                        Button {
                            selectedSSID = network.ssid
                            customSSID = ""
                            loadSavedPassword(for: network.ssid)
                        } label: {
                            HStack {
                                Image(systemName: wifiSymbol(for: network.rssi))
                                Text(network.ssid)
                                Spacer()
                                if network.isSecure {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if selectedSSID == network.ssid {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                TextField("Other network name", text: $customSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Wi-Fi Network")
            }

            Section("Password") {
                SecureField("Wi-Fi password", text: $password)
                    .textContentType(.password)
                Toggle("Save password on this iPhone", isOn: $savePassword)
            }

            if let instance = model.activeInstance {
                Section("Tesserae System") {
                    LabeledContent("Server", value: instance.name)
                    Text(instance.baseURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(isSubmitting ? "Testing Connection…" : "Connect Display") {
                    submitConfiguration()
                }
                .disabled(chosenSSID.isEmpty || isSubmitting)
            } footer: {
                Text("The display tests Wi-Fi and the server before replacing any saved settings.")
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
    }

    private var maintenance: some View {
        Form {
            if let diagnostics = nearby.diagnostics {
                Section("Display") {
                    LabeledContent("Model", value: diagnostics.model)
                    LabeledContent("Firmware", value: diagnostics.firmware)
                    LabeledContent(
                        "Battery",
                        value: diagnostics.batteryMillivolts > 0
                            ? String(format: "%.2f V", Double(diagnostics.batteryMillivolts) / 1000)
                            : "—"
                    )
                }
                Section("Current Network") {
                    LabeledContent("Wi-Fi", value: diagnostics.ssid ?? "Not configured")
                    LabeledContent("IP Address", value: diagnostics.ipAddress ?? "—")
                    LabeledContent(
                        "Signal",
                        value: diagnostics.rssi == 0 ? "—" : "\(diagnostics.rssi) dBm"
                    )
                    LabeledContent(
                        "Server",
                        value: diagnostics.isServerConfigured ? "Configured" : "Not configured"
                    )
                }
                if !diagnostics.logs.isEmpty {
                    Section("Recent Maintenance Events") {
                        ForEach(Array(diagnostics.logs.enumerated()), id: \.offset) { _, log in
                            Text(log).font(.caption.monospaced())
                        }
                    }
                }
            } else {
                Section {
                    HStack { ProgressView(); Text("Reading diagnostics…") }
                    Button("Try Again") { nearby.requestDiagnostics() }
                }
            }

            Section("Actions") {
                Button("Repair or Change Wi-Fi", systemImage: "wifi") {
                    screen = .wifi
                    nearby.scanWiFi()
                }
                Button("Restart Display", systemImage: "arrow.clockwise") {
                    nearby.reboot()
                }
                Button("Clear Wi-Fi Settings", systemImage: "wifi.slash", role: .destructive) {
                    pendingDestructiveAction = .clearWiFi
                }
                Button("Factory Reset", systemImage: "trash", role: .destructive) {
                    pendingDestructiveAction = .factoryReset
                }
            }

            if let status = nearby.statusMessage {
                Section { Text(status).foregroundStyle(.secondary) }
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
    }

    private var completion: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 68))
                .foregroundStyle(.green)
            Text("Display Connected")
                .font(.title2.bold())
            Text("The display verified Wi-Fi and your Tesserae Server, saved the new settings, and is restarting.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Done") {
                nearby.dismissSuggestion(for: device)
                nearby.disconnect()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
        .tesseraeScreenBackground()
    }

    private var maintenanceAction: some View {
        VStack(spacing: 20) {
            Spacer()
            if nearby.connectionState == .restarting {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 68))
                    .foregroundStyle(.green)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(nearby.connectionState == .restarting
                 ? "Command Received"
                 : "Updating Display")
                .font(.title2.bold())
            Text(nearby.statusMessage ?? "Sending command to the display…")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if nearby.connectionState == .restarting {
                Text("The Bluetooth maintenance connection closes while the display restarts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if nearby.connectionState == .restarting {
                Button("Close") {
                    nearby.dismissSuggestion(for: device)
                    nearby.disconnect()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(28)
        .tesseraeScreenBackground()
    }

    private var navigationTitle: String {
        switch screen {
        case .introduction: "Nearby Display"
        case .authentication: "Verify"
        case .connecting: "Connecting"
        case .wifi: "Wi-Fi Setup"
        case .maintenance: "Display Maintenance"
        case .maintenanceAction: "Display Maintenance"
        case .complete: "Setup Complete"
        }
    }

    private var chosenSSID: String {
        customSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? selectedSSID
            : customSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var destructiveDialogTitle: String {
        switch pendingDestructiveAction {
        case .clearWiFi: "Clear this display's Wi-Fi settings?"
        case .factoryReset: "Factory reset this display?"
        case nil: "Confirm action"
        }
    }

    private func submitConfiguration() {
        guard let instance = model.activeInstance else {
            localError = NearbyDeviceSetupError.noServer.localizedDescription
            return
        }
        isSubmitting = true
        Task {
            do {
                let pairingCode: String
                if model.supportsDeviceSetup {
                    let pairing = try await model.createFirmwareDevicePairing()
                    pairingCode = pairing.code
                } else if device.mode == .maintenance {
                    // An existing display can repair Wi-Fi without replacing
                    // its server identity when it remains on the same server.
                    pairingCode = ""
                } else {
                    throw NearbyDeviceSetupError.serverUpdateRequired
                }
                nearby.applyConfiguration(
                    ssid: chosenSSID,
                    password: password,
                    serverURL: instance.baseURL,
                    pairingCode: pairingCode
                )
            } catch {
                isSubmitting = false
                localError = error.localizedDescription
            }
        }
    }

    private func loadSavedPassword(for ssid: String) {
        guard let instanceID = model.activeInstance?.id else { return }
        Task {
            if let saved = try? await setupNetworks.savedPassword(
                instanceID: instanceID,
                ssid: ssid
            ) {
                password = saved
                savePassword = true
            } else {
                password = ""
                savePassword = false
            }
        }
    }

    private func rememberConfiguredNetwork() {
        guard let instanceID = model.activeInstance?.id else {
            password = ""
            screen = .complete
            return
        }
        let configuredSSID = chosenSSID
        let configuredPassword = password
        let shouldSavePassword = savePassword
        Task {
            try? await setupNetworks.record(
                instanceID: instanceID,
                ssid: configuredSSID,
                password: configuredPassword,
                savePassword: shouldSavePassword
            )
            password = ""
            screen = .complete
        }
    }

    private func wifiSymbol(for rssi: Int) -> String {
        if rssi >= -55 { return "wifi" }
        if rssi >= -70 { return "wifi" }
        return "wifi.exclamationmark"
    }
}

struct NearbyDisplaysView: View {
    @Environment(NearbyDeviceManager.self) private var nearby
    @Environment(AppModel.self) private var model
    @Environment(SetupNetworkStore.self) private var setupNetworks
    @State private var selectedDevice: NearbyTesseraeDevice?

    var body: some View {
        List {
            if !setupNetworks.networks.isEmpty {
                Section("Networks Configured from This iPhone") {
                    ForEach(setupNetworks.networks) { network in
                        LabeledContent {
                            if network.hasSavedPassword {
                                Label("Password saved", systemImage: "key.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            Label(network.ssid, systemImage: "wifi")
                        }
                        .swipeActions {
                            Button("Forget", role: .destructive) {
                                guard let instanceID = model.activeInstance?.id else { return }
                                Task {
                                    try? await setupNetworks.remove(
                                        instanceID: instanceID,
                                        ssid: network.ssid
                                    )
                                }
                            }
                        }
                    }
                }
            }
            Section {
                if nearby.nearbyDevices.isEmpty {
                    ContentUnavailableView(
                        "No Displays Nearby",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("New displays advertise automatically. For an existing display, hold Refresh for 3 seconds to enter Maintenance Mode.")
                    )
                } else {
                    ForEach(nearby.nearbyDevices) { device in
                        Button {
                            selectedDevice = device
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: device.mode == .setup
                                      ? "display"
                                      : "wrench.and.screwdriver")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.mode == .setup ? "Ready to set up" : "Maintenance mode")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Bluetooth is used only for local setup and maintenance. Normal Tesserae communication continues over Wi-Fi.")
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .navigationTitle("Nearby Displays")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            nearby.startScanning()
            if let instanceID = model.activeInstance?.id {
                setupNetworks.load(instanceID: instanceID)
            }
        }
        .sheet(item: $selectedDevice) { device in
            NearbyDeviceSetupView(device: device)
        }
    }
}
