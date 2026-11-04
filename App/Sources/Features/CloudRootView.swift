import SwiftUI
import TesseraeKit

struct CloudRootView: View {
    let model: CloudBrowseModel
    @Environment(CompanionPresentation.self) private var presentation
    @Environment(ConnectionHost.self) private var host
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var body: some View {
        @Bindable var presentation = presentation
        TabView {
            CloudResourceList(model: model, isDevice: true)
                .tabItem { Label("Displays", systemImage: "display").accessibilityIdentifier("cloud-displays-tab") }
            CloudResourceList(model: model, isDevice: false)
                .tabItem { Label("Dashboards", systemImage: "rectangle.stack").accessibilityIdentifier("cloud-pages-tab") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if horizontalSizeClass != .compact && canSend { TesseraeFloatingSendAction() }
        }
        .environment(\.tesseraePageSendEnabled, horizontalSizeClass == .compact && canSend)
        .sheet(item: $presentation.sheet) { sheet in
            switch sheet {
            case .settings: SettingsView()
            case .send:
                if let context = host.cloudPresentationContext, host.cloud === model {
                    CloudSendSheet(model: model, context: context)
                }
            case .cloudResults:
                if let context = host.cloudPresentationContext, host.cloud === model {
                    CloudSubmissionResultsSheet(context: context, initialID: presentation.cloudResultID)
                }
            case .uploads: EmptyView()
            }
        }
        .onChange(of: model.needsSignIn || model.isRestricted) { _, _ in
            Task { await host.cloudReadAccessChanged() }
        }
        .task { if model.snapshot == nil { await model.refresh() } }
    }
    private var canSend: Bool {
        host.canUseCloudSubmissions && !model.devices.isEmpty
            && model.snapshot?.account.auth.scopes.contains("app:send") == true
    }
}

private struct CloudResourceList: View {
    let model: CloudBrowseModel
    let isDevice: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(CompanionPresentation.self) private var presentation
    @State private var selectedID: String?
    @State private var connectionsPresented = false
    private var ids: [String] { isDevice ? model.devices.map(\.id) : model.pages.map(\.id) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                if let account = model.snapshot?.account {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.tenant.name).font(.headline)
                            Text(account.user.email).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("cloud-current-tenant")
                    }
                }
                if let problem = model.problem {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(problem, systemImage: "exclamationmark.triangle")
                            if let date = model.fetchedAt, model.snapshot != nil {
                                Text("Last updated: \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Choose Connection", systemImage: "arrow.triangle.swap") { connectionsPresented = true }
                        }
                        .accessibilityIdentifier("cloud-read-problem")
                    }
                }
                Section {
                    if isDevice {
                        ForEach(model.devices) { device in
                            NavigationLink(value: device.id) {
                                Label {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name).font(.headline)
                                        Text("\(device.panel.width) × \(device.panel.height)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "display") }
                            }
                            .accessibilityIdentifier("cloud-device-\(device.id)")
                        }
                    } else {
                        ForEach(model.pages) { page in
                            NavigationLink(value: page.id) {
                                Label(page.name, systemImage: "rectangle.stack")
                            }
                            .accessibilityIdentifier("cloud-page-\(page.id)")
                        }
                    }
                    if ids.isEmpty {
                        if model.isLoading {
                            ProgressView("Loading Cloud…")
                                .frame(maxWidth: .infinity, minHeight: 150)
                        } else if model.problem == nil {
                            VStack(spacing: 12) {
                                ContentUnavailableView(String(localized: isDevice ? "No Cloud Displays" : "No Cloud Dashboards"),
                                    systemImage: isDevice ? "display" : "rectangle.stack",
                                    description: Text(String(localized: isDevice ? "Set up a display in Tesserae Cloud, then refresh this list." : "Create a dashboard in Tesserae Cloud to see it here.")))
                                Link(String(localized: isDevice ? "Set Up in Cloud" : "Open Tesserae Cloud"),
                                    destination: isDevice ? AppConfiguration.cloudSetupURL(issuer: model.client.issuer) : model.client.issuer.appending(path: "app/"))
                                    .accessibilityIdentifier("cloud-setup-link")
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .tesseraeScreenBackground()
            .navigationTitle(String(localized: isDevice ? "Displays" : "Dashboards"))
            .refreshable { await model.refresh() }
            .toolbar {
                TesseraeRootToolbar(showsGlobalActions: horizontalSizeClass == .compact || selectedID == nil) {
                    Button("Refresh List", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .disabled(model.isLoading)
                        .accessibilityIdentifier("cloud-refresh-list")
                    if horizontalSizeClass == .compact || selectedID == nil {
                        Button("Send Results", systemImage: "clock") {
                            presentation.cloudResultID = nil; presentation.sheet = .cloudResults
                        }
                        .accessibilityIdentifier("cloud-send-results")
                    }
                }
            }
            .tesseraeRootPageChrome()
        } detail: {
            if let selectedID {
                CloudResourceDetail(model: model, id: selectedID, isDevice: isDevice)
                    .id("\(model.fence.epoch):\(isDevice):\(selectedID)")
            } else {
                ContentUnavailableView("Select an Item", systemImage: isDevice ? "display" : "rectangle.stack")
                    .tesseraeScreenBackground()
            }
        }
        .onChange(of: ids) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
        .sheet(isPresented: $connectionsPresented) { OnboardingView(isChoosingServer: true) }
    }
}

private struct CloudResourceDetail: View {
    let model: CloudBrowseModel
    let id: String
    let isDevice: Bool
    @Environment(ConnectionHost.self) private var host
    @Environment(CompanionPresentation.self) private var presentation
    @State private var refreshDecision = UUID()
    @State private var startingRefresh = false
    @State private var refreshError: String?
    private var device: CloudDevice? { model.devices.first { $0.id == id } }
    private var page: CloudPage? { model.pages.first { $0.id == id } }
    private var exists: Bool { isDevice ? device != nil : page != nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if exists && model.verifiedDetails.contains(CloudBrowseModel.key(id, isDevice)) {
                    Text(isDevice ? device!.name : page!.name).font(.title2.bold())
                    preview
                    if let device {
                        LabeledContent("Panel", value: "\(device.panel.width) × \(device.panel.height)")
                        if let battery = device.batteryPercent {
                            LabeledContent("Battery", value: "\(Int(battery))%")
                        }
                        if let seen = device.lastSeenAt { LabeledContent("Last Seen", value: seen.formatted()) }
                        if let frame = device.frame { LabeledContent("Frame Generated", value: frame.renderedAt.formatted()) }
                    }
                    if let page { LabeledContent("Updated", value: page.updatedAt.formatted()) }
                    if let refreshError { Text(refreshError).foregroundStyle(.red) }
                    Text("Existing preview only. Browsing does not refresh the physical display.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if model.previews[CloudBrowseModel.key(id, isDevice)] == nil
                            || model.previews[CloudBrowseModel.key(id, isDevice)] == .loading {
                    ProgressView("Loading Preview…").frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ContentUnavailableView("Item Unavailable", systemImage: "rectangle.slash",
                        description: Text(model.problem ?? String(localized: "This item is no longer available.")))
                }
            }
            .frame(maxWidth: 820).padding(20).frame(maxWidth: .infinity)
        }
        .tesseraeScreenBackground()
        .navigationTitle(String(localized: isDevice ? "Display" : "Dashboard"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            TesseraeRootToolbar {
                Button("Send Results", systemImage: "clock") {
                    presentation.cloudResultID = nil; presentation.sheet = .cloudResults
                }
                .accessibilityIdentifier("cloud-send-results")
                if isDevice, device?.pageID != nil,
                   model.snapshot?.account.auth.scopes.contains("app:refresh") == true {
                    Button("Refresh Current Page", systemImage: "arrow.triangle.2.circlepath") { refreshCurrentPage() }
                        .disabled(startingRefresh || !host.canUseCloudSubmissions)
                        .accessibilityIdentifier("cloud-refresh-current")
                }
                Button("Refresh Preview", systemImage: "arrow.clockwise") {
                    Task { await model.openDetail(id: id, isDevice: isDevice, reuseCached: false) }
                }
            }
        }
        .tesseraeRootPageChrome()
        .task(id: model.previewVersion(id: id, isDevice: isDevice)) {
            await model.openDetail(id: id, isDevice: isDevice)
        }
        .onDisappear { model.closeDetail(id: id, isDevice: isDevice) }
    }
    private func refreshCurrentPage() {
        guard !startingRefresh, host.cloud === model, let context = host.cloudPresentationContext else { return }
        startingRefresh = true; refreshError = nil
        let decision = refreshDecision
        Task {
            defer { startingRefresh = false }
            do {
                let id = try await host.refreshCloudCurrentPage(id, decision: decision, context: context)
                refreshDecision = UUID()
                host.withCurrentCloudPresentation(context) {
                    presentation.cloudResultID = id; presentation.sheet = .cloudResults
                }
            } catch { refreshError = error.localizedDescription }
        }
    }
    @ViewBuilder private var preview: some View {
        switch model.previews[CloudBrowseModel.key(id, isDevice)] {
        case .image(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("Existing Cloud Preview")
                    .accessibilityIdentifier("cloud-preview-image")
            } else {
                ContentUnavailableView("Preview Unavailable", systemImage: "photo.badge.exclamationmark",
                    description: Text("This saved preview could not be opened."))
            }
        case .missing:
            ContentUnavailableView("No Preview Yet", systemImage: "photo",
                description: Text("A preview will appear when a saved image is available in Cloud."))
                .accessibilityIdentifier("cloud-no-preview")
        case .unavailable(let message):
            ContentUnavailableView("Preview Unavailable", systemImage: "wifi.exclamationmark", description: Text(message))
        default: ProgressView("Loading Preview…").frame(maxWidth: .infinity, minHeight: 180)
        }
    }
}

struct CloudConnectionSettings: View {
    let model: CloudBrowseModel
    let onChooseConnection: () -> Void
    @Environment(ConnectionHost.self) private var host
    var body: some View {
        Section("Tesserae Cloud") {
            if let account = model.snapshot?.account {
                LabeledContent("Account", value: account.user.email)
                LabeledContent("Tenant", value: account.tenant.name)
                LabeledContent("Role", value: String(localized: account.role == "owner" ? "Owner" : "Member"))
            }
            if host.isSigningIn {
                ProgressView(String(localized: host.loginPhase == .committing ? "Finishing Sign-In…" : "Waiting for Sign-In…"))
                if host.canCancelLogin {
                    Button("Cancel Sign-In", role: .cancel) { host.cancelCloudSignIn() }
                }
            }
            if let error = host.loginError { Text(error).foregroundStyle(TesseraeTheme.danger) }
            LabeledContent("Service", value: model.client.issuer.absoluteString)
            Button("Choose Connection", systemImage: "arrow.triangle.swap", action: onChooseConnection)
            Button("Sign In Again", systemImage: "person.crop.circle.badge.checkmark") { Task { await host.beginCloudSignIn() } }
                .disabled(host.isSigningIn)
            Link("Set Up in Cloud", destination: AppConfiguration.cloudSetupURL(issuer: model.client.issuer))
            if let account = model.snapshot?.account {
                NavigationLink("Cloud Usage & Features") {
                    Form {
                        Section("Usage") {
                            LabeledContent("Displays", value: String(account.usage.devices))
                            LabeledContent("Dashboards", value: String(account.usage.pages))
                            LabeledContent("Renders Today", value: String(account.usage.rendersToday))
                            LabeledContent("Charged Renders Today", value: String(account.usage.rendersChargedToday))
                            LabeledContent("MCP Calls Today", value: String(account.usage.mcpCallsToday))
                            LabeledContent("Browser Time Today", value: Duration.milliseconds(account.usage.browserMillisecondsToday).formatted(.units(allowed: [.hours, .minutes, .seconds])))
                            LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: Int64(account.usage.storageBytes), countStyle: .file))
                        }
                        Section("Limits") {
                            ForEach(account.limits.keys.sorted(), id: \.self) { key in
                                if let title = CloudSettingsLabels.limit(key) {
                                    LabeledContent(title, value: account.limits[key].flatMap { $0 }.map { $0.formatted() } ?? String(localized: "Unlimited"))
                                }
                            }
                        }
                        Section("Features") {
                            ForEach(account.features.keys.sorted(), id: \.self) { key in
                                if let title = CloudSettingsLabels.feature(key) {
                                    LabeledContent(title, value: account.features[key] == true ? String(localized: "Available") : String(localized: "Unavailable"))
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden).tesseraeScreenBackground()
                    .navigationTitle("Cloud Usage & Features")
                }
            }
            Button("Sign Out", role: .destructive) { Task { await host.signOut() } }
        }
    }
}

private enum CloudSettingsLabels {
    static func limit(_ key: String) -> String? {
        switch key {
        case "devices": String(localized: "Displays")
        case "pages": String(localized: "Dashboards")
        case "web_pages": String(localized: "Web Pages")
        case "renders_per_day": String(localized: "Daily Renders")
        case "mcp_calls_per_day": String(localized: "Daily MCP Calls")
        case "fonts_per_day": String(localized: "Daily Fonts")
        case "agent_messages_per_day": String(localized: "Daily Agent Messages")
        case "agent_credits_per_month": String(localized: "Monthly Agent Credits")
        case "min_wake_s": String(localized: "Minimum Wake Interval (seconds)")
        case "render_seconds_per_day": String(localized: "Daily Render Time (seconds)")
        case "storage_mb": String(localized: "Storage (MB)")
        case "history_days": String(localized: "History (days)")
        case "battery_days": String(localized: "Battery History (days)")
        case "unfiled_renders_per_day": String(localized: "Daily Unfiled Renders")
        default: nil
        }
    }
    static func feature(_ key: String) -> String? {
        switch key {
        case "connectors": String(localized: "Connectors")
        case "state": String(localized: "Cloud State")
        case "mcp": String(localized: "MCP Tools")
        case "agent": String(localized: "Agent")
        case "platform_agent": String(localized: "Platform Agent")
        case "hardware_reuse": String(localized: "Hardware Reuse")
        case "custom_name": String(localized: "Custom Names")
        default: nil
        }
    }
}
