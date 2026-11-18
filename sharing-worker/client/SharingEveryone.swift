import Foundation
import Combine

struct SharingProjectionSnapshot {
    let observations: [SharingProjectionObservation]
    let checkedAt: Date?
    let snapshotAt: Date?
    let heartbeat: Date?
    let methodId: String
    var calendar: Calendar = .current
}

@MainActor final class SharingEveryoneModel: ObservableObject {
    @Published private(set) var cells: [SharingPublicCell] = []
    @Published private(set) var status = "No beta destination is enabled."
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var busy = false
    @Published private(set) var projectionPoints: [SharingProjectionPoint] = []
    @Published private(set) var projectionStatus = "Choose one model, tier, effort and region to request a local hypothetical projection."
    @Published private(set) var projectionBusy = false
    private let projectionProvider: (() async -> SharingProjectionSnapshot?)?
    private var projectionEvidenceDates: [Date] = []
    private var projectionGeneration = 0
    private var computationTask: Task<Result<[SharingProjectionPoint], SharingProjectionBlock>, Never>?
    private var projectionTask: Task<SharingProjectionSnapshot?, Never>?
    let available: Bool
    private let transport: SharingHTTPTransport
    private let clock: () -> Date
    private var viewingAccount: SharingAccount = .unknown
    private var permissionObserver: AnyCancellable?
    private var generation = 0
    private var loadingTask: Task<[SharingPublicCell], Error>?
    init(policy: SharingTransportPolicy = .disabled, configuration: URLSessionConfiguration = .ephemeral, clock: @escaping () -> Date = Date.init, projectionProvider: (() async -> SharingProjectionSnapshot?)? = nil) {
        if case .reviewedEndpoint = policy { available = true } else { available = false }
        transport = SharingHTTPTransport(policy: policy, configuration: configuration)
        self.clock = clock
        self.projectionProvider = projectionProvider
        if available { status = "Choose your account type, then refresh published results." }
    }
    func chooseAccount(_ account: SharingAccount, onboarding: SharingOnboarding) {
        viewingAccount = account; clear()
        if account != .personal, onboarding.session != nil { onboarding.stop() }
    }
    func observePermission(from onboarding: SharingOnboarding) {
        permissionObserver = onboarding.$canViewPersonal.sink { [weak self] allowed in
            guard let self, !allowed, self.viewingAccount == .personal else { return }
            self.clear(); self.status = "Personal viewing paused because sharing consent ended."
        }
    }
    static func canDisplay(account: SharingAccount, personalPermission: Bool) -> Bool {
        account == .workOrSchool || (account == .personal && personalPermission)
    }
    func refresh(account: SharingAccount, personalConsent: @escaping () -> Bool) async {
        guard available, !busy else { return }
        viewingAccount = account
        guard account == .workOrSchool || (account == .personal && personalConsent()) else {
            clear(); status = "Personal accounts require an active sharing consent. Work/school accounts can view without uploading."; return
        }
        clearProjection()
        busy = true; generation += 1; let token = generation
        defer { if token == generation { busy = false; loadingTask = nil } }
        do {
            let load = Task { @MainActor in
                let config = try await transport.configuration(now: clock())
                try Task.checkCancellation()
                guard token == generation, account == .workOrSchool || personalConsent() else { throw CancellationError() }
                return try await transport.snapshot(config: config, now: clock())
            }
            loadingTask = load
            let result = try await load.value
            guard token == generation else { return }
            guard account == .workOrSchool || personalConsent() else { clear(); status = "Personal viewing paused because sharing consent ended."; return }
            cells = result; fetchedAt = clock()
            status = result.isEmpty ? "No published comparisons. The server may not yet have enough eligible contributors." : "Published comparisons loaded."
        } catch {
            guard token == generation else { return }
            cells = []; fetchedAt = nil
            status = "Published comparisons unavailable. No partial or cached result is shown."
        }
    }
    func isStale(at now: Date) -> Bool { fetchedAt.map { now.timeIntervalSince($0) > 300 || now < $0 } ?? false }
    func clear() {
        clearProjection()
        generation += 1; loadingTask?.cancel(); loadingTask = nil; transport.cancelAll(); cells = []; fetchedAt = nil; busy = false
        status = available ? "Results cleared. Refresh to load published comparisons." : "No beta destination is enabled."
    }
    func isProjectionFresh(at now: Date) -> Bool {
        guard !projectionPoints.isEmpty, fetchedAt != nil, projectionEvidenceDates.count == 3, !isStale(at:now) else { return false }
        return projectionEvidenceDates.allSatisfy { now.timeIntervalSince($0).isFinite && now >= $0 && now.timeIntervalSince($0) <= 120 } &&
            projectionPoints.allSatisfy { now.timeIntervalSince1970 < Double($0.windowStart + SharingMethod.windowMS)/1000 + 86400 }
    }
    func clearProjection() {
        projectionGeneration += 1; projectionTask?.cancel(); projectionTask = nil; computationTask?.cancel(); computationTask = nil
        projectionPoints = []; projectionEvidenceDates = []; projectionBusy = false
        projectionStatus = "Projection cleared. Request again for the selected inputs."
    }
    func project(account: SharingAccount, personalConsent: @escaping () -> Bool,
                 model: String, region: String, tier: String, effort: String) async {
        clearProjection()
        guard available, account == .personal, personalConsent(), !busy,
              let projectionProvider else { projectionStatus = "A local projection requires an enabled destination and active personal consent."; return }
        guard !model.isEmpty, !region.isEmpty, ["standard","fast","ultrafast"].contains(tier),
              SharingMethod.exactEfforts.contains(effort), fetchedAt != nil, !isStale(at:clock()) else {
            projectionStatus = "Refresh and select one model, tier, effort and region."; return
        }
        let selected = Self.visible(cells,now:clock(),model:model,region:region,tier:tier,effort:effort)
        guard !selected.isEmpty, selected.count <= 48,
              Set(selected.map(\.windowStart)).count == selected.count else { projectionStatus = "No bounded, unique published series matches this selection."; return }
        viewingAccount = .personal
        let token = projectionGeneration
        projectionBusy = true; projectionStatus = "Checking the matching local baseline."
        defer { if token == projectionGeneration { projectionBusy = false; projectionTask = nil; computationTask = nil } }
        let task = Task { @MainActor in await projectionProvider() }
        projectionTask = task
        let snapshot = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard token == projectionGeneration, !Task.isCancelled, !task.isCancelled else { return }
        guard personalConsent(), viewingAccount == .personal else { clearProjection(); return }
        let now = clock()
        guard !isStale(at:now), let snapshot, snapshot.methodId == SharingMethod.id,
              snapshot.observations.count <= 50_000,
              SharingFreshDraft(checkedAt:snapshot.checkedAt,snapshotAt:snapshot.snapshotAt,heartbeat:snapshot.heartbeat,draft:nil)
                .isFresh(window:selected[0].windowStart,now:now),
              Self.visible(selected,now:now).count == selected.count else {
            projectionStatus = "Fresh, compatible local evidence is unavailable. Projection withheld."; return
        }
        let computation = Task.detached { () -> Result<[SharingProjectionPoint], SharingProjectionBlock> in
            var points: [SharingProjectionPoint] = []
            for cell in selected.reversed() {
                guard !Task.isCancelled else { return .failure(.incompatible) }
                let baseline = SharingProjection.makeBaseline(observations:snapshot.observations,windowStart:cell.windowStart,
                    model:model,tier:tier,effort:effort,calendar:snapshot.calendar)
                switch SharingProjection.calculate(SharingProjectionEvidence(cell:cell,exactEffort:effort,source:.effortStratifiedV2),baseline:baseline) {
                case .success(let point): points.append(point)
                case .failure(let reason): return .failure(reason)
                }
            }
            guard SharingProjection.coherent(points) else { return .failure(.incompatible) }
            return .success(points)
        }
        computationTask = computation
        let outcome = await withTaskCancellationHandler(operation: { await computation.value }, onCancel: { computation.cancel() })
        guard token == projectionGeneration, !Task.isCancelled, !computation.isCancelled else { return }
        guard personalConsent(), viewingAccount == .personal else { clearProjection(); return }
        let finishedAt = clock()
        guard !isStale(at:finishedAt),
              SharingFreshDraft(checkedAt:snapshot.checkedAt,snapshotAt:snapshot.snapshotAt,heartbeat:snapshot.heartbeat,draft:nil)
                .isFresh(window:selected[0].windowStart,now:finishedAt),
              Self.visible(selected,now:finishedAt).count == selected.count else {
            projectionStatus = "Local evidence expired while calculating. Projection withheld."; return
        }
        let points: [SharingProjectionPoint]
        switch outcome {
        case .success(let calculated): points = calculated
        case .failure(let reason): projectionStatus = reason.rawValue; return
        }
        projectionEvidenceDates = [snapshot.checkedAt!, snapshot.snapshotAt!, snapshot.heartbeat!]
        projectionPoints = points
        projectionStatus = "Hypothetical projection using your matching local usual speed. Not observed speed or a prediction."
    }
    // Never infer a personal token speed, a median token speed, or a confidence
    // interval by multiplying this median of member-relative ratios by local data.
    static func relativeLabel(_ ratio: Double) -> String {
        guard ratio.isFinite, (0.3...3).contains(ratio) else { return "Unavailable" }
        let percent = (ratio - 1) * 100
        return abs(percent) < 0.5 ? "Near contributors’ usual" : String(format: "%+.0f%% vs contributors’ usual", percent)
    }
    static func visible(_ cells: [SharingPublicCell], now: Date, model: String = "", region: String = "", tier: String = "", effort: String = "") -> [SharingPublicCell] {
        cells.filter { cell in
            cell.methodId == SharingMethod.id && SharingMethod.exactEfforts.contains(cell.exactEffort) && cell.median.isFinite && (0.3...3).contains(cell.median) &&
            cell.windowStart >= 0 && cell.windowStart < Int64.max - SharingMethod.windowMS - SharingMethod.graceMS &&
            Double(cell.windowStart + SharingMethod.windowMS + SharingMethod.graceMS)/1000 <= now.timeIntervalSince1970 &&
            now.timeIntervalSince1970 < Double(cell.windowStart + SharingMethod.windowMS)/1000 + 86400 &&
            (model.isEmpty || model == cell.model) && (region.isEmpty || region == cell.region) && (tier.isEmpty || tier == cell.tier) && (effort.isEmpty || effort == cell.exactEffort)
        }.sorted { ($0.windowStart, $0.model, $0.region, $0.tier, $0.exactEffort) > ($1.windowStart, $1.model, $1.region, $1.tier, $1.exactEffort) }
    }
}
