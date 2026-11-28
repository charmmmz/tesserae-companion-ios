import SwiftUI
import TesseraeKit

struct CloudNavigationTitle: View {
    let title: String
    var compact = false
    var tenant: String? = nil

    var body: some View {
        let context = tenant.map { String(localized: "Tesserae Cloud, \($0)") } ?? String(localized: "Tesserae Cloud")
        HStack(spacing: compact ? 6 : 9) {
            Text(title)
                .font(compact ? .headline : .largeTitle.bold())
                .lineLimit(compact ? 1 : nil)
            Image(systemName: "cloud")
                .font(compact ? .subheadline : .title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(context)"))
        .accessibilityAddTraits(.isHeader)
    }
}

struct CloudResourceList: View {
    let model: CloudBrowseModel
    let isDevice: Bool
    let isActive: Bool
    let showResult: (UUID) -> Void
    let onDashboardAccepted: (UUID, CloudPresentationContext) -> Void
    @Environment(ConnectionHost.self) private var host
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedID: String?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var connectionsPresented = false
    @State private var pushTarget: CloudDashboardPushTarget?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var collapsedSections: Set<String> = ["other"]

    private var title: String { isDevice ? String(localized: "Displays") : String(localized: "Dashboards") }
    private var icon: String { isDevice ? "display" : "rectangle.stack" }
    private var ids: [String] { isDevice ? model.devices.map(\.id) : model.pages.map(\.id) }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canPushDashboard: Bool {
        host.cloud === model && host.canUseCloudSubmissions && !model.devices.isEmpty
            && model.snapshot?.account.auth.scopes.contains(CloudTokenResponse.dashboardPushScope) == true
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CloudNavigationTitle(title: title, tenant: model.snapshot?.account.tenant.name)
                        .accessibilityIdentifier("cloud-current-tenant")
                    if !isDevice { searchField }
                    if let problem = model.problem { readProblem(problem) }
                    if ids.isEmpty {
                        emptyState
                    } else if isDevice {
                        displays
                    } else {
                        dashboards
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.always)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("cloud-resource-list")
            .refreshable { await model.refresh() }
            .accessibilityAction(named: Text("Refresh List")) { Task { await model.refresh() } }
            .tesseraeScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                TesseraeRootToolbar(showsGlobalActions: horizontalSizeClass == .compact || selectedID == nil) {
                    EmptyView()
                }
            }
            .tesseraeRootPageChrome()
        } detail: {
            NavigationStack {
                if let selectedID {
                    CloudResourceDetail(model: model, id: selectedID, isDevice: isDevice, showResult: showResult,
                        pushDashboard: canPushDashboard ? { page in beginPush(page) } : nil)
                        .id(selectedID)
                } else {
                    ContentUnavailableView("Select an Item", systemImage: icon)
                        .tesseraeScreenBackground()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: ids) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
                preferredColumn = .sidebar
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { searchFocused = false }
        }
        .sheet(isPresented: $connectionsPresented) { OnboardingView(isChoosingServer: true) }
        .sheet(item: $pushTarget) { target in
            CloudDashboardPushSheet(model: model, target: target) { id in
                pushTarget = nil
                onDashboardAccepted(id, target.context)
            }
        }
    }

    private func beginPush(_ page: CloudPage, preferredDeviceID: String? = nil) {
        guard canPushDashboard, let context = host.cloudPresentationContext else { return }
        searchFocused = false
        let assigned = model.devices.filter { $0.pageID == page.id || $0.id == page.deviceID }.map(\.id)
        pushTarget = .init(page: page, context: context,
            deviceIDs: preferredDeviceID.map { Set([$0]) } ?? Set(assigned))
    }

    private var displays: some View {
        LazyVStack(spacing: 14) {
            ForEach(model.devices) { device in
                Button {
                    open(device.id)
                } label: {
                    CloudDisplayCard(model: model, device: device, loadsPreview: loadsPreviews)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cloud-device-\(device.id)")
            }
        }
    }

    private var loadsPreviews: Bool { isActive && (horizontalSizeClass != .compact || preferredColumn == .sidebar) }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Dashboards", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("cloud-dashboard-search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Label("Clear Search", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(TesseraeTheme.surface, in: Capsule())
    }

    private struct PageSection: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let pages: [CloudPage]
        var deviceID: String? = nil
    }

    private var sections: [PageSection] {
        let pages = model.pages.filter {
            searchTerm.isEmpty || $0.name.localizedStandardContains(searchTerm)
        }
        var result = model.devices.compactMap { device -> PageSection? in
            let matching = pages.filter { $0.id == device.pageID }
            guard !matching.isEmpty else { return nil }
            return PageSection(id: "display-\(device.id)", title: device.name,
                symbol: device.panel.height > device.panel.width ? "rectangle.portrait.inset.filled" : "display",
                pages: matching, deviceID: device.id)
        }
        let assigned = Set(model.devices.compactMap(\.pageID))
        let other = pages.filter { !assigned.contains($0.id) }
        if !other.isEmpty {
            result.append(PageSection(id: "other", title: String(localized: "Other Dashboards"),
                symbol: "square.grid.2x2", pages: other))
        }
        return result
    }

    private var dashboardColumns: [GridItem] {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.adaptive(minimum: 340), spacing: 12)]
            : [GridItem(.flexible())]
    }

    @ViewBuilder private var dashboards: some View {
        let sections = sections
        if sections.isEmpty {
            ContentUnavailableView.search(text: searchTerm)
        } else {
            LazyVGrid(columns: dashboardColumns, alignment: .leading, spacing: 10) {
                ForEach(sections) { section in
                    let collapsed = searchTerm.isEmpty && collapsedSections.contains(section.id)
                    Section {
                        if !collapsed {
                            ForEach(section.pages) { page in
                                CloudDashboardCard(model: model, page: page, loadsPreview: loadsPreviews,
                                    open: { open(page.id) },
                                    push: canPushDashboard ? { beginPush(page, preferredDeviceID: section.deviceID) } : nil)
                            }
                        }
                    } header: {
                        DashboardSectionHeader(title: section.title, subtitle: nil, count: section.pages.count,
                            isCollapsed: collapsed, canCollapse: searchTerm.isEmpty, minimumHeight: 44, icon: Image(systemName: section.symbol)) {
                            if collapsed { collapsedSections.remove(section.id) }
                            else { collapsedSections.insert(section.id) }
                        }
                        .accessibilityIdentifier("cloud-dashboard-section-\(section.id)")
                    }
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.isLoading {
            ProgressView("Loading Cloud…").frame(maxWidth: .infinity, minHeight: 150)
        } else if model.problem == nil {
            ContentUnavailableView {
                Label(isDevice ? String(localized: "No Cloud Displays") : String(localized: "No Cloud Dashboards"), systemImage: icon)
            } description: {
                Text(isDevice ? String(localized: "Set up a display in Tesserae Cloud, then refresh this list.")
                    : String(localized: "Create a dashboard in Tesserae Cloud to see it here."))
            } actions: {
                Link(isDevice ? String(localized: "Set Up in Cloud") : String(localized: "Open Tesserae Cloud"),
                    destination: isDevice ? AppConfiguration.cloudSetupURL(issuer: model.client.issuer)
                    : model.client.issuer.appending(path: "app/"))
                .accessibilityIdentifier("cloud-setup-link")
            }
        }
    }

    private func readProblem(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(problem, systemImage: "exclamationmark.triangle")
            if let date = model.fetchedAt, model.snapshot != nil {
                Text("Last updated: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Choose Connection", systemImage: "arrow.triangle.swap") { connectionsPresented = true }
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
        .accessibilityIdentifier("cloud-read-problem")
    }

    private func open(_ id: String) {
        searchFocused = false
        selectedID = id
        preferredColumn = .detail
    }
}

private struct CloudDisplayCard: View {
    let model: CloudBrowseModel
    let device: CloudDevice
    let loadsPreview: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        DisplayCardLayout {
            VStack(alignment: .leading, spacing: 9) {
                Label {
                    Text(device.name)
                } icon: {
                    Image(systemName: device.panel.height > device.panel.width ? "rectangle.portrait" : "display")
                        .foregroundStyle(TesseraeTheme.accent)
                }
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                DisplayHardwareBadge(presentation: DisplayHardwarePresentation(kind: device.kind))
                let metrics = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 12))
                metrics {
                    if let battery = device.batteryReading {
                        Label(battery.text, systemImage: battery.icon)
                    }
                    if let seen = device.lastSeenAt {
                        Label {
                            Text(seen, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } preview: { canvasSize in
            let scale = min(canvasSize.width / CGFloat(max(device.panel.width, 1)),
                            canvasSize.height / CGFloat(max(device.panel.height, 1)))
            CloudCardPreview(model: model, id: device.id, isDevice: true,
                loadsPreview: loadsPreview && device.frame != nil, title: device.name,
                symbol: "display", detail: "\(device.panel.width) × \(device.panel.height)")
                .frame(width: CGFloat(device.panel.width) * scale, height: CGFloat(device.panel.height) * scale)
                .frame(width: canvasSize.width, height: canvasSize.height)
        }
    }
}

private struct CloudDashboardCard: View {
    let model: CloudBrowseModel
    let page: CloudPage
    let loadsPreview: Bool
    let open: () -> Void
    let push: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) { icon; details }
                previewButton
            }
            .tesseraeCard()
        } else {
            DashboardCardRow {
                icon
            } details: {
                details
            } preview: {
                previewButton
            }
            .tesseraeCard()
        }
    }

    private var icon: some View {
        Image(systemName: page.kind == "album" ? "photo.on.rectangle" : "rectangle.grid.2x2")
            .font(.system(size: 18))
            .foregroundStyle(TesseraeTheme.accent)
            .frame(width: 36, height: 36)
            .background(TesseraeTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: open) { title.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cloud-page-\(page.id)")
            if let push {
                Button(action: push) {
                    Label("Push", systemImage: "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 11)
                        .frame(minHeight: 44)
                        .background {
                            Capsule().fill(TesseraeTheme.accentFill)
                                .frame(height: 26)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel(Text("Push \(page.name)"))
                .accessibilityIdentifier("cloud-dashboard-push-\(page.id)")
            }
        }
    }

    private var previewButton: some View {
        Button(action: open) { preview.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(page.name).font(.headline)
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            Text(page.kind.capitalized).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var preview: some View {
        CloudCardPreview(model: model, id: page.id, isDevice: false, loadsPreview: loadsPreview,
            title: page.name, symbol: "rectangle.stack", detail: nil)
            .frame(width: 112, height: 118)
    }
}

private struct CloudCardPreview: View {
    let model: CloudBrowseModel
    let id: String
    let isDevice: Bool
    let loadsPreview: Bool
    let title: String
    let symbol: String
    let detail: String?
    @State private var data: Data?
    @State private var loadedVersion: String?

    private var version: String? {
        loadsPreview && !model.needsSignIn && !model.isRestricted ? model.previewVersion(id: id, isDevice: isDevice) : nil
    }

    var body: some View {
        PreviewArtwork(
            state: version == loadedVersion ? data.map { PreviewImageState(data: $0, eTag: nil, phase: .ready) } : nil,
            placeholderSystemName: symbol,
            placeholderLabel: String(localized: "Preview unavailable for \(title)"),
            imageLabel: String(localized: "Preview for \(title)"),
            accessibilityIdentifier: "cloud-card-preview-\(id)",
            placeholderDetail: detail,
            cachesDecodedImage: false
        )
        .accessibilityHidden(true)
        .task(id: version) {
            data = nil
            loadedVersion = nil
            guard let request = version else { return }
            let preview = await model.cardPreview(id: id, isDevice: isDevice, version: request)
            guard !Task.isCancelled, version == request else { return }
            loadedVersion = request
            data = preview
        }
        .onDisappear { data = nil; loadedVersion = nil }
    }
}

private extension CloudDevice {
    var batteryReading: (text: String, icon: String)? {
        guard let batteryPercent, (0...100).contains(batteryPercent) else { return nil }
        let level = Int((batteryPercent / 25).rounded()) * 25
        return ((batteryPercent / 100).formatted(.percent.precision(.fractionLength(0))),
                "battery.\(level)percent")
    }
}

private struct CloudResourceDetail: View {
    let model: CloudBrowseModel
    let id: String
    let isDevice: Bool
    let showResult: (UUID) -> Void
    let pushDashboard: ((CloudPage) -> Void)?
    @Environment(ConnectionHost.self) private var host
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.tesseraePageSendEnabled) private var pageSendEnabled
    @State private var refreshDecision = UUID()
    @State private var refreshObservation: UUID?
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshFeedback: RefreshFeedback?
    @State private var retriedAfterRateLimit = false

    private enum RefreshFeedback: Equatable {
        case ready, attention(UUID), failed(String)
    }

    private var key: String { CloudBrowseModel.key(id, isDevice) }
    private var previewState: CloudBrowseModel.Preview? { model.previews[key] }
    private var previewRetryDate: Date? {
        guard case .rateLimited(let until) = previewState else { return nil }
        return until
    }
    private var device: CloudDevice? { isDevice ? model.devices.first { $0.id == id } : nil }
    private var page: CloudPage? { isDevice ? nil : model.pages.first { $0.id == id } }
    private var name: String { device?.name ?? page?.name ?? String(localized: "Preview") }
    private var exists: Bool { device != nil || page != nil }
    private var canRefresh: Bool {
        device?.pageID != nil && model.snapshot?.account.auth.scopes.contains("app:refresh") == true
    }

    var body: some View {
        Group {
            if isDevice {
                displayContent
            } else {
                dashboardContent
            }
        }
        .scrollBounceBehavior(.always)
        .accessibilityIdentifier("cloud-resource-detail")
        .refreshable { await reloadPreview() }
        .accessibilityAction(named: Text("Reload Preview")) { Task { await reloadPreview() } }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(id: "cloud-detail-title", placement: .principal) {
                CloudNavigationTitle(title: name, compact: true)
            }
            TesseraeRootToolbar(showsGlobalActions: isDevice || horizontalSizeClass != .compact) {
                if let page, model.verifiedDetails.contains(key), let url = dashboardURL(page) {
                    Link(destination: url) {
                        Label("Open in Cloud", systemImage: "safari")
                    }
                    .accessibilityIdentifier("cloud-dashboard-web")
                }
            }
        }
        .tesseraeRootPageChrome()
        .environment(\.tesseraePageSendEnabled, isDevice && pageSendEnabled)
        .task(id: model.previewVersion(id: id, isDevice: isDevice)) {
            await model.openDetail(id: id, isDevice: isDevice)
        }
        .task(id: previewRetryDate) {
            guard let date = previewRetryDate, !retriedAfterRateLimit else { return }
            do {
                while date > .now {
                    try await Task.sleep(for: .seconds(min(date.timeIntervalSinceNow, 60)))
                }
                try Task.checkCancellation()
            } catch { return }
            guard exists, previewRetryDate == date else { return }
            retriedAfterRateLimit = true
            await reloadPreview()
        }
        .task(id: refreshFeedback) {
            guard refreshFeedback == .ready else { return }
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
            if refreshFeedback == .ready { refreshFeedback = nil }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
            refreshObservation = nil
            retriedAfterRateLimit = false
            model.closeDetail(id: id, isDevice: isDevice)
        }
    }

    private var displayContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let device, model.verifiedDetails.contains(key) {
                    displayPreviewCard
                    connectionCard(device)
                    deviceDetails(device)
                } else {
                    detailStatus
                }
            }
            .frame(maxWidth: 820)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .tesseraeScreenBackground()
    }

    private var dashboardContent: some View {
        DashboardDetailForm {
            if let page, model.verifiedDetails.contains(key) {
                Section {
                    DashboardDetailPreview {
                        preview
                    } action: {
                        if let pushDashboard {
                            Button { pushDashboard(page) } label: {
                                Label("Push", systemImage: "paperplane.fill")
                                    .tesseraeIconActionLabel()
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("cloud-dashboard-detail-push")
                            .padding(10)
                        }
                    }
                }
                dashboardDetails(page)
            } else {
                Section { detailStatus }
            }
        }
    }

    @ViewBuilder private var detailStatus: some View {
        if exists, case .rateLimited(let until) = previewState {
            rateLimitedPreview(until: until)
        } else if exists && (previewState == nil || previewState == .loading) {
            ProgressView("Loading Preview…").frame(maxWidth: .infinity, minHeight: 180)
        } else {
            ContentUnavailableView("Item Unavailable", systemImage: "rectangle.slash",
                description: Text(model.problem ?? String(localized: "This item is no longer available.")))
        }
    }

    private var displayPreviewCard: some View {
        DisplayPreviewCard {
            ViewThatFits(in: .horizontal) {
                HStack {
                    previewTitle
                    Spacer(minLength: 8)
                    refreshButton
                }
                VStack(alignment: .leading, spacing: 0) {
                    previewTitle
                    refreshButton
                }
            }
            preview
            refreshMessage
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewTitle: some View {
        Label("Screen Preview", systemImage: "display").font(.headline)
    }

    @ViewBuilder private var refreshButton: some View {
        if canRefresh {
            Button(action: refreshCurrentPage) {
                Group {
                    if refreshTask != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .foregroundStyle(TesseraeTheme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(refreshTask != nil || !host.canUseCloudSubmissions)
            .accessibilityLabel(refreshTask == nil ? Text("Refresh") : Text("Refreshing…"))
            .accessibilityHint("Prepares a fresh image for the display’s current dashboard.")
            .accessibilityIdentifier("cloud-refresh-current")
        }
    }

    @ViewBuilder private var refreshMessage: some View {
        switch refreshFeedback {
        case .ready:
            Label("Ready for next wake", systemImage: "checkmark.circle")
                .font(.footnote).foregroundStyle(TesseraeTheme.success)
                .accessibilityIdentifier("cloud-refresh-ready")
        case .attention(let batchID):
            HStack {
                Label("Check this refresh", systemImage: "exclamationmark.circle")
                    .foregroundStyle(TesseraeTheme.warning)
                Spacer()
                Button("View") { showResult(batchID) }.frame(minHeight: 44)
            }
            .font(.subheadline)
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(TesseraeTheme.danger)
        case nil:
            EmptyView()
        }
    }

    private func connectionCard(_ device: CloudDevice) -> some View {
        DisplayDetailCard(title: "Connection & Power", systemImage: "antenna.radiowaves.left.and.right") {
            DisplayDetailRow(title: "Last Seen") {
                if let seen = device.lastSeenAt {
                    Text(seen, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                } else {
                    Text("Not reported")
                }
            }
            DisplayDetailRow(title: "Battery") {
                if let battery = device.batteryReading {
                    Label(battery.text, systemImage: battery.icon)
                } else {
                    Text("Not reported")
                }
            }
            DisplayDetailRow(title: "Signal") {
                if let rssi = device.rssi {
                    Text("\(rssi.formatted(.number.precision(.fractionLength(0)))) dBm")
                } else {
                    Text("Not reported")
                }
            }
        }
    }

    private func deviceDetails(_ device: CloudDevice) -> some View {
        DisclosureGroup {
            VStack(spacing: 12) {
                DisplayDetailRow(title: "Model") {
                    DisplayHardwareBadge(presentation: DisplayHardwarePresentation(kind: device.kind))
                }
                DisplayDetailRow(title: "Panel") { Text("\(device.panel.width) × \(device.panel.height)") }
                if let firmware = device.firmwareVersion {
                    DisplayDetailRow(title: "Firmware") { Text(firmware) }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Device Details", systemImage: "info.circle")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
        }
        .tesseraeCard()
    }

    private func dashboardDetails(_ page: CloudPage) -> some View {
        let names = model.devices.filter { $0.pageID == page.id }.map(\.name)
        return Section("General") {
            LabeledContent("Name", value: page.name)
            LabeledContent("Type", value: page.kind.capitalized)
            if !names.isEmpty {
                LabeledContent("Assigned to", value: names.formatted(.list(type: .and)))
            }
            LabeledContent("Updated", value: page.updatedAt.formatted())
        }
    }

    private func dashboardURL(_ page: CloudPage) -> URL? {
        var url = URLComponents(url: model.client.issuer.appending(path: "app/"), resolvingAgainstBaseURL: false)
        let editor = page.kind == "ink" || page.kind == "album" ? page.kind : "editor"
        url?.fragment = "/\(editor)/\(page.id)"
        return url?.url
    }

    private func reloadPreview() async {
        await model.openDetail(id: id, isDevice: isDevice, reuseCached: false)
    }

    private func rateLimitedPreview(until: Date?) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label("Preview Temporarily Unavailable", systemImage: "clock")
                    .accessibilityIdentifier("cloud-preview-rate-limited")
            } description: {
                if let until {
                    Text("Try again at \(until.formatted(date: .omitted, time: .standard)).")
                } else {
                    Text("Cloud is busy. Wait before trying again.")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                Button("Reload Preview") { Task { await reloadPreview() } }
                    .frame(minHeight: 44)
                    .buttonStyle(.bordered)
                    .disabled(until.map { clock.date < $0 } ?? false)
                    .accessibilityIdentifier("cloud-reload-preview")
            }
        }
    }

    private func refreshCurrentPage() {
        guard refreshTask == nil, host.cloud === model, let context = host.cloudPresentationContext else { return }
        let observation = UUID()
        refreshObservation = observation
        refreshFeedback = nil
        refreshTask = Task {
            defer {
                if refreshObservation == observation {
                    refreshTask = nil
                    refreshObservation = nil
                }
            }
            do {
                let batchID = try await host.refreshCloudCurrentPage(id, decision: refreshDecision, context: context)
                try Task.checkCancellation()
                refreshDecision = UUID()
                let batch = try await host.waitForCloudResult(batchID, context: context)
                try Task.checkCancellation()
                host.withCurrentCloudPresentation(context) {
                    refreshFeedback = batch.results.first?.outcome.isCleanGenerated == true ? .ready : .attention(batchID)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                host.withCurrentCloudPresentation(context) { refreshFeedback = .failed(error.localizedDescription) }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch previewState {
        case .image(let data):
            if let image = UIImage(data: data) {
                let artwork = Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                    .accessibilityLabel("Existing Cloud Preview")
                    .accessibilityIdentifier("cloud-preview-image")

                if isDevice {
                    artwork
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    artwork
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(TesseraeTheme.surfaceInset, in: RoundedRectangle(cornerRadius: 9))
                }
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
        case .rateLimited(let until):
            rateLimitedPreview(until: until)
        default:
            ProgressView("Loading Preview…").frame(maxWidth: .infinity, minHeight: 180)
        }
    }
}


private struct CloudDashboardPushTarget: Identifiable {
    let id = UUID()
    let page: CloudPage
    let context: CloudPresentationContext
    let deviceIDs: Set<String>
}

private struct CloudDashboardPushSheet: View {
    let model: CloudBrowseModel
    let target: CloudDashboardPushTarget
    let onAccepted: (UUID) -> Void
    @Environment(ConnectionHost.self) private var host
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var decision = UUID()
    @State private var isSubmitting = false
    @State private var error: String?

    private var devices: [CloudDevice] {
        model.devices.filter { $0.panel.compositionGeometry != nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CloudCardPreview(model: model, id: target.page.id, isDevice: false, loadsPreview: true,
                        title: target.page.name, symbol: "rectangle.stack", detail: nil)
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    Text(target.page.name).font(.headline)
                }
                Section {
                    ForEach(devices) { device in
                        Toggle(device.name, isOn: Binding(get: { selected.contains(device.id) }, set: { on in
                            if on { selected.insert(device.id) } else { selected.remove(device.id) }
                            decision = UUID()
                        }))
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("cloud-dashboard-target-\(device.id)")
                    }
                } header: {
                    Text("Displays")
                } footer: {
                    Text("This assigns the Dashboard to the selected displays. They can collect the new frame on their next wake.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(TesseraeTheme.danger) }
                }
            }
            .scrollContentBackground(.hidden)
            .tesseraeScreenBackground()
            .navigationTitle("Push Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .disabled(isSubmitting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: submit) {
                    Group {
                        if isSubmitting { ProgressView().accessibilityLabel("Sending…") }
                        else { Label("Push Dashboard", systemImage: "paperplane.fill") }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || isSubmitting || host.cloudPresentationContext != target.context)
                .accessibilityIdentifier("cloud-dashboard-submit")
                .padding()
                .background(.bar)
            }
        }
        .onAppear { selected = target.deviceIDs.intersection(devices.map(\.id)) }
        .interactiveDismissDisabled(isSubmitting)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func submit() {
        guard !isSubmitting, !selected.isEmpty, host.cloudPresentationContext == target.context else { return }
        isSubmitting = true
        error = nil
        let deviceIDs = selected
        let decision = decision
        Task {
            defer { isSubmitting = false }
            do {
                let id = try await host.pushCloudDashboard(pageID: target.page.id, deviceIDs: deviceIDs,
                    decision: decision, context: target.context)
                host.withCurrentCloudPresentation(target.context) { onAccepted(id) }
            } catch {
                host.withCurrentCloudPresentation(target.context) { self.error = error.localizedDescription }
            }
        }
    }
}
