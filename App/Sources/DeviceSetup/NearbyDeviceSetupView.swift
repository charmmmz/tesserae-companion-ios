import SwiftUI
import TesseraeKit

struct NearbyDeviceSetupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Screen: Equatable {
        case introduction
        case authentication
        case connecting
        case server
        case wifi
        case maintenance
        case maintenanceAction
        case complete
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @State private var clearWiFiConfirmationPresented = false
    @State private var factoryResetConfirmationPresented = false
    @State private var recentEventsExpanded = false
    @State private var selectedDetent: PresentationDetent = .height(360)
    @State private var changingServer = false
    @State private var useConnectedServer = true
    @State private var serverAddress = ""
    @State private var serverPairingCode = ""

    private var isPicPakMaintenance: Bool {
        nearby.resolvedHardware == .picPak42 && device.mode == .maintenance
    }

    private var hardwarePresentation: DisplayHardwarePresentation {
        nearby.hardwarePresentation(for: device)
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
                case .introduction: accessibleStep { introduction }
                case .authentication: accessibleStep { authentication }
                case .connecting: accessibleStep { connecting }
                case .server: serverSetup
                case .wifi: wifiSetup
                case .maintenance: maintenance
                case .maintenanceAction: accessibleStep { maintenanceAction }
                case .complete: accessibleStep { completion }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tesseraeScreenBackground()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsToolbarCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Group {
                            if device.mode == .maintenance && (screen == .wifi || screen == .server) {
                                Button("Cancel", systemImage: "xmark") {
                                    changingServer = false
                                    serverPairingCode = ""
                                    screen = .maintenance
                                }
                                .labelStyle(.iconOnly)
                            } else {
                                Button {
                                    closeSheet()
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                        .labelStyle(.iconOnly)
                                }
                            }
                        }
                        .disabled(isSubmitting || nearby.isSavingScreenMode)
                    }
                }
            }
        }
        .presentationDetents(
            dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(360), .height(480), .large],
            selection: $selectedDetent
        )
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(isSubmitting || nearby.isSavingScreenMode)
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
                        Button("Cancel", systemImage: "xmark") { scannerPresented = false }
                            .labelStyle(.iconOnly)
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
        .onChange(of: nearby.connectionState) { _, state in
            switch state {
            case .ready:
                screen = device.mode == .maintenance ? .maintenance : .wifi
            case .configured:
                isSubmitting = false
                serverPairingCode = ""
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
        .onChange(of: dynamicTypeSize, initial: true) { _, _ in
            selectedDetent = preferredDetent(for: screen)
        }
        .onChange(of: screen) { _, newScreen in
            withAnimation(reduceMotion ? nil : .snappy) {
                selectedDetent = preferredDetent(for: newScreen)
            }
        }
        .task(id: model.activeInstance?.id) {
            if let instanceID = model.activeInstance?.id {
                setupNetworks.load(instanceID: instanceID)
            }
        }
    }

    @ViewBuilder
    private func accessibleStep<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            GeometryReader { geometry in
                ScrollView {
                    content().frame(minHeight: geometry.size.height)
                }
            }
        } else {
            content()
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
                DisplayHardwareBadge(presentation: hardwarePresentation, fallbackModelName: String(localized: "Nearby Display"))
            }
            Spacer(minLength: 0)
            if model.activeInstance == nil {
                Label(
                    device.mode == .setup
                        ? "Connect this app to a Tesserae Server first."
                        : "Bluetooth maintenance works without a server.",
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
                .tint(TesseraeTheme.accentFill)
                .foregroundStyle(.white)
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
            .tint(TesseraeTheme.accentFill)
            .foregroundStyle(.white)
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
            Text("Keep your device close.")
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wifiSetup: some View {
        let knownNetworks = model.activeInstance == nil ? [] : setupNetworks.networks
        let knownSSIDs = Set(knownNetworks.map(\.ssid))
        let otherNetworks = nearby.networks.filter { !knownSSIDs.contains($0.ssid) }

        return Form {
            Section("Display") {
                displayIdentityRows
            }

            if changingServer {
                Section("New Server") {
                    Text(targetServerURL?.absoluteString ?? "")
                        .font(.callout)
                        .textSelection(.enabled)
                    Button("Edit Server") { screen = .server }
                }
            }

            if !knownNetworks.isEmpty {
                Section {
                    ForEach(knownNetworks) { knownNetwork in
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
                    Text("Saved by Tesserae on this device.")
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
                Text(knownNetworks.isEmpty ? "Wi-Fi Networks" : "Other Networks")
            }

            if requiresWiFiPassword {
                Section("Password") {
                    SecureField("Wi-Fi password", text: $password)
                        .textContentType(.password)
                    if model.activeInstance != nil {
                        Toggle("Save on this device", isOn: $savePassword)
                    }
                }
            }

            Section {
                Button(isSubmitting
                       ? "Testing Connection…"
                       : changingServer ? "Change Server"
                       : isPicPakMaintenance ? "Save Wi-Fi" : "Connect Display") {
                    submitConfiguration()
                }
                .disabled(chosenSSID.isEmpty || isSubmitting || (changingServer && !canContinueServerChange))
            } footer: {
                Text(isPicPakMaintenance
                     ? "Saved after Wi-Fi connects. Server settings stay unchanged."
                     : "Saved only after Wi-Fi and server checks pass.")
            }
        }
        .disabled(isSubmitting)
        .scrollContentBackground(.hidden)
    }

    private var targetServerURL: URL? {
        if useConnectedServer {
            return model.activeInstance.flatMap {
                BLESetupConfiguration.serverURL(from: $0.baseURL.absoluteString)
            }
        }
        return BLESetupConfiguration.serverURL(from: serverAddress)
    }

    private var canContinueServerChange: Bool {
        targetServerURL != nil && (useConnectedServer
            ? model.supportsDeviceSetup
            : BLESetupConfiguration.isValidPairingCode(serverPairingCode))
    }

    private var serverSetup: some View {
        Form {
            Section {
                Picker("Server", selection: $useConnectedServer) {
                    Text("Connected in This App").tag(true)
                    Text("Enter Manually").tag(false)
                }
                if useConnectedServer {
                    if let instance = model.activeInstance {
                        Text(instance.name)
                        Text(instance.baseURL.absoluteString)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !model.supportsDeviceSetup {
                        Text("Connect this app to a server that supports display setup, or enter a server and pairing code manually.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Server URL", text: $serverAddress, prompt: Text(verbatim: "https://tesserae.example.com"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Server URL")
                        .accessibilityIdentifier("nearby-server-url")
                    SecureField("Device Pairing Code", text: $serverPairingCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .accessibilityLabel("Device Pairing Code")
                        .accessibilityIdentifier("nearby-server-pairing-code")
                }
            } header: {
                Text("New Server")
            } footer: {
                Text(useConnectedServer
                     ? "A one-time device pairing code will be requested when you submit."
                     : "Enter a six-digit device pairing code from the new server, not the Bluetooth code on the display.")
            }
            Section {
                Button("Continue to Wi-Fi") {
                    screen = .wifi
                    if let ssid = nearby.diagnostics?.ssid { selectNetwork(ssid) }
                    nearby.scanWiFi()
                }
                .disabled(!canContinueServerChange)
                .accessibilityIdentifier("nearby-server-continue")
            } footer: {
                Text("Confirm Wi-Fi next. The display saves the new server after connection checks pass, then restarts to register there.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var maintenance: some View {
        Form {
            if let error = nearby.displayRecords.storageError {
                Section {
                    Text(error).font(.footnote).foregroundStyle(TesseraeTheme.warning)
                }
            }
            if let diagnostics = nearby.diagnostics {
                Section {
                    displayIdentityRows
                    LabeledContent("Firmware", value: diagnostics.firmware)
                    LabeledContent(
                        "Battery",
                        value: diagnostics.batteryPercent.map { "\($0)%" } ?? "—"
                    )
                    if diagnostics.batteryMillivolts > 0 {
                        LabeledContent("Voltage", value: String(format: "%.2f V", Double(diagnostics.batteryMillivolts) / 1000))
                    }
                    if isPicPakMaintenance,
                       let speed = nearby.refreshSpeedSetting.confirmedValue {
                        Picker(selection: Binding(
                            get: { nearby.refreshSpeedSetting.confirmedValue ?? speed },
                            set: { nearby.setRefreshSpeed($0) }
                        )) {
                            ForEach(BLERefreshSpeed.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        } label: {
                            HStack {
                                Text("Refresh Speed")
                                if nearby.refreshSpeedSetting.isSaving {
                                    ProgressView()
                                        .accessibilityLabel("Saving refresh speed")
                                }
                            }
                        }
                        .disabled(
                            nearby.isSavingScreenMode
                                || nearby.refreshSpeedSetting.isSaving
                                || nearby.refreshSpeedSetting.needsReadback
                                || nearby.connectionState != .ready
                        )
                        .accessibilityIdentifier("nearby-refresh-speed")
                        .accessibilityValue(nearby.refreshSpeedSetting.confirmedValue?.displayName ?? "")

                        if let message = nearby.refreshSpeedSetting.errorMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if nearby.refreshSpeedSetting.needsReadback {
                                Button("Check Again") { nearby.requestDiagnostics() }
                            }
                        }
                    }
                } header: {
                    Text("Display")
                } footer: {
                    if isPicPakMaintenance,
                       nearby.refreshSpeedSetting.confirmedValue != nil {
                        Text("Faster refresh may leave ghosting. Applies next refresh.")
                    }
                }
                if nearby.supportsScreenMode, let mode = nearby.screenMode {
                    Section {
                        Picker("Screen Mode", selection: Binding(
                            get: { nearby.screenMode ?? mode },
                            set: { nearby.setScreenMode($0) }
                        )) {
                            ForEach(BLEScreenMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .accessibilityIdentifier("nearby-screen-mode")
                        .accessibilityValue((nearby.screenMode ?? mode).title)
                        .disabled(nearby.isSavingScreenMode || nearby.screenModeNeedsReadback
                                  || nearby.refreshSpeedSetting.isSaving || nearby.refreshSpeedSetting.needsReadback
                                  || nearby.connectionState != .ready)
                        if nearby.isSavingScreenMode {
                            HStack { ProgressView(); Text("Saving screen mode…") }
                        } else if mode == .bluetooth, !nearby.photoAuthorized {
                            Button("Allow This Device") { nearby.setScreenMode(.bluetooth) }
                                .disabled(nearby.screenModeNeedsReadback || nearby.connectionState != .ready)
                        }
                        if let message = nearby.screenModeError {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                        if nearby.screenModeNeedsReadback {
                            Button("Check Again") { nearby.requestDiagnostics() }
                        }
                    } footer: {
                        Text(mode == .bluetooth
                             ? (isPicPakMaintenance
                                ? String(localized: "After leaving Maintenance, press PicPak's button once with this app open to send a photo. Automatic updates and Wi-Fi heartbeats are paused.")
                                : String(localized: "Leave Maintenance and wait for the display to restart. Then press its button with this app open to send a photo. Automatic updates and Wi-Fi heartbeats are paused."))
                             : String(localized: "Automatic updates use the saved Wi-Fi and server settings."))
                    }
                }
                if nearby.screenModeUnavailable {
                    Section {
                        Text("The display's screen mode settings could not be read. Restore Automatic to use its saved Wi-Fi and server settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Restore Automatic (Wi-Fi)") { nearby.setScreenMode(.wifi) }
                            .accessibilityIdentifier("nearby-restore-automatic")
                            .disabled(nearby.isSavingScreenMode || nearby.screenModeNeedsReadback
                                      || nearby.refreshSpeedSetting.isSaving || nearby.refreshSpeedSetting.needsReadback
                                      || nearby.connectionState != .ready)
                        if nearby.isSavingScreenMode { ProgressView("Saving screen mode…") }
                        if let message = nearby.screenModeError {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                        if nearby.screenModeNeedsReadback {
                            Button("Check Again") { nearby.requestDiagnostics() }
                        }
                    }
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
                    changingServer = false
                    screen = .wifi
                    nearby.scanWiFi()
                }
                if !isPicPakMaintenance {
                    Button("Change Server", systemImage: "server.rack") {
                        changingServer = true
                        useConnectedServer = model.supportsDeviceSetup
                        serverAddress = ""
                        serverPairingCode = ""
                        screen = .server
                    }
                    .accessibilityIdentifier("nearby-change-server")
                }
                Button("Restart Display", systemImage: "arrow.clockwise") {
                    nearby.reboot()
                }
            }
            .disabled(nearby.isSavingScreenMode || nearby.screenModeNeedsReadback || nearby.refreshSpeedSetting.isSaving || nearby.refreshSpeedSetting.needsReadback)

            Section("Reset") {
                Button(role: .destructive) {
                    clearWiFiConfirmationPresented = true
                } label: {
                    Label("Clear Wi-Fi Settings", systemImage: "wifi.slash")
                        .foregroundStyle(TesseraeTheme.danger)
                }
                .confirmationDialog(
                    "Clear this display's Wi-Fi settings?",
                    isPresented: $clearWiFiConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Clear Wi-Fi Settings", role: .destructive) {
                        nearby.clearWiFi()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Forgets Wi-Fi and restarts. Tesserae server settings stay saved.")
                }

                Button(role: .destructive) {
                    factoryResetConfirmationPresented = true
                } label: {
                    Label("Factory Reset", systemImage: "trash")
                        .foregroundStyle(TesseraeTheme.danger)
                }
                .confirmationDialog(
                    "Factory reset this display?",
                    isPresented: $factoryResetConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Factory Reset Display", role: .destructive) {
                        nearby.factoryReset()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Erases Wi-Fi, server, and display settings, then restarts as a new display.")
                }
            }
            .disabled(nearby.isSavingScreenMode || nearby.screenModeNeedsReadback || nearby.refreshSpeedSetting.isSaving || nearby.refreshSpeedSetting.needsReadback)

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
                .foregroundStyle(TesseraeTheme.success)
            Text(changingServer ? "Server Saved" : isPicPakMaintenance ? "Wi-Fi Saved" : "Display Connected")
                .font(.title2.bold())
            Text(changingServer
                 ? "The display is restarting to register with the new server."
                 : isPicPakMaintenance
                 ? "Wi-Fi settings are saved. The display is restarting."
                 : "Wi-Fi and Tesserae are connected. The display is restarting.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Done", systemImage: "checkmark") {
                nearby.dismissSuggestion(for: device)
                nearby.disconnect()
                dismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .tint(TesseraeTheme.accentFill)
            .foregroundStyle(.white)
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
                    .foregroundStyle(TesseraeTheme.success)
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
                Button("Done", systemImage: "checkmark") {
                    closeSheet()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .tint(TesseraeTheme.accentFill)
                .foregroundStyle(.white)
                .controlSize(.large)
            } else {
                Spacer()
            }
        }
        .padding(28)
    }

    private var navigationTitle: LocalizedStringKey {
        switch screen {
        case .introduction: "Nearby Display"
        case .authentication: "Verify Display"
        case .connecting: "Connecting"
        case .server: "Change Server"
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

    private func submitConfiguration() {
        isSubmitting = true
        Task {
            do {
                let pairingCode: String
                let serverURL: URL?
                if changingServer && !useConnectedServer {
                    guard let target = targetServerURL,
                          BLESetupConfiguration.isValidPairingCode(serverPairingCode) else {
                        throw NearbyDeviceSetupError.invalidServerConfiguration
                    }
                    serverURL = target
                    pairingCode = serverPairingCode
                } else if device.mode == .maintenance && !changingServer {
                    // Maintenance changes Wi-Fi only. Keep the display's exact
                    // saved server URL and token, including any custom port.
                    pairingCode = ""
                    serverURL = nil
                } else if model.supportsDeviceSetup {
                    guard let instance = model.activeInstance else {
                        throw NearbyDeviceSetupError.noServer
                    }
                    let pairing = try await model.createFirmwareDevicePairing()
                    guard model.activeInstance?.id == instance.id,
                          model.activeInstance?.baseURL == instance.baseURL,
                          nearby.activeDevice?.id == device.id else {
                        throw NearbyDeviceSetupError.serverConnectionChanged
                    }
                    pairingCode = pairing.code
                    guard let target = BLESetupConfiguration.serverURL(from: instance.baseURL.absoluteString) else {
                        throw NearbyDeviceSetupError.invalidServerConfiguration
                    }
                    serverURL = target
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
        if dynamicTypeSize.isAccessibilitySize { return .large }
        return switch screen {
        case .authentication:
            .height(480)
        case .server, .wifi, .maintenance:
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

struct TesseraeEInkDisplayArtwork: View {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(NearbyDeviceManager.self) private var nearby
    @Environment(AppModel.self) private var model
    @Environment(SetupNetworkStore.self) private var setupNetworks
    @State private var selectedDevice: NearbyTesseraeDevice?

    var body: some View {
        List {
            if model.activeInstance != nil, !setupNetworks.networks.isEmpty {
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
                    Text("Saved by Tesserae on this device.")
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

                            Text("Keep the display close to your phone.")
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
                            let presentation = nearby.hardwarePresentation(for: device)

                            HStack(spacing: 13) {
                                Image(
                                    systemName: device.mode == .photo ? "photo" : device.mode == .setup
                                        ? "display.badge.checkmark"
                                        : "wrench.and.screwdriver"
                                )
                                .font(.system(size: 20, weight: .semibold))
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
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Text(hardwareSummary(presentation))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Label(
                                        device.mode == .photo ? "Ready to receive a photo" : device.mode == .setup
                                            ? "Ready to set up"
                                            : "Maintenance mode",
                                        systemImage: device.mode == .photo ? "photo" : device.mode == .setup
                                            ? "sparkles"
                                            : "wrench.fill"
                                    )
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(nearbyAccent)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                    .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
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

            Section {
                NearbyMaintenanceEntryRow(
                    title: "Refresh Button",
                    instruction: "Hold Refresh, then release.",
                    duration: "3 s"
                )
                NearbyMaintenanceEntryRow(
                    title: "PicPak Button",
                    instruction: "Hold the button, then release.",
                    duration: "10 s"
                )
                Label {
                    Text("Release before 20 seconds to avoid reset or setup.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                }
                .font(.footnote)
                .foregroundStyle(TesseraeTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            } header: {
                Text("Enter Maintenance Mode")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select the display above, then scan the code on its screen.")
                    Text("Closes after 5 minutes. To exit sooner, short-press the same button.")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .navigationTitle("Nearby Displays")
        .navigationBarTitleDisplayMode(.inline)
        .tesseraeMessageCenter()
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
            NearbyDeviceSheet(device: device)
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
        TesseraeTheme.accent
    }
}

private struct NearbyMaintenanceEntryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: LocalizedStringKey
    let instruction: LocalizedStringKey
    let duration: LocalizedStringKey

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(instruction)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(duration)
                .font(.headline.monospacedDigit())
                .foregroundStyle(TesseraeTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(TesseraeTheme.accentSoft, in: Capsule())
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
