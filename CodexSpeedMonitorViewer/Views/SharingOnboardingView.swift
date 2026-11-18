import SwiftUI

// No endpoint is configured in the app. This form is inert until a reviewed
// coordinator is deliberately supplied; credentials are never saved by SwiftUI.
struct SharingOnboardingView: View {
    @ObservedObject var onboarding: SharingOnboarding
    @State private var account: SharingAccount = .unknown
    @State private var region = ""
    @State private var reviewed = false
    @State private var invite = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Beta connection").font(.headline)
            Text(onboarding.destination).textSelection(.enabled)
                .accessibilityLabel("Reviewed destination: \(onboarding.destination)")
            Text(onboarding.status).font(.callout).accessibilityLabel("Connection status: \(onboarding.status)")
            Button("Check beta configuration") { Task { await onboarding.checkConfiguration() } }
                .disabled(!onboarding.available || onboarding.busy || onboarding.session != nil)
                .help("Fetch public configuration only. Does not send an invite or usage data.")
            Picker("Account type", selection: $account) {
                Text("Choose account type").tag(SharingAccount.unknown)
                Text("Personal").tag(SharingAccount.personal)
                Text("Work or school: viewing only").tag(SharingAccount.workOrSchool)
            }
            Picker("Broad region", selection: $region) {
                Text("Choose region").tag("")
                Text("Americas").tag("americas")
                Text("Europe").tag("europe")
                Text("Asia-Pacific").tag("asia-pacific")
            }
            SecureField("Beta invite", text: $invite)
                .disabled(!onboarding.canReviewConsent)
                .accessibilityLabel("Beta invite credential")
                .help(SharingSetupPresentation(available: onboarding.available, active: onboarding.session?.active == true, hasSession: onboarding.session != nil).inviteHelp)
            Text("Provisional method: \(SharingMethod.id). Share UTC half-hour timestamps, random IDs, broad region, app version and model/tier/exact-effort generating-speed ratios. Exact effort adds a finer public activity dimension and may increase linkability. Cloudflare would receive your IP address. Aggregate retention targets 24 hours; cleanup may be delayed and provider logs/backups may last longer. Stopping cannot retract data already sent. Sharing status keeps up to 50 recent attempts in memory, including the shared comparison fields and delivery status, but no invite or request IDs. It is not saved to disk and clears on app restart; closing setup may retain it. Review Sharing details and Provisional method before enabling.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("I reviewed these details and consent to sharing from my personal account", isOn: $reviewed)
                .toggleStyle(.checkbox).disabled(!onboarding.canReviewConsent)
            HStack {
                Button("Stop and clear invite") { invite = ""; reviewed = false; onboarding.stop() }
                    .disabled(onboarding.session == nil && invite.isEmpty && !onboarding.busy)
                Spacer()
                Button("Enable reviewed beta") {
                    onboarding.approve(account: account, region: region, reviewed: reviewed, invite: invite)
                    invite = "" // Best effort: Swift strings/URLSession copies cannot promise secure zeroization.
                }
                .disabled(!onboarding.canReviewConsent || !reviewed || account != .personal || region.isEmpty || invite.isEmpty)
            }
        }
        .onChange(of: account) { reviewed = false; invite = ""; if onboarding.session != nil { onboarding.selectionChanged() } }
        .onChange(of: region) { reviewed = false; invite = ""; if onboarding.session != nil { onboarding.selectionChanged() } }
        .onChange(of: reviewed) { if !reviewed && onboarding.session != nil { invite = ""; onboarding.selectionChanged() } }
        .onDisappear { invite = "" } // Tab navigation clears input; outer sheet disappearance stops sharing.
    }
}
