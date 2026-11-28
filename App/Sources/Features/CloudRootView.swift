import SwiftUI
import TesseraeKit

struct CloudRootView: View {
    private enum Tab: Hashable { case displays, dashboards, activity }

    let model: CloudBrowseModel
    @Environment(CompanionPresentation.self) private var presentation
    @Environment(ConnectionHost.self) private var host
    @Environment(TesseraeMessageCenter.self) private var messageCenter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var tab: Tab = .displays
    @State private var activityPath: [UUID] = []
    @State private var feedbackScope = UUID()
    @State private var feedbackTasks: [UUID: Task<Void, Never>] = [:]

    private var context: CloudPresentationContext? {
        host.cloud === model && host.canUseCloudSubmissions ? host.cloudPresentationContext : nil
    }

    var body: some View {
        @Bindable var presentation = presentation
        TabView(selection: $tab) {
            CloudResourceList(model: model, isDevice: true, isActive: tab == .displays && presentation.sheet == nil,
                showResult: showActivity)
                .tabItem { Label("Displays", systemImage: "display").accessibilityIdentifier("cloud-displays-tab") }
                .tag(Tab.displays)
            CloudResourceList(model: model, isDevice: false, isActive: tab == .dashboards && presentation.sheet == nil,
                showResult: showActivity)
                .tabItem { Label("Dashboards", systemImage: "rectangle.stack").accessibilityIdentifier("cloud-pages-tab") }
                .tag(Tab.dashboards)
            activity
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath").accessibilityIdentifier("cloud-activity-tab") }
                .tag(Tab.activity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if horizontalSizeClass != .compact && canSend { TesseraeFloatingSendAction() }
        }
        .environment(\.tesseraePageSendEnabled, horizontalSizeClass == .compact && canSend)
        .sheet(item: $presentation.sheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView()
            case .send:
                if let context {
                    CloudSendSheet(model: model, context: context) { id in
                        sendAccepted(id, context: context)
                    }
                }
            case .uploads:
                EmptyView()
            }
        }
        .onChange(of: model.needsSignIn || model.isRestricted) { _, _ in
            Task { await host.cloudReadAccessChanged() }
        }
        .onChange(of: context) { _, _ in resetActivityPresentation() }
        .onDisappear(perform: resetActivityPresentation)
        .task { if model.snapshot == nil { await model.refresh() } }
    }

    @ViewBuilder private var activity: some View {
        if let context {
            CloudSubmissionActivity(context: context, tenant: model.snapshot?.account.tenant.name,
                isActive: tab == .activity && presentation.sheet == nil, path: $activityPath)
                .id(context)
        } else {
            NavigationStack {
                ContentUnavailableView("Activity Unavailable", systemImage: "clock",
                    description: Text(model.problem ?? String(localized: "Connect to Tesserae Cloud to see your activity.")))
                    .tesseraeScreenBackground()
                    .toolbar { TesseraeRootToolbar { EmptyView() } }
                    .navigationTitle("Activity")
            }
        }
    }

    private var canSend: Bool {
        context != nil && !model.devices.isEmpty
            && model.snapshot?.account.auth.scopes.contains("app:send") == true
    }

    private var feedbackPrefix: String { "cloud-send-\(feedbackScope.uuidString)-" }

    private func showActivity(_ id: UUID) {
        guard context != nil else { return }
        activityPath = [id]
        tab = .activity
    }

    private func resetActivityPresentation() {
        feedbackTasks.values.forEach { $0.cancel() }
        feedbackTasks.removeAll()
        messageCenter.dismissMessages(startingWith: feedbackPrefix)
        activityPath = []
    }

    private func sendAccepted(_ id: UUID, context acceptedContext: CloudPresentationContext) {
        guard context == acceptedContext else { return }
        presentation.sheet = nil
        guard feedbackTasks[id] == nil else { return }
        let messageID = feedbackPrefix + id.uuidString
        messageCenter.post(.init(id: messageID, text: String(localized: "Sending…"),
            kind: .progress(fraction: nil), lifetime: .persistent, survivesPresentationChange: true,
            accessibilityIdentifier: "cloud-send-progress"))
        feedbackTasks[id] = Task {
            defer { if !Task.isCancelled { feedbackTasks[id] = nil } }
            do {
                let batch = try await host.waitForCloudResult(id, context: acceptedContext)
                guard !Task.isCancelled, context == acceptedContext else { return }
                let ready = batch.results.filter { $0.outcome.isCleanGenerated }.count
                if ready == batch.targets.count, let first = batch.targets.first {
                    let text = ready == 1 ? String(localized: "Photo ready for \(first.name)")
                        : String(localized: "Photo ready for \(ready) displays")
                    messageCenter.post(.init(id: messageID, text: text, kind: .success,
                        lifetime: .automatic(seconds: 4), survivesPresentationChange: true,
                        accessibilityIdentifier: "cloud-send-ready"))
                } else {
                    let text = ready == 0 ? String(localized: "Check this send")
                        : String(localized: "\(ready) of \(batch.targets.count) displays ready")
                    postResultLink(id, messageID: messageID, text: text, context: acceptedContext)
                }
            } catch {
                guard !Task.isCancelled, context == acceptedContext else { return }
                postResultLink(id, messageID: messageID, text: String(localized: "Check this send"), context: acceptedContext)
            }
        }
    }

    private func postResultLink(_ id: UUID, messageID: String, text: String, context acceptedContext: CloudPresentationContext) {
        messageCenter.post(.init(id: messageID, text: text, kind: .warning,
            lifetime: .automatic(seconds: 8), survivesPresentationChange: true, priority: .high,
            accessibilityIdentifier: "cloud-send-attention",
            action: .init(title: String(localized: "View")) {
                guard context == acceptedContext else { return }
                showActivity(id)
                messageCenter.dismiss(id: messageID)
            }))
    }
}

struct CloudAccountSettings: View {
    let model: CloudBrowseModel
    let onChooseConnection: () -> Void
    @Environment(ConnectionHost.self) private var host
    @State private var confirmsSignOut = false
    @State private var signOutContext: CloudPresentationContext?
    @State private var signingOut = false
    @State private var appleLink = CloudAppleAccountLinkModel()

    var body: some View {
        Form {
            if let problem = model.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if model.needsSignIn || model.isRestricted {
                        Button("Choose Connection", systemImage: "arrow.triangle.swap", action: onChooseConnection)
                    } else if let retryAfter = model.retryAfter {
                        TimelineView(.periodic(from: .now, by: 1)) { clock in
                            retryButton.disabled(clock.date < retryAfter)
                        }
                    } else {
                        retryButton
                    }
                }
            }

            if let account = model.snapshot?.account {
                Section("Account") {
                    LabeledContent("Email", value: account.user.email)
                        .accessibilityIdentifier("cloud-account-email")
                    LabeledContent("Workspace", value: account.tenant.name)
                        .accessibilityIdentifier("cloud-account-workspace")
                    LabeledContent("Role", value: String(localized: account.role == "owner" ? "Owner" : "Member"))
                    if let context = appleLinkContext { appleLinkRows(context) }
                }

                Section {
                    NavigationLink {
                        CloudUsageSettings(model: model)
                    } label: {
                        Label("Cloud Usage & Features", systemImage: "chart.bar")
                    }
                    Link(destination: accountWebURL) {
                        Label("Cloud Settings in Browser", systemImage: "safari")
                    }
                    Link(destination: AppConfiguration.cloudSetupURL(issuer: model.client.issuer)) {
                        Label("Set Up in Cloud", systemImage: "display")
                    }
                }
            } else if model.problem == nil {
                Section {
                    ProgressView("Loading Cloud…")
                }
            }

            Section {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    guard host.cloud === model, let context = host.cloudPresentationContext else { return }
                    signOutContext = context
                    confirmsSignOut = true
                }
                .accessibilityIdentifier("cloud-sign-out")
                .disabled(signingOut || host.isSwitching || host.isSigningIn)
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .tesseraeScreenBackground()
        .navigationTitle("Cloud Account")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appleLinkContext) {
            appleLink.reset()
            guard let context = appleLinkContext else { return }
            await appleLink.check(model.client, isCurrent: appleLinkValidity(context))
        }
        .onDisappear { appleLink.reset() }
        .alert("Sign Out of Cloud?", isPresented: $confirmsSignOut, presenting: signOutContext) { context in
            Button("Sign Out", role: .destructive) { signOut(context) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You’ll need to sign in again to use this Cloud connection on this device.")
        }
    }

    private var retryButton: some View {
        Button("Retry", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            .disabled(model.isLoading)
    }

    private var appleLinkContext: CloudPresentationContext? {
        guard host.cloud === model, model.snapshot != nil, !model.needsSignIn, !model.isRestricted,
              CloudOAuthClient.supportsAppleSignIn(issuer: model.client.issuer) else { return nil }
        return host.cloudPresentationContext
    }

    private func appleLinkValidity(_ context: CloudPresentationContext) -> @MainActor () -> Bool {
        { [host, model] in
            host.cloudPresentationContext == context && host.cloud === model && !model.needsSignIn && !model.isRestricted
        }
    }

    @ViewBuilder
    private func appleLinkRows(_ context: CloudPresentationContext) -> some View {
        if appleLink.isLinked == true {
            LabeledContent {
                Text("Linked").foregroundStyle(.secondary)
            } label: {
                Label("Apple", systemImage: "apple.logo")
            }
            .accessibilityIdentifier("cloud-apple-linked")
        } else if appleLink.isLinked == false {
            Button {
                Task { await appleLink.link(model.client, isCurrent: appleLinkValidity(context)) }
            } label: {
                HStack {
                    Label("Link Apple account", systemImage: "apple.logo")
                    if appleLink.isBusy {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .disabled(appleLink.isBusy || signingOut || host.isSwitching || host.isSigningIn)
            .accessibilityValue(appleLink.isBusy ? Text("Linking Apple account…") : Text(""))
            .accessibilityIdentifier("cloud-apple-link")
        } else if appleLink.isBusy {
            LabeledContent {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
                    .accessibilityHidden(true)
            } label: {
                Label("Apple", systemImage: "apple.logo")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Checking Apple account…")
            .accessibilityIdentifier("cloud-apple-checking")
        } else if appleLink.problem != nil {
            Button("Check Apple account status", systemImage: "arrow.clockwise") {
                Task { await appleLink.check(model.client, isCurrent: appleLinkValidity(context)) }
            }
            .disabled(appleLink.isBusy)
        }
        if let problem = appleLink.problem {
            Text(problem).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var accountWebURL: URL {
        var url = URLComponents(url: model.client.issuer.appending(path: "app/"), resolvingAgainstBaseURL: false)
        url?.fragment = "/settings/account"
        return url?.url ?? model.client.issuer
    }

    private func signOut(_ context: CloudPresentationContext) {
        signingOut = true
        Task {
            await host.signOut(expectedCloud: context)
            signingOut = false
        }
    }
}

private struct CloudUsageSettings: View {
    let model: CloudBrowseModel

    var body: some View {
        Form {
            if model.isLoading || model.problem != nil || model.fetchedAt != nil {
                Section {
                    if model.isLoading {
                        ProgressView("Updating Usage…")
                    } else if let problem = model.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    if let updated = model.fetchedAt {
                        Text("Last updated: \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("cloud-usage-updated")
                    }
                }
            }
            if let account = model.snapshot?.account {
                Section("Workspace Usage") {
                    quotaRow("Displays", used: Double(account.usage.devices), limit: "devices", in: account)
                    quotaRow("Dashboards", used: Double(account.usage.pages), limit: "pages", in: account)
                    quotaRow("Storage", used: account.usage.storageBytes / 1_048_576, limit: "storage_mb", in: account,
                             unit: .mebibytes)
                }
                Section {
                    quotaRow("Renders Toward Limit", used: Double(account.usage.rendersChargedToday),
                             limit: "renders_per_day", in: account)
                    quotaRow("MCP Calls", used: Double(account.usage.mcpCallsToday), limit: "mcp_calls_per_day", in: account)
                    quotaRow("Web Render Time", used: account.usage.browserMillisecondsToday / 1_000,
                             limit: "render_seconds_per_day", in: account, unit: .seconds)
                    LabeledContent("Total Renders", value: account.usage.rendersToday.formatted())
                } header: {
                    if let updated = model.fetchedAt {
                        Text("Daily Usage · \(updated.formatted(Self.utcDayFormat)) UTC")
                    } else {
                        Text("Daily Usage")
                    }
                } footer: {
                    Text("Daily limits reset at midnight UTC. Total renders also include automatic display renders.")
                }

                let limits = account.limits.keys.sorted().filter { CloudSettingsLabels.limit($0) != nil }
                let features = account.features.keys.sorted().filter { CloudSettingsLabels.feature($0) != nil }
                if !limits.isEmpty {
                    Section {
                        DisclosureGroup("Limits") {
                            ForEach(limits, id: \.self) { key in
                                if let title = CloudSettingsLabels.limit(key) {
                                    LabeledContent(title, value: account.limits[key].flatMap { $0 }?.formatted()
                                        ?? String(localized: key == "min_wake_s" ? "No Additional Minimum" : "Unlimited"))
                                        .accessibilityIdentifier("cloud-limit-\(key)")
                                }
                            }
                        }
                    }
                }
                if !features.isEmpty {
                    Section {
                        DisclosureGroup("Features") {
                            ForEach(features, id: \.self) { key in
                                if let title = CloudSettingsLabels.feature(key) {
                                    LabeledContent(title, value: account.features[key] == true
                                        ? String(localized: "Available") : String(localized: "Unavailable"))
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .tesseraeScreenBackground()
        .navigationTitle("Cloud Usage & Features")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            TesseraeToolbarActions {
                if let retryAfter = model.retryAfter {
                    TimelineView(.periodic(from: .now, by: 1)) { clock in
                        refreshButton.disabled(clock.date < retryAfter)
                    }
                } else {
                    refreshButton
                }
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }

    private var refreshButton: some View {
        Button("Refresh Usage", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            .disabled(model.isLoading)
            .accessibilityIdentifier("cloud-usage-refresh")
    }

    private enum QuotaUnit {
        case count, mebibytes, seconds

        func format(_ amount: Double) -> String {
            let number = amount.formatted(.number.precision(.fractionLength(0...2)))
            let value = amount > 0 && amount < 0.01
                ? String(localized: "Less than \(0.01.formatted())")
                : number
            switch self {
            case .count: return value
            case .mebibytes: return String(localized: "\(value) MiB")
            case .seconds: return String(localized: "\(value) s")
            }
        }
    }

    private func quotaRow(_ title: LocalizedStringKey, used amount: Double, limit key: String,
                          in account: CloudAccount, unit: QuotaUnit = .count) -> some View {
        let used = unit.format(amount)
        let value: String
        let spokenValue: String
        switch account.limits[key] {
        case .some(.some(let amount)):
            let limit = unit.format(amount)
            value = "\(used) / \(limit)"
            spokenValue = String(localized: "\(used) used out of \(limit)")
        case .some(.none):
            value = String(localized: "\(used) · Unlimited")
            spokenValue = String(localized: "\(used) used, no limit")
        case .none:
            value = used
            spokenValue = String(localized: "\(used) used")
        }
        return LabeledContent {
            Text(value).monospacedDigit()
                .accessibilityLabel(spokenValue)
        } label: {
            Text(title)
        }
        .accessibilityIdentifier("cloud-usage-\(key)")
    }

    private static var utcDayFormat: Date.FormatStyle {
        var format = Date.FormatStyle().month(.abbreviated).day()
        format.timeZone = .gmt
        return format
    }
}

private enum CloudSettingsLabels {
    static func limit(_ key: String) -> String? {
        switch key {
        case "web_pages": String(localized: "Web Pages")
        case "fonts_per_day": String(localized: "Daily Fonts")
        case "agent_messages_per_day": String(localized: "Daily Agent Messages")
        case "agent_credits_per_month": String(localized: "Monthly Agent Credits")
        case "min_wake_s": String(localized: "Plan Minimum Wake Interval (seconds)")
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
