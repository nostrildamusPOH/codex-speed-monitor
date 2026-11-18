import SwiftUI

// App lifecycle controls are connected, but production preparation and transport stay disabled.
enum SharingPreviewAccount: String, CaseIterable, Identifiable {
    case unknown = "Choose account type"
    case personal = "Personal"
    case workOrSchool = "Work or school"
    var id: String { rawValue }
}
enum SharingPreviewTab: String, CaseIterable, Identifiable {
    case setup = "Setup", everyone = "Everyone", invite = "Beta invite", details = "Sharing details", methodology = "Provisional method", activity = "Sharing status"
    var id: String { rawValue }
}
struct SharingSetupDraft {
    var account: SharingPreviewAccount = .unknown
    var region = "Choose region"
    var reviewed = false
    var tab: SharingPreviewTab = .setup
    // Hard-coded off. A UI selection or checkbox can never enable real sharing.
    var canStartSharing: Bool { false }
    var status: String {
        account == .workOrSchool
            ? "Work and school accounts will be viewing-only. Uploads stay off."
            : "Sharing is off. No sharing records are being created or sent."
    }
    mutating func selectRegion(_ value: String) {
        region = value
        reviewed = false
    }
    mutating func selectAccount(_ value: SharingPreviewAccount) {
        account = value
        reviewed = false
    }
}
struct SharingSetupPresentation {
    let available: Bool
    let active: Bool
    let hasSession: Bool
    var badge: String { !available ? "NOT CONNECTED" : (active ? "ACTIVE" : (hasSession ? "PAUSED" : "NOT SHARING")) }
    var introduction: String {
        available ? "Review the configured destination and sharing details in Beta invite. Explicit consent can save local state and enable eligible uploads. Closing setup stops sharing."
                  : "Setup preview only. No beta destination is enabled. These preview choices do not create sharing state or authorize uploads."
    }
    var footer: String { available ? "Closing setup stops sharing." : "No server connection in this build." }
    var inviteHelp: String { available ? "Memory only for this session. Enter only the invite for the reviewed destination; never paste it into chat." : "This disabled build cannot accept an invite. Do not paste credentials here." }
    var methodScope: String { available ? "After explicit consent, fresh authoritative local snapshots can be used to prepare eligible uploads." : "This disabled build does not read local history for sharing or prepare sharing records." }
    var activityTitle: String { available ? "Current sharing status" : "No sharing uploads enabled" }
    var activityBody: String { available ? "Shows up to 50 recent upload attempts in memory while this setup controller exists. Retries appear separately. Not saved to disk; history may remain when setup closes and is cleared on app restart or when sharing state is recreated. Stop does not clear this history or recall sent records." : "This build does not prepare or send sharing records. No live upload log is available." }
}
struct SharingSetupView: View {
    @State private var draft: SharingSetupDraft
    @StateObject private var onboarding: SharingOnboarding
    @StateObject private var everyone: SharingEveryoneModel
    let onClose: () -> Void
    init(initial: SharingSetupDraft = SharingSetupDraft(), onboarding: SharingOnboarding? = nil, httpConfiguration: URLSessionConfiguration = .ephemeral, projectionProvider: (() async -> SharingProjectionSnapshot?)? = nil, onClose: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        let owner = onboarding ?? SharingOnboarding()
        _onboarding = StateObject(wrappedValue: owner)
        let results = SharingEveryoneModel(policy: owner.policy, configuration: httpConfiguration, projectionProvider: projectionProvider)
        results.observePermission(from: owner)
        _everyone = StateObject(wrappedValue: results)
        self.onClose = onClose
    }
    private let accent = Color(red: 0.65, green: 0.55, blue: 0.95)
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Everyone").font(.system(size: 25, weight: .semibold))
                    Text("Compare generating speed with other sharing Macs.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(presentation.badge).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.white.opacity(0.07), in: Capsule())
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: onboarding.session?.active == true ? "checkmark.circle.fill" : "pause.circle.fill").foregroundStyle(accent).font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(onboarding.session != nil ? onboarding.status : (draft.account == .workOrSchool ? draft.status : onboarding.status)).font(.system(size: 13, weight: .medium))
                    Text(presentation.introduction)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            Picker("Sharing setup section", selection: $draft.tab) {
                ForEach(SharingPreviewTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    switch draft.tab {
                    case .setup: setup
                    case .everyone: SharingEveryoneView(model: everyone, onboarding: onboarding)
                    case .invite: SharingOnboardingView(onboarding: onboarding)
                    case .details: details
                    case .methodology: methodology
                    case .activity: activity
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2).padding(.trailing, 4)
            }
            Divider()
            HStack(spacing: 12) {
                Text(presentation.footer)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: closeSetup).keyboardShortcut(.cancelAction)
                Button("Stop", action: stopSharing).disabled(onboarding.session == nil && !onboarding.busy)
                Button("Beta invite") { draft.tab = .invite }
                    .help(onboarding.available ? "Review the configured beta destination and consent controls." : "This build has no enabled beta destination.")
            }
        }
        .padding(24).frame(width: 660, height: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .onChange(of: draft.account) { stopSharing() }
        .onChange(of: draft.region) { stopSharing() }
        .onChange(of: draft.reviewed) { if !draft.reviewed { stopSharing() } }
        .onDisappear(perform: stopSharing)
    }
    private var presentation: SharingSetupPresentation { SharingSetupPresentation(available: onboarding.available, active: onboarding.canViewPersonal, hasSession: onboarding.session != nil) }
    private func stopSharing() { everyone.clear(); SharingSetupActions.stop(onboarding: onboarding) }
    private func closeSetup() { stopSharing(); onClose() }
    private var account: SharingAccount { draft.account == .personal ? .personal : (draft.account == .workOrSchool ? .workOrSchool : .unknown) }
    private var region: String { ["Americas":"americas", "Europe":"europe", "Asia-Pacific":"asia-pacific"][draft.region] ?? "" }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before sharing").font(.headline)
            Picker("Account type", selection: Binding(get: { draft.account }, set: { draft.selectAccount($0) })) {
                ForEach(SharingPreviewAccount.allCases) { account in Text(account.rawValue).tag(account) }
            }.pickerStyle(.menu)
            if draft.account == .workOrSchool {
                note("Viewing only", "You will be able to view published comparisons without uploading work or school activity. No shared results are available in this build.")
            } else {
                Picker("Broad region", selection: Binding(get: { draft.region }, set: { draft.selectRegion($0) })) {
                    ForEach(["Choose region", "Americas", "Europe", "Asia-Pacific"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                Text("Region is your choice. This screen does not look up your location or account.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle("I have reviewed the provisional sharing details", isOn: $draft.reviewed)
                    .toggleStyle(.checkbox).font(.system(size: 13))
                Text(onboarding.available ? "This page is informational, not consent. Use Beta invite to verify the destination and explicitly opt in." : "This preview is not consent to upload. Sharing remains disabled.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            note("Community results", "Use Everyone to request published comparisons when a reviewed destination is enabled. Work and school accounts cannot upload. No sample results are presented as real community data.")
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 15) {
            note(onboarding.available ? "Shared record fields" : "Proposed shared fields", "One half-hour record containing its UTC window-start timestamp, a random record ID, random installation ID, broad region, app version, the immutable provisional method ID, and reviewed model/tier/exact-effort generating-speed ratios.")
            note("Kept out of sharing records", "Prompts, answers, thread and response IDs, file paths, email addresses, account identifiers and machine names are not part of the sharing format.")
            note("Publication and retention", "The prototype publishes a median only after five distinct admitted beta-member IDs contribute to a region/model/tier/exact-effort window, then removes active raw records after the five-minute upload allowance closes. Invites and IDs do not verify five distinct people. Public medians are retained in application storage for 24 hours after window closure; cleanup can be delayed. They cannot be retracted by stopping sharing.")
            note("Finer public groups", "Exact effort is now shared and published. Finer groups can increase linkability and leave fewer publishable windows. Thresholds never pool across efforts, tiers, models, regions or windows.")
            note("Provider and privacy limits", onboarding.available ? "The reviewed host receives connection metadata, including IP addresses, when contacted. Provider logs and backups may retain data beyond application deletion. This is not a guarantee of anonymity." : "Cloudflare is the planned host and would receive connection metadata, including IP addresses. Platform logs and backups may retain data beyond application deletion. This is not a guarantee of anonymity.")
            note("Beta invite", onboarding.available ? "An invite authorizes uploads for a stable beta-member ID. Enter it only in the Beta invite secure field after checking configuration. It is memory-only and discarded on Stop; changing installation IDs does not allow extra contributions." : "No invite destination is enabled. Do not paste credentials into this preview.")
            note("Stopping", onboarding.available ? "Stop or closing setup cancels new uploads, discards the invite and clears queued local records. Save failures are surfaced. Already-sent bytes and published medians cannot be recalled." : "Sharing is off in this preview. In an enabled session, Stop clears queued local records but cannot recall already-sent data.")
        }
    }
    private var methodology: some View {
        VStack(alignment: .leading, spacing: 15) {
            note("Provisional private-beta method", "Method: \(SharingMethod.id). \(presentation.methodScope)")
            note("Estimated generating speed", "Use output tokens divided by measured duration minus Codex-reported first-output wait. Never substitute whole-response speed when timing is missing.")
            note("Like-for-like history", "At least 10 replies with valid timing and 100+ output tokens each. Compare with the same model, verified exact effort, tier and clock interval over the prior 14 days. Use the median of daily pooled generating speeds from five or more days with at least three qualifying replies each. Omit mixed or unverified efforts.")
            note("Completed windows and upload allowance", "Observe complete UTC-aligned 30-minute intervals, then allow five minutes to upload or retry. Reject later submissions and publish after that allowance. \(onboarding.available ? "Automatic processing requires explicit consent." : "Automatic sharing is disabled in this build.")")
            note("Device-local baseline and version", "The reference uses the device-local calendar and timezone at calculation time. Travel or timezone changes can change the comparison. Intervals distorted by clock transitions are omitted. This method is versioned separately from the app; a changed method clears queued data and requires new consent.")
            note("Nothing to share is valid", "Missing history, unclear effort, invalid timing or ratios outside 0.3–3 mean no contribution, not a made-up normal speed. No methodology choice here enables sharing.")
        }
    }
    private var activity: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(presentation.activityTitle, systemImage: "tray").font(.headline)
            Text(presentation.activityBody)
                .font(.system(size: 13)).foregroundStyle(.secondary)
            SharingUploadHistoryView(history: onboarding.uploadHistory)
            Text("Your existing local speed history is separate and is not shown or exported here.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Stop sharing", action: stopSharing).disabled(onboarding.session == nil && !onboarding.busy)
            Text(onboarding.status).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// One action boundary for all outer Stop, Close, disappearance and selection paths.
@MainActor enum SharingSetupActions {
    static func stop(onboarding: SharingOnboarding) {
        onboarding.stop()
    }
}


private struct SharingUploadHistoryView: View {
    @ObservedObject var history: SharingUploadHistory
    private func utc(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if history.entries.isEmpty { Text("No upload attempts recorded in this setup view.").font(.caption) }
            ForEach(history.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(utc(entry.startedAt)).font(.caption).bold()
                    Text(entry.outcome).font(.caption)
                    Text("Destination: \(entry.destination)").font(.caption)
                    Text("Window starts \(utc(Date(timeIntervalSince1970: Double(entry.windowStart) / 1000))) · \(entry.region)").font(.caption)
                    ForEach(Array(entry.comparisons.enumerated()), id: \.offset) { _, comparison in
                        Text("\(comparison.model) · \(comparison.tier) · \(comparison.exactEffort) · \(comparison.ratio, specifier: "%.2f")×").font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("This local view omits invite credentials, request and installation IDs, and IP addresses. It is not a permanent audit log or proof of deletion on the server.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
