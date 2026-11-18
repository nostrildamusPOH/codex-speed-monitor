import SwiftUI

struct SharingEveryoneView: View {
    @ObservedObject var model: SharingEveryoneModel
    @ObservedObject var onboarding: SharingOnboarding
    @State private var account: SharingAccount = .unknown
    @State private var selectedModel = ""
    @State private var region = ""
    @State private var tier = ""
    @State private var effort = ""
    var fixture: [SharingPublicCell]? = nil // render-only synthetic injection; never supplied by app
    var fixtureNow: Date? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = fixtureNow ?? context.date
            let mayDisplay = fixture != nil || SharingEveryoneModel.canDisplay(account: account, personalPermission: onboarding.canViewPersonal)
            let all = mayDisplay ? SharingEveryoneModel.visible(fixture ?? model.cells, now: now) : []
            let rows = SharingEveryoneModel.visible(all, now: now, model: selectedModel, region: region, tier: tier, effort: effort)
            VStack(alignment: .leading, spacing: 12) {
                Text("Everyone · relative generating speed").font(.headline)
                Text("Provisional results browser. Choose one model, region, tier and exact effort to request a hypothetical projection using matching local history.").font(.caption).foregroundStyle(.secondary)
                if fixture != nil { Text("SYNTHETIC PREVIEW · NOT COMMUNITY DATA").font(.caption.bold()).foregroundStyle(.orange) }
                Text("Median of contributors’ ratios to their own comparable history. This is not your token speed, a median tokens/second rate, or a service-capacity measurement.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Viewing account", selection: $account) {
                    Text("Choose account type").tag(SharingAccount.unknown)
                    Text("Personal: sharing required").tag(SharingAccount.personal)
                    Text("Work/school: viewing only").tag(SharingAccount.workOrSchool)
                }
                HStack {
                    Button(model.busy ? "Loading…" : "Refresh results") {
                        Task { await model.refresh(account: account, personalConsent: { onboarding.canViewPersonal }) }
                    }.disabled(!model.available || model.busy || account == .unknown || (account == .personal && !onboarding.canViewPersonal))
                    if let fetched = model.fetchedAt { Text("Fetched \(fetched.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                }
                if model.isStale(at: now) { Text("This snapshot is over five minutes old or the clock changed. Refresh for current publications.").font(.caption).foregroundStyle(.orange) }
                Text(fixture == nil ? model.status : "Synthetic published ratios for layout testing only.").font(.caption).accessibilityLabel("Results status: \(model.status)")
                HStack {
                    Picker("Model", selection: $selectedModel) {
                        Text("All models").tag("")
                        ForEach(Array(Set(all.map(\.model))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Region", selection: $region) {
                        Text("All regions").tag("")
                        ForEach(["americas", "europe", "asia-pacific"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Tier", selection: $tier) {
                        Text("All tiers").tag("")
                        ForEach(["standard", "fast", "ultrafast"], id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Exact effort", selection: $effort) {
                    Text("All efforts").tag("")
                    ForEach(SharingMethod.exactEfforts.sorted(), id: \.self) { Text($0).tag($0) }
                }
                Text("This chart reads local history only when you request a projection with active personal sharing consent. Separately, enabled sharing reads local history automatically to prepare contributions. Chart baselines stay on this Mac and are not added to uploaded records.").font(.caption).foregroundStyle(.secondary)
                Button(model.projectionBusy ? "Preparing projection…" : "Project using my local history") {
                    Task { await model.project(account: account, personalConsent: { onboarding.canViewPersonal }, model: selectedModel, region: region, tier: tier, effort: effort) }
                }.disabled(!model.available || model.busy || model.projectionBusy || account != .personal || !onboarding.canViewPersonal || selectedModel.isEmpty || region.isEmpty || tier.isEmpty || effort.isEmpty || fixture != nil)
                Text(model.projectionStatus).font(.caption).foregroundStyle(.secondary)
                SharingProjectionView(points: mayDisplay && model.isProjectionFresh(at: now) ? model.projectionPoints : [], blocked: !model.projectionPoints.isEmpty && !model.isProjectionFresh(at: now) ? .staleEvidence : .missingBaseline)
                if rows.isEmpty { Text("No published comparison for this selection. Missing data is not normal speed.").font(.callout) }
                ForEach(Array(rows.prefix(200).enumerated()), id: \.offset) { _, cell in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cell.model + " · " + cell.tier + " · " + cell.exactEffort).font(.callout.weight(.semibold))
                            Spacer()
                            Text(SharingEveryoneModel.relativeLabel(cell.median)).font(.callout.weight(.medium))
                        }
                        Text("\(cell.region) · \(Self.windowLabel(cell.windowStart)) UTC").font(.caption).foregroundStyle(.secondary)
                    }.padding(10).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
                if rows.count > 200 { Text("Showing newest 200 comparisons. Narrow the filters to see older windows.").font(.caption) }
                Text("Publication requires at least five distinct admitted beta-member IDs, not five verified people. These are contributor-reported estimates. Exact counts and uncertainty are not supplied. Each published cell matches model, tier, exact effort, region and UTC window; fewer than five admitted members in that exact group produces no cell. Method: \(SharingMethod.id).")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Account selection is a UI rule, not identity verification or protection of the public snapshot endpoint. No local telemetry is needed to fetch these results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: account) { model.chooseAccount(account, onboarding: onboarding) }
        .onChange(of: onboarding.canViewPersonal) { _, active in if account == .personal && !active { model.clear() } }
        .onChange(of: selectedModel) { _,_ in model.clearProjection() }
        .onChange(of: region) { _,_ in model.clearProjection() }
        .onChange(of: tier) { _,_ in model.clearProjection() }
        .onChange(of: effort) { _,_ in model.clearProjection() }
        .onDisappear { model.clear() }
    }
    private static func windowLabel(_ milliseconds: Int64) -> String {
        let format = DateFormatter(); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "MMM d HH:mm"
        let start = Date(timeIntervalSince1970: Double(milliseconds)/1000)
        return format.string(from: start) + "–" + format.string(from: start.addingTimeInterval(1800))
    }
}
