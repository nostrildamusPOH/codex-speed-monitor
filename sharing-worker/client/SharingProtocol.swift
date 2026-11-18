import Foundation
import Combine

// Isolated client foundation, compiled for validation but not activated by the app.
// No database reads, networking, account lookup, or telemetry logging.
// File persistence is explicit through the caller-supplied SharingStateFile below.
enum SharingMethod {
    static let id = "generating-exact-effort-local-v2-provisional"
    static let exactEfforts: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static let windowMS: Int64 = 1_800_000
    static let graceMS: Int64 = 300_000
    static let lookbackDays = 14
    static let minimumCurrentReplies = 10
    static let minimumDayReplies = 3
    static let minimumBaselineDays = 5
    static let minimumOutputTokens: Int64 = 100
}
enum SharingAccount: String, Codable { case unknown, personal, workOrSchool }
struct SharingComparison: Codable, Equatable {
    let model: String
    let tier: String
    let ratio: Double
    let exactEffort: String
}
struct SharingRecord: Codable, Equatable {
    let id: String
    let installationId: String
    let windowStart: Int64
    let region: String
    let appVersion: String
    let comparisons: [SharingComparison]
    var methodId: String = SharingMethod.id

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
// A local narrow draft. Queueing still requires explicit current-method consent.
struct SharingMeasurementDraft {
    let methodId: String
    let windowStart: Int64
    let comparisons: [SharingComparison]
}
struct SharingConfig {
    let enabled: Bool
    let minAppVersion: String
    let models: Set<String>
    let regions: Set<String>
    let fetchedAt: Date
    var methodId: String = SharingMethod.id
    var exactEfforts: Set<String> = SharingMethod.exactEfforts
    var graceSeconds: Int = Int(SharingMethod.graceMS / 1000)
    func usable(at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return enabled && exactEfforts == SharingMethod.exactEfforts && methodId == SharingMethod.id && graceSeconds == Int(SharingMethod.graceMS / 1000) && age >= 0 && age <= 300
    }
}
enum SharingProblem: Error, Equatable {
    case consentRequired, viewingOnly, unavailable, invalidVersion, invalidComparison
    case invalidRegion, alreadySubmitted, invalidWindow, methodChanged
}
struct SharingAttempt {
    let id: String
    let body: Data
    let generation: Int
}
struct SharingClientState: Codable {
    static let windowMS: Int64 = SharingMethod.windowMS
    private(set) var account: SharingAccount = .unknown
    private(set) var consented = false
    private(set) var consentMethodId: String?
    private(set) var pending: SharingRecord?
    private(set) var accepted = false
    private(set) var attempts = 0
    private(set) var nextAttemptAt: Date = .distantPast
    private(set) var generation = 0
    private(set) var lastQueuedWindow: Int64?
    let installationId: String

    init(installationId: UUID = UUID()) {
        self.installationId = installationId.uuidString.lowercased()
    }
    init(migrating installationId: UUID, lastQueuedWindow: Int64?) {
        self.installationId = installationId.uuidString.lowercased()
        self.lastQueuedWindow = lastQueuedWindow
    }
    static func windowStart(at date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 1800)) * windowMS
    }
    static func completedWindow(at date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 1800, seconds < Double(Int64.max / 1000) else { return nil }
        let current = windowStart(at: date)
        guard seconds * 1000 < Double(current + SharingMethod.graceMS) else { return nil }
        return current - windowMS
    }
    mutating func checkMethod(_ config: SharingConfig) throws {
        guard config.exactEfforts == SharingMethod.exactEfforts, config.methodId == SharingMethod.id, config.graceSeconds == Int(SharingMethod.graceMS / 1000) else {
            stop(); throw SharingProblem.methodChanged
        }
    }
    // This is a product UI gate, not authentication or authorization of public GETs.
    var canViewEveryone: Bool { account == .workOrSchool || (account == .personal && consented) }
    mutating func setAccount(_ account: SharingAccount) {
        if account != self.account { stop(); self.account = account }
    }
    mutating func optIn() throws {
        guard account == .personal else { throw SharingProblem.viewingOnly }
        consented = true
        consentMethodId = SharingMethod.id
    }
    mutating func stop() {
        consented = false
        consentMethodId = nil
        pending = nil
        accepted = false
        attempts = 0
        nextAttemptAt = .distantPast
        generation += 1 // Invalidate results from an already-in-flight request.
        // Keep lastQueuedWindow to prevent a different payload in the same window.
    }
    mutating func expire(at now: Date) {
        if let pending, pending.windowStart != Self.completedWindow(at: now) {
            self.pending = nil
            accepted = false
            attempts = 0
            generation += 1
        }
    }
    mutating func queue(comparisons: [SharingComparison], region: String, appVersion: String,
                        config: SharingConfig, now: Date, windowStart: Int64? = nil) throws {
        try checkMethod(config)
        expire(at: now)
        guard account == .personal else { throw SharingProblem.viewingOnly }
        guard consented, consentMethodId == SharingMethod.id else { throw SharingProblem.consentRequired }
        guard config.usable(at: now) else { throw SharingProblem.unavailable }
        guard Self.atLeast(appVersion, config.minAppVersion) else { throw SharingProblem.invalidVersion }
        guard config.regions.contains(region) else { throw SharingProblem.invalidRegion }
        guard let eligible = Self.completedWindow(at: now), windowStart == nil || windowStart == eligible else { throw SharingProblem.invalidWindow }
        let window = windowStart ?? eligible
        guard lastQueuedWindow != window else { throw SharingProblem.alreadySubmitted }
        guard !comparisons.isEmpty, comparisons.count <= 12 else { throw SharingProblem.invalidComparison }
        var seen = Set<String>()
        for c in comparisons {
            guard config.models.contains(c.model), ["standard", "fast", "ultrafast"].contains(c.tier),
                  SharingMethod.exactEfforts.contains(c.exactEffort), c.ratio.isFinite, (0.3...3.0).contains(c.ratio),
                  seen.insert(c.model + "\u{0}" + c.tier).inserted else { throw SharingProblem.invalidComparison }
        }
        pending = SharingRecord(id: UUID().uuidString.lowercased(), installationId: installationId,
                                windowStart: window, region: region, appVersion: appVersion,
                                comparisons: comparisons.sorted { ($0.model, $0.tier) < ($1.model, $1.tier) })
        lastQueuedWindow = window
        accepted = false
        attempts = 0
        nextAttemptAt = now
        generation += 1
    }
    // Caller may inspect this body as the local upload preview. This method never sends it.
    mutating func beginAttempt(config: SharingConfig, now: Date) throws -> SharingAttempt? {
        try checkMethod(config)
        expire(at: now)
        guard consented, consentMethodId == SharingMethod.id, account == .personal, config.usable(at: now), let record = pending,
              !accepted, attempts < 5, now >= nextAttemptAt else { return nil }
        guard Self.atLeast(record.appVersion, config.minAppVersion), config.regions.contains(record.region),
              record.comparisons.allSatisfy({config.models.contains($0.model)}) else {
            pending = nil; generation += 1; return nil
        }
        attempts += 1
        nextAttemptAt = now.addingTimeInterval(min(300, 15 * pow(2, Double(attempts - 1))))
        return SharingAttempt(id: record.id, body: try record.encoded(), generation: generation)
    }
    mutating func finishAttempt(_ attempt: SharingAttempt, status: Int, now: Date) {
        expire(at: now)
        guard consented, account == .personal, attempt.generation == generation,
              pending?.id == attempt.id else { return }
        if status == 200 { accepted = true }
        else if [400, 409, 413, 415, 426].contains(status) { pending = nil; generation += 1 }
        // 429/5xx/network errors retain the exact body/ID for bounded backoff.
    }
    static func atLeast(_ version: String, _ minimum: String) -> Bool {
        func parts(_ value: String) -> [Int]? {
            let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
            let numbers = pieces.compactMap { Int($0) }
            return numbers.count == 3 ? numbers : nil
        }
        guard let a = parts(version), let b = parts(minimum) else { return false }
        for i in 0..<3 where a[i] != b[i] { return a[i] > b[i] }
        return true
    }
}


// The host decides where to store this local-only state. Tests use a temporary folder.
// Never call a transport until the queued state and attempt have been saved successfully.
enum SharingArchiveProblem: Error { case unsupportedVersion, invalidState, tooLarge }
struct SharingArchive: Codable {
    let version: Int
    let state: SharingClientState
}
struct SharingStateFile {
    let url: URL
    var privateDirectory = false
    private func checkLocation() throws {
        guard privateDirectory else { return }
        let fm = FileManager.default
        let parent = try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        guard parent[.type] as? FileAttributeType == .typeDirectory,
              (parent[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (parent[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw SharingArchiveProblem.invalidState }
        // attributesOfItem inspects the link itself; never load or overwrite a symlink.
        if let attrs = try? fm.attributesOfItem(atPath: url.path) {
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { throw SharingArchiveProblem.invalidState }
        }
    }
    func save(_ state: SharingClientState) throws {
        try checkLocation()
        try Self.check(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(SharingArchive(version: 3, state: state))
        guard bytes.count <= 65_536 else { throw SharingArchiveProblem.tooLarge }
        // Parent directory must already exist; do not invent an application location.
        try bytes.write(to: url, options: [.atomic])
        if privateDirectory {
            // New state is already inside the verified private 0700 directory.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try checkLocation()
        }
    }
    func load(now: Date) throws -> SharingClientState? {
        try checkLocation()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > 65_536 { throw SharingArchiveProblem.tooLarge }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 65_536 else { throw SharingArchiveProblem.tooLarge }
        // Decode only identity and the used-window guard from v2. Its pending payload
        // has no effort dimension and must never be relabeled or restored.
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: bytes).version
        if version == 2 {
            struct Legacy: Decodable {
                struct Identity: Decodable { let installationId: UUID; let lastQueuedWindow: Int64? }
                let state: Identity
            }
            let legacy = try JSONDecoder().decode(Legacy.self, from: bytes)
            let state = SharingClientState(migrating: legacy.state.installationId, lastQueuedWindow: legacy.state.lastQueuedWindow)
            try Self.check(state)
            try save(state)
            return state
        }
        guard version == 3 else { throw SharingArchiveProblem.unsupportedVersion }
        let archive = try JSONDecoder().decode(SharingArchive.self, from: bytes)
        guard archive.version == 3 else { throw SharingArchiveProblem.unsupportedVersion }
        try Self.check(archive.state)
        var state = archive.state
        state.expire(at: now)
        return state
    }
    private static func check(_ state: SharingClientState) throws {
        func validID(_ value: String) -> Bool {
            value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
        }
        guard validID(state.installationId), (0...5).contains(state.attempts),
              (0..<1_000_000_000).contains(state.generation),
              state.nextAttemptAt.timeIntervalSince1970.isFinite,
              !state.consented || (state.account == .personal && state.consentMethodId == SharingMethod.id),
              !state.accepted || state.pending != nil else { throw SharingArchiveProblem.invalidState }
        if let window = state.lastQueuedWindow {
            guard window >= 0, window % SharingClientState.windowMS == 0 else { throw SharingArchiveProblem.invalidState }
        }
        if let record = state.pending {
            guard state.consented, state.account == .personal,
                  record.installationId == state.installationId, record.methodId == SharingMethod.id, validID(record.id),
                  record.windowStart == state.lastQueuedWindow,
                  SharingClientState.atLeast(record.appVersion, "0.0.0"),
                  !record.region.isEmpty, record.region.utf8.count <= 64,
                  !record.comparisons.isEmpty, record.comparisons.count <= 12,
                  try record.encoded().count <= 8192 else { throw SharingArchiveProblem.invalidState }
            var seen = Set<String>()
            for c in record.comparisons {
                guard !c.model.isEmpty, c.model.utf8.count <= 128,
                      ["standard", "fast", "ultrafast"].contains(c.tier),
                      SharingMethod.exactEfforts.contains(c.exactEffort), c.ratio.isFinite, (0.3...3.0).contains(c.ratio),
                      seen.insert(c.model + "\u{0}" + c.tier).inserted else { throw SharingArchiveProblem.invalidState }
            }
        }
    }
}

// Offline coordinator. Confine to the UI's main actor when connected to the app.
// Every new process starts paused, even when a previous consent choice was saved.
// No URLSession or endpoint exists here; returned attempts are preview artifacts only.
final class SharingOfflineController: ObservableObject {
    private(set) var state: SharingClientState
    @Published private(set) var sessionActive = false
    private let file: SharingStateFile
    var canViewEveryone: Bool { state.account == .workOrSchool || (sessionActive && state.canViewEveryone) }
    init(file: SharingStateFile, now: Date) throws {
        self.file = file
        self.state = try file.load(now: now) ?? SharingClientState()
        try file.save(state)
    }
    private func commit(_ change: (inout SharingClientState) throws -> Void) throws {
        var next = state
        do { try change(&next) }
        catch SharingProblem.methodChanged {
            sessionActive = false
            state = next
            try file.save(next)
            throw SharingProblem.methodChanged
        }
        try file.save(next)
        state = next
    }
    func selectAccount(_ account: SharingAccount) throws {
        sessionActive = false
        try commit { $0.setAccount(account) }
    }
    // Call only after an explicit personal-account consent/resume action.
    func approvePersonalSharing() throws {
        try commit { try $0.optIn() }
        sessionActive = true
    }
    func queue(comparisons: [SharingComparison], region: String, appVersion: String,
               config: SharingConfig, now: Date, windowStart: Int64? = nil) throws {
        guard sessionActive else { throw SharingProblem.consentRequired }
        try commit { try $0.queue(comparisons: comparisons, region: region, appVersion: appVersion, config: config, now: now, windowStart: windowStart) }
    }
    func queue(_ draft: SharingMeasurementDraft, region: String, appVersion: String,
               config: SharingConfig, now: Date) throws {
        guard draft.methodId == SharingMethod.id else { try stop(); throw SharingProblem.methodChanged }
        try queue(comparisons: draft.comparisons, region: region, appVersion: appVersion,
                  config: config, now: now, windowStart: draft.windowStart)
    }
    func previewAttempt(config: SharingConfig, now: Date) throws -> SharingAttempt? {
        guard sessionActive else { return nil }
        var attempt: SharingAttempt?
        try commit { attempt = try $0.beginAttempt(config: config, now: now) }
        return attempt
    }
    func recordResult(_ attempt: SharingAttempt, status: Int, now: Date) throws {
        guard sessionActive else { return }
        // An authentication rejection requires explicit resume, not automatic retries.
        // Pause before persistence so even a save failure cannot keep sending.
        if [401, 403].contains(status), state.pending?.id == attempt.id,
           state.generation == attempt.generation { sessionActive = false }
        try commit { $0.finishAttempt(attempt, status: status, now: now) }
    }
    func expireQueued(at now: Date) throws {
        guard let pending = state.pending, pending.windowStart != SharingClientState.completedWindow(at: now) else { return }
        try commit { $0.expire(at: now) }
    }
    func pauseForAuthentication() { sessionActive = false }
    func stop() throws {
        // Stop in memory even if the disk write fails. A restart is paused too.
        sessionActive = false
        state.stop()
        try file.save(state)
    }
}

// App-facing local preparation lifecycle. This type has no transport capability.
// Production construction is disabled and does not create a file or read telemetry.
// Only synthetic integration tests inject an enabled controller/configuration today.
@MainActor final class SharingAppSession: ObservableObject {
    @Published private(set) var status = "Sharing is off. No sharing records are being created or sent."
    @Published private(set) var active = false
    @Published private(set) var preparedWindow: Int64?
    @Published private(set) var nextCheckAt: Date?
    let preparationEnabled: Bool
    private let controller: SharingOfflineController?
    private var region: String?
    private var lastCheck: Date?
    init(preparationEnabled: Bool = false, controller: SharingOfflineController? = nil) {
        self.preparationEnabled = preparationEnabled
        self.controller = controller
    }
    func canStart(account: SharingAccount, region: String, reviewed: Bool) -> Bool {
        !active && preparationEnabled && controller != nil && account == .personal && reviewed &&
        ["americas", "europe", "asia-pacific"].contains(region)
    }
    func start(account: SharingAccount, region: String, reviewed: Bool) {
        guard canStart(account: account, region: region, reviewed: reviewed) else {
            status = "Sharing is unavailable in this build. Nothing was enabled."
            return
        }
        do {
            try controller!.selectAccount(account)
            if let pending = controller!.state.pending, pending.region != region {
                // New consent never authorizes an old-region payload. Keep the
                // same-window guard even though the incompatible queue is cleared.
                try controller!.stop()
            }
            try controller!.approvePersonalSharing()
            self.region = region; active = true; lastCheck = nil; nextCheckAt = nil
            status = "Local preparation enabled. Network sending is disabled."
        } catch { fail("Could not save consent", error) }
    }
    var canStop: Bool { active || controller?.state.consented == true || controller?.state.pending != nil }
    @discardableResult func stop() -> Bool {
        active = false; region = nil; lastCheck = nil; preparedWindow = nil; nextCheckAt = nil
        do { try controller?.stop(); status = "Stopped. Queued local records cleared. Nothing new will be sent."; return true }
        catch { status = "Stopped in memory, but could not save Stop. Restart remains paused: \(error)"; return false }
    }
    // Account, region or review changes withdraw the current session, not merely its UI checkbox.
    func selectionChanged() { if canStop { stop() } }
    func needsFreshPreparation(now: Date, appVersion: String, config: SharingConfig) -> Bool {
        guard preparationEnabled, active, controller?.sessionActive == true, let region,
              config.usable(at: now), config.regions.contains(region),
              SharingClientState.atLeast(appVersion, config.minAppVersion),
              let window = SharingClientState.completedWindow(at: now),
              controller?.state.lastQueuedWindow != window else { return false }
        return lastCheck == nil || now < lastCheck! || now.timeIntervalSince(lastCheck!) >= 30
    }
    func tick(now: Date, appVersion: String, config: SharingConfig?,
              prepare: (Date, Date, Set<String>) -> SharingMeasurementDraft?) {
        guard preparationEnabled, let controller else { return }
        // Queue expiry is local housekeeping, independent of consent, connectivity
        // or config freshness. A paused session must not retain an expired payload.
        do { try controller.expireQueued(at: now) } catch { fail("Could not save queue expiry", error); return }
        if controller.state.pending == nil { preparedWindow = nil }
        guard active, let region else { return }
        guard controller.sessionActive else { pause("Sharing paused. Resume requires consent."); return }
        guard let config else { pause("Waiting for reviewed server configuration."); return }
        guard config.exactEfforts == SharingMethod.exactEfforts, config.methodId == SharingMethod.id, config.graceSeconds == Int(SharingMethod.graceMS / 1000) else {
            if stop() { status = "Method changed. Review the new method before consenting again." }; return
        }
        guard config.usable(at: now), config.regions.contains(region),
              SharingClientState.atLeast(appVersion, config.minAppVersion) else {
            pause("Configuration unavailable or app update required. Resume requires consent."); return
        }
        guard let window = SharingClientState.completedWindow(at: now) else {
            nextCheckAt = Date(timeIntervalSince1970: Double(SharingClientState.windowStart(at: now) + SharingMethod.windowMS) / 1000)
            preparedWindow = nil; status = "Waiting for a completed half-hour. Network sending is disabled."; return
        }
        if controller.state.lastQueuedWindow == window {
            preparedWindow = controller.state.pending?.windowStart
            status = controller.state.pending == nil ? "This window was already used. Nothing is queued; waiting for the next window." : "Record prepared locally. Network sending is disabled."; return
        }
        // Re-check sparse or recently synced history at most every 30 seconds during grace.
        if let lastCheck, now >= lastCheck, now.timeIntervalSince(lastCheck) < 30 { return }
        lastCheck = now; nextCheckAt = now.addingTimeInterval(30)
        let start = Date(timeIntervalSince1970: Double(window) / 1000)
        guard let draft = prepare(start, now, config.models) else {
            status = "No eligible comparison yet. Nothing queued or sent."; return
        }
        do {
            try controller.queue(draft, region: region, appVersion: appVersion, config: config, now: now)
            preparedWindow = window
            status = "Record prepared locally. Network sending is disabled."
        } catch { fail("Could not prepare local record", error) }
    }
    private func pause(_ message: String) {
        active = false; nextCheckAt = nil; controller?.pauseForAuthentication(); status = message
    }
    private func fail(_ message: String, _ error: Error) {
        active = false; nextCheckAt = nil; controller?.pauseForAuthentication()
        status = "\(message). Sharing paused: \(error)"
    }
}
