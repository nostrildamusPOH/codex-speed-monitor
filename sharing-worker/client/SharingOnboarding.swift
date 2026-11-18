import Foundation
import Combine

// Operational freshness gate, separate from the immutable estimator. Fail closed
// if the read, copied snapshot or producer heartbeat is missing/stale/pre-window.
struct SharingFreshDraft {
    let checkedAt: Date?
    let snapshotAt: Date?
    let heartbeat: Date?
    let draft: SharingMeasurementDraft?
    func isFresh(window: Int64, now: Date) -> Bool {
        let end = Double(window + SharingMethod.windowMS) / 1000
        return [checkedAt, snapshotAt, heartbeat].allSatisfy { stamp in
            guard let stamp else { return false }
            let age = now.timeIntervalSince(stamp)
            return age.isFinite && age >= 0 && age <= 120 && stamp.timeIntervalSince1970 >= end
        }
    }
}

// Staged integration scaffold. No endpoint is supplied by the application.
// Configuration is public; invite credentials are scoped to POST /records only.
// No credential, config error body or raw telemetry is logged or archived.
// Narrow shared fields may appear in the explicitly bounded in-memory attempt view.
@MainActor final class SharingOnboarding: ObservableObject {
    @Published private(set) var status = "Beta connection is disabled in this build."
    @Published private(set) var config: SharingConfig?
    @Published private(set) var session: SharingAppSession?
    @Published private(set) var busy = false
    @Published private(set) var canViewPersonal = false
    private var viewingObserver: AnyCancellable?
    let uploadHistory = SharingUploadHistory()
    let policy: SharingTransportPolicy
    private let version: String
    private let clock: () -> Date
    private let httpConfiguration: URLSessionConfiguration
    private let makeController: (Date) throws -> SharingOfflineController
    private var connection: SharingConnection?
    private var uploader: SharingHTTPTransport?
    private var generation = 0
    init(policy: SharingTransportPolicy = .disabled, appVersion: String = "0.0.0",
         httpConfiguration: URLSessionConfiguration = .ephemeral,
         clock: @escaping () -> Date = Date.init,
         makeController: @escaping (Date) throws -> SharingOfflineController = { _ in throw SharingProblem.unavailable }) {
        self.policy = policy; version = appVersion; self.httpConfiguration = httpConfiguration
        self.clock = clock; self.makeController = makeController
        if case .reviewedEndpoint = policy { status = "Check beta configuration before reviewing consent." }
    }
    var available: Bool { if case .reviewedEndpoint = policy { return true }; return false }
    var destination: String {
        if case let .reviewedEndpoint(url) = policy { return url.host ?? "Invalid destination" }
        return "No reviewed beta destination"
    }
    var canReviewConsent: Bool { available && !busy && session == nil && config?.usable(at: clock()) == true }
    // Invoke only from an explicit check-setup action. This sends no invite or usage data.
    func checkConfiguration() async {
        guard available, !busy, session == nil else { return }
        busy = true; generation += 1; let token = generation
        defer { if token == generation { busy = false } }
        let transport = SharingHTTPTransport(policy: policy, configuration: httpConfiguration)
        defer { transport.cancelAll() }
        do {
            let fresh = try await transport.configuration(now: clock())
            guard token == generation else { return }
            guard fresh.usable(at: clock()), SharingClientState.atLeast(version, fresh.minAppVersion) else {
                config = nil; status = "Beta unavailable or app update required."; return
            }
            config = fresh; status = "Review the destination, provisional method and sharing details before opting in."
        } catch {
            guard token == generation else { return }
            config = nil; status = "Could not verify compatible beta configuration. Nothing enabled."
        }
    }
    // This call is the explicit consent boundary. The caller clears its SecureField
    // immediately afterward. Memory copies cannot be guaranteed to be zeroized.
    func approve(account: SharingAccount, region: String, reviewed: Bool, invite: String) {
        guard canReviewConsent, reviewed, account == .personal, let config,
              config.regions.contains(region) else { status = "Personal-account consent and a valid region are required."; return }
        let candidate = SharingHTTPTransport(policy: policy, inviteCredential: invite, configuration: httpConfiguration)
        do {
            try candidate.validateUploadAuthorization() // before opening/creating local state
            let controller = try makeController(clock())
            let local = SharingAppSession(preparationEnabled: true, controller: controller)
            local.start(account: account, region: region, reviewed: reviewed)
            guard local.active else { candidate.discardInvite(); status = "Could not save consent. Sharing remains paused."; return }
            uploader = candidate
            connection = SharingConnection(controller: controller, transport: candidate, clock: clock, history: uploadHistory, destination: destination)
            session = local
            viewingObserver = local.$active.combineLatest(controller.$sessionActive).sink { [weak self] active, authorized in
                self?.canViewPersonal = active && authorized
            }
            status = "Consent saved for this session. A new eligible record may be sent to the reviewed destination."
        } catch {
            candidate.discardInvite(); status = "Invite format or local state unavailable. Nothing enabled."
        }
    }
    // Called by a future reviewed live lifecycle, not by the currently disabled app.
    // Refresh config on each eligible run; no telemetry provider is called first.
    func prepareAndSend(_ prepare: (Date, Date, Set<String>) async -> SharingFreshDraft?) async {
        guard available, !busy, let session, let connection, let uploader else { return }
        busy = true; let token = generation
        defer { if token == generation { busy = false } }
        do {
            try connection.controller.expireQueued(at: clock())
            guard session.active, connection.controller.sessionActive else { return }
            guard SharingClientState.completedWindow(at: clock()) != nil else {
                status = "Waiting for the next completed half-hour. Nothing sent."; return
            }
            let state = connection.controller.state
            if state.accepted { status = "Accepted for this window"; return }
            if state.pending != nil && (state.attempts >= 5 || clock() < state.nextAttemptAt) { return }
            let fresh = try await uploader.configuration(now: clock())
            guard token == generation else { return }
            config = fresh
            var draft: SharingMeasurementDraft?
            var missingFreshInput = false
            if session.needsFreshPreparation(now: clock(), appVersion: version, config: fresh),
               let window = SharingClientState.completedWindow(at: clock()) {
                let input = await prepare(Date(timeIntervalSince1970: Double(window) / 1000), clock(), fresh.models)
                guard token == generation, !Task.isCancelled else { return }
                if let input, input.isFresh(window: window, now: clock()),
                   SharingClientState.completedWindow(at: clock()) == window {
                    draft = input.draft
                } else { missingFreshInput = true }
            }
            session.tick(now: clock(), appVersion: version, config: fresh, prepare: { _,_,_ in draft })
            guard session.active else { status = session.status; return }
            guard connection.controller.state.pending != nil else {
                status = missingFreshInput ? "Fresh post-window telemetry is unavailable. Nothing prepared or sent." : session.status
                return
            }
            await connection.sendPending()
            guard token == generation else { return }
            status = connection.lastStatus
            // Reflect auth pauses immediately without reading telemetry again.
            if !connection.controller.sessionActive {
                session.tick(now: clock(), appVersion: version, config: nil, prepare: { _,_,_ in nil })
            }
        } catch SharingTransportError.methodChanged {
            guard token == generation else { return }
            stop()
            if !status.contains("Could not save") { status = "Method changed. Consent withdrawn; review setup again." }
        } catch {
            guard token == generation else { return }
            session.tick(now: clock(), appVersion: version, config: nil, prepare: { _,_,_ in nil })
            status = "Configuration or local state unavailable. Sharing paused; review setup again."
        }
    }
    func maintainLocalState() {
        guard let session, let connection else { return }
        do { try connection.controller.expireQueued(at: clock()) }
        catch { session.tick(now: clock(), appVersion: version, config: nil, prepare: { _,_,_ in nil }); status = "Local queue cleanup failed. Sharing paused." }
    }
    func stop() {
        generation += 1; busy = false; canViewPersonal = false
        viewingObserver?.cancel(); viewingObserver = nil
        connection?.cancelPendingAndDiscardInvite(); uploader?.discardInvite()
        let saved = session?.stop() ?? true
        status = saved ? "Stopped. Invite discarded and local queue cleared. Already-sent data cannot be recalled." : "Stopped in memory. Could not save queue cleanup; restart remains paused."
        connection = nil; uploader = nil; if saved { session = nil }; config = nil
    }
    // Account/region/review changes and cancelling onboarding withdraw this session.
    func selectionChanged() { stop() }
}
