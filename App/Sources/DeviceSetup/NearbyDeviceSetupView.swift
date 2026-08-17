import SwiftUI
import TesseraeKit

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
    @State private var recentEventsExpanded = false
    @State private var selectedDetent: PresentationDetent = .height(360)

    private enum DestructiveAction: String, Identifiable {
        case clearWiFi
        case factoryReset
        var id: String { rawValue }
    }

    private var hardwarePresentation: DisplayHardwarePresentation {
        DisplayHardwarePresentation(
            kind: nearby.deviceInfo?.model ?? device.hardware.catalogKind
        )
    }

    private var manufacturerName: String {
        hardwarePresentation.brand?.displayName ?? String(localized: "Not reported")
    }

    private var modelName: String {
        hardwarePresentation.modelName
            ?? nearby.deviceInfo?.model
            ?? nearby.diagnostics?.model
            ?? String(localized: "Not reported")
    }

    @ViewBuilder
    private var displayIdentityRows: some View {
        LabeledContent("Manufacturer", value: manufacturerName)
        LabeledContent("Model", value: modelName)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tesseraeScreenBackground()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsToolbarCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            closeSheet()
                        } label: {
                            Label("Close", systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(isSubmitting)
                    }
                }
            }
        }
        .presentationDetents(
            [.height(360), .height(480), .large],
            selection: $selectedDetent
        )
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
                 ? "Forgets Wi-Fi and restarts. Tesserae server settings stay saved."
                 : "Erases Wi-Fi, server, and display settings, then restarts as a new display.")
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
                selectedDetent = preferredDetent(for: newScreen)
            }
        }
        .task(id: model.activeInstance?.id) {
            if let instanceID = model.activeInstance?.id {
                setupNetworks.load(instanceID: instanceID)
            }
        }
    }

    private var introduction: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            TesseraeEInkDisplayArtwork(isMaintenance: device.mode == .maintenance)
            VStack(spacing: 5) {
                Text(device.mode == .setup
                     ? "Ready to Set Up"
                     : "Maintenance Mode")
                    .font(.title2.bold())
                DisplayHardwareBadge(presentation: hardwarePresentation)
            }
            Spacer(minLength: 0)
            if model.activeInstance == nil {
                Label(
                    device.mode == .setup
                        ? "Connect this app to a Tesserae Server first."
                        : "Connect to a Tesserae Server to change Wi-Fi.",
                    systemImage: "server.rack"
                )
                .font(.footnote)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            } else if !model.supportsDeviceSetup && device.mode == .setup {
                Label(
                    "Update your Tesserae Server to continue.",
                    systemImage: "arrow.down.app"
                )
                .font(.footnote)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            }
            Button("Continue") { screen = .authentication }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    device.mode == .setup
                        && (model.activeInstance == nil || !model.supportsDeviceSetup)
                )
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var authentication: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("Scan the temporary code shown on the display.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Scan Code", systemImage: "camera") {
                scannerPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Enter 6-Digit Code") {
                screen = .connecting
                nearby.connect(to: device, qrCode: nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(28)
    }

    private var connecting: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text(nearby.statusMessage ?? "Connecting securely…")
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep your iPhone close.")
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wifiSetup: some View {
        let knownSSIDs = Set(setupNetworks.networks.map(\.ssid))
        let otherNetworks = nearby.networks.filter { !knownSSIDs.contains($0.ssid) }

        return Form {
            Section("Display") {
                displayIdentityRows
            }

            if !setupNetworks.networks.isEmpty {
                Section {
                    ForEach(setupNetworks.networks) { knownNetwork in
                        Button {
                            selectNetwork(knownNetwork.ssid)
                        } label: {
                            HStack {
                                if let scanned = nearby.networks.first(where: {
                                    $0.ssid == knownNetwork.ssid
                                }) {
                                    Image(systemName: wifiSymbol(for: scanned.rssi))
                                } else {
                                    Image(systemName: "wifi")
                                        .foregroundStyle(.secondary)
                                }
                                Text(knownNetwork.ssid)
                                Spacer()
                                if knownNetwork.hasSavedPassword {
                                    Image(systemName: "key.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if selectedSSID == knownNetwork.ssid {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Known Networks")
                } footer: {
                    Text("Saved by Tesserae on this iPhone.")
                }
            }

            Section {
                if otherNetworks.isEmpty {
                    HStack {
                        ProgressView()
                        Text(nearby.statusMessage ?? "Scanning…")
                            .foregroundStyle(.secondary)
                    }
                    Button("Scan Again") { nearby.scanWiFi() }
                } else {
                    ForEach(otherNetworks) { network in
                        Button {
                            selectNetwork(network.ssid)
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
                    .onChange(of: customSSID) { _, newValue in
                        guard !newValue.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty else { return }
                        selectedSSID = ""
                        password = ""
                        savePassword = false
                    }
            } header: {
                Text(setupNetworks.networks.isEmpty ? "Wi-Fi Networks" : "Other Networks")
            }

            if requiresWiFiPassword {
                Section("Password") {
                    SecureField("Wi-Fi password", text: $password)
                        .textContentType(.password)
                    Toggle("Save on this iPhone", isOn: $savePassword)
                }
            }

            Section {
                Button(isSubmitting ? "Testing Connection…" : "Connect Display") {
                    submitConfiguration()
                }
                .disabled(chosenSSID.isEmpty || isSubmitting)
            } footer: {
                Text("Saved only after Wi-Fi and server checks pass.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var maintenance: some View {
        Form {
            if let diagnostics = nearby.diagnostics {
                Section("Display") {
                    displayIdentityRows
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
                    if !diagnostics.isServerConfigured {
                        LabeledContent("Server", value: "Not configured")
                    }
                }
                if !diagnostics.logs.isEmpty {
                    Section {
                        DisclosureGroup(
                            "Recent Events",
                            isExpanded: $recentEventsExpanded
                        ) {
                            ForEach(
                                Array(diagnostics.logs.enumerated()),
                                id: \.offset
                            ) { _, log in
                                Text(log).font(.caption.monospaced())
                            }
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
            }

            Section("Reset") {
                Button(role: .destructive) {
                    pendingDestructiveAction = .clearWiFi
                } label: {
                    Label("Clear Wi-Fi Settings", systemImage: "wifi.slash")
                        .foregroundStyle(.red)
                }
                Button(role: .destructive) {
                    pendingDestructiveAction = .factoryReset
                } label: {
                    Label("Factory Reset", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }

            if let status = nearby.statusMessage {
                Section { Text(status).foregroundStyle(.secondary) }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var completion: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 68))
                .foregroundStyle(.green)
            Text("Display Connected")
                .font(.title2.bold())
            Text("Wi-Fi and Tesserae are connected. The display is restarting.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
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
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            if nearby.connectionState == .restarting {
                Spacer()
                Button("Done") {
                    closeSheet()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Spacer()
            }
        }
        .padding(28)
    }

    private var navigationTitle: String {
        switch screen {
        case .introduction: "Nearby Display"
        case .authentication: "Verify Display"
        case .connecting: "Connecting"
        case .wifi: "Choose Wi-Fi"
        case .maintenance: "Maintenance"
        case .maintenanceAction: "Maintenance"
        case .complete: "Complete"
        }
    }

    private var showsToolbarCloseButton: Bool {
        screen != .maintenanceAction && screen != .complete
    }

    private var chosenSSID: String {
        customSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? selectedSSID
            : customSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var requiresWiFiPassword: Bool {
        guard !chosenSSID.isEmpty else { return false }
        guard customSSID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else { return true }
        return nearby.networks.first(where: { $0.ssid == selectedSSID })?
            .isSecure ?? true
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
                let serverURL: URL?
                if device.mode == .maintenance {
                    // Maintenance changes Wi-Fi only. Keep the display's exact
                    // saved server URL and token, including any custom port.
                    pairingCode = ""
                    serverURL = nil
                } else if model.supportsDeviceSetup {
                    let pairing = try await model.createFirmwareDevicePairing()
                    pairingCode = pairing.code
                    serverURL = instance.baseURL
                } else {
                    throw NearbyDeviceSetupError.serverUpdateRequired
                }
                nearby.applyConfiguration(
                    ssid: chosenSSID,
                    password: password,
                    serverURL: serverURL,
                    pairingCode: pairingCode
                )
            } catch {
                isSubmitting = false
                localError = error.localizedDescription
            }
        }
    }

    private func preferredDetent(for screen: Screen) -> PresentationDetent {
        switch screen {
        case .authentication:
            .height(480)
        case .wifi, .maintenance:
            .large
        case .introduction, .connecting, .maintenanceAction, .complete:
            .height(360)
        }
    }

    private func closeSheet() {
        nearby.dismissSuggestion(for: device)
        nearby.disconnect()
        dismiss()
    }

    private func selectNetwork(_ ssid: String) {
        selectedSSID = ssid
        customSSID = ""
        loadSavedPassword(for: ssid)
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

private struct TesseraeEInkDisplayArtwork: View {
    let isMaintenance: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.78))
                    .shadow(color: .black.opacity(0.14), radius: 7, y: 4)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(red: 0.94, green: 0.93, blue: 0.88))
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                VStack(spacing: 4) {
                    Image("TesseraeLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                    Text("TESSERAE")
                        .font(.system(size: 6, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(.black.opacity(0.68))
                }
                .padding(.bottom, 22)
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(.white.opacity(0.72))
                            .frame(width: 3.5, height: 3.5)
                    }
                }
                .padding(.bottom, 5)
            }
            .frame(width: 72, height: 88)

            Image(systemName: isMaintenance ? "wrench.fill" : "sparkles")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(7)
                .background(Circle().fill(.tint))
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                .offset(x: 7, y: 5)
        }
        .frame(width: 94, height: 94)
        .accessibilityHidden(true)
    }
}

struct NearbyDisplaysView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(NearbyDeviceManager.self) private var nearby
    @Environment(AppModel.self) private var model
    @Environment(SetupNetworkStore.self) private var setupNetworks
    @State private var selectedDevice: NearbyTesseraeDevice?

    var body: some View {
        List {
            if !setupNetworks.networks.isEmpty {
                Section {
                    ForEach(setupNetworks.networks) { network in
                        HStack(spacing: 12) {
                            Image(systemName: "wifi")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(nearbyAccent)
                                .frame(width: 34, height: 34)
                                .background(
                                    nearbyAccent.opacity(0.12),
                                    in: RoundedRectangle(
                                        cornerRadius: 9,
                                        style: .continuous
                                    )
                                )

                            Text(network.ssid)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .fixedSize(horizontal: false, vertical: true)
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
                } header: {
                    Text("Known Networks")
                } footer: {
                    Text("Saved by Tesserae on this iPhone.")
                }
            }
            Section {
                if nearby.nearbyDevices.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(nearbyAccent)
                            .frame(width: 34, height: 34)
                            .background(
                                nearbyAccent.opacity(0.12),
                                in: RoundedRectangle(
                                    cornerRadius: 9,
                                    style: .continuous
                                )
                            )
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("No displays found")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Text("For maintenance, hold Refresh for 3 seconds.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(nearby.nearbyDevices) { device in
                        Button {
                            selectedDevice = device
                        } label: {
                            let presentation = DisplayHardwarePresentation(
                                kind: device.hardware.catalogKind
                            )

                            HStack(spacing: 13) {
                                Image(
                                    systemName: device.mode == .setup
                                        ? "display.badge.checkmark"
                                        : "wrench.and.screwdriver"
                                )
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(nearbyAccent)
                                .frame(width: 44, height: 44)
                                .background(
                                    nearbyAccent.opacity(0.12),
                                    in: RoundedRectangle(
                                        cornerRadius: 12,
                                        style: .continuous
                                    )
                                )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text(hardwareSummary(presentation))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    Label(
                                        device.mode == .setup
                                            ? "Ready to set up"
                                            : "Maintenance mode",
                                        systemImage: device.mode == .setup
                                            ? "sparkles"
                                            : "wrench.fill"
                                    )
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(nearbyAccent)
                                    .lineLimit(1)
                                }

                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Displays Nearby")
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
        .sheet(item: Binding(
            get: { selectedDevice },
            set: { newDevice in
                if newDevice == nil, let selectedDevice {
                    nearby.endSession(for: selectedDevice)
                }
                selectedDevice = newDevice
            }
        )) { device in
            NearbyDeviceSetupView(device: device)
        }
    }

    private func hardwareSummary(_ presentation: DisplayHardwarePresentation) -> String {
        let components = [presentation.brand?.displayName, presentation.modelName]
            .compactMap { $0 }
        return components.isEmpty
            ? String(localized: "Tesserae Display")
            : components.joined(separator: " · ")
    }

    private var nearbyAccent: Color {
        colorScheme == .dark ? TesseraeTheme.darkAccent : TesseraeTheme.accent
    }
}
