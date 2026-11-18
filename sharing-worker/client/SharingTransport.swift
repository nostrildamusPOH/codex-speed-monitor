import Foundation
import Combine


// Memory-only audit of attempted uploads, owned by one setup controller. Never
// persist payload bytes, request/installation IDs, credentials or server bodies.
struct SharingUploadEntry: Identifiable {
    let id: UUID // Local UI identity only; unrelated to request/installation IDs.
    let startedAt: Date
    let destination: String
    let windowStart: Int64
    let region: String
    let comparisons: [SharingComparison]
    var outcome: String
}
@MainActor final class SharingUploadHistory: ObservableObject {
    static let capacity = 50
    @Published private(set) var entries: [SharingUploadEntry] = []
    func begin(_ attempt: SharingAttempt, destination: String, now: Date) -> UUID? {
        guard attempt.body.count <= 8192,
              let record = try? JSONDecoder().decode(SharingRecord.self, from: attempt.body),
              record.comparisons.count <= 12 else { return nil }
        let id = UUID()
        entries.insert(SharingUploadEntry(id: id, startedAt: now, destination: destination,
            windowStart: record.windowStart, region: record.region, comparisons: record.comparisons,
            outcome: "Attempt started; delivery not yet confirmed"), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        return id
    }
    func finish(_ id: UUID?, result: SharingUploadResult?) {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].outcome = result.map { $0.accepted
            ? "Server acknowledged acceptance (may be an identical retry)"
            : "No acceptance acknowledgement (HTTP \($0.status)); delivery may be unknown" }
            ?? "Delivery unknown; interruption or invalid response does not prove nothing arrived"
    }
}

// Actual HTTP adapter, default disabled. No production endpoint is supplied by this build.
// Constructing the disabled adapter performs no networking. Tests use intercepted .invalid URLs.
enum SharingTransportPolicy {
    case disabled
    case reviewedEndpoint(URL)
}
enum SharingTransportError: Error, Equatable {
    case disabled, inviteRequired, methodChanged, invalidEndpoint, invalidResponse, responseTooLarge, redirected, unavailable(Int)
}
struct SharingUploadResult {
    let status: Int
    let accepted: Bool
}
struct SharingPublicCell: Codable, Equatable {
    let windowStart: Int64
    let region: String
    let model: String
    let tier: String
    let median: Double
    let exactEffort: String
    var methodId: String = SharingMethod.id
}
private struct SharingConfigResponse: Decodable {
    let enabled: Bool
    let minAppVersion: String
    let models: [String]
    let regions: [String]
    let windowSeconds: Int
    let graceSeconds: Int
    let exactEfforts: [String]
    let methodId: String
}
private struct SharingSnapshotResponse: Decodable { let windows: [SharingPublicCell]; let nextCursor: String? }
private struct SharingUploadResponse: Decodable { let accepted: Bool; let duplicate: Bool? }
private final class SharingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a sharing payload to another destination.
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil) // Normal system TLS verification only.
        } else {
            completionHandler(.rejectProtectionSpace, nil) // Never attach saved user credentials.
        }
    }
}
final class SharingHTTPTransport {
    private let policy: SharingTransportPolicy
    private let session: URLSession
    // Supplied only after a reviewed invite flow. Memory-only; never stored in the state archive.
    private let credentialLock = NSLock()
    private var inviteCredential: String?
    init(policy: SharingTransportPolicy = .disabled, inviteCredential: String? = nil, configuration: URLSessionConfiguration = .ephemeral) {
        self.policy = policy
        self.inviteCredential = inviteCredential
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: config, delegate: SharingSessionDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func cancelAll() { session.getAllTasks { tasks in tasks.forEach { $0.cancel() } } }
    func discardInvite() {
        credentialLock.lock(); inviteCredential = nil; credentialLock.unlock()
        session.invalidateAndCancel()
    }
    private func credential() -> String? {
        credentialLock.lock(); defer { credentialLock.unlock() }; return inviteCredential
    }
    private func endpoint(_ path: String) throws -> URL {
        guard case let .reviewedEndpoint(base) = policy else { throw SharingTransportError.disabled }
        guard let parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, ["", "/"].contains(parts.path),
              ["config", "snapshot", "records"].contains(path) else { throw SharingTransportError.invalidEndpoint }
        return base.appendingPathComponent(path)
    }
    func validateUploadAuthorization() throws {
        _ = try endpoint("records")
        guard let credential = credential(),
              (32...128).contains(credential.utf8.count),
              credential.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw SharingTransportError.inviteRequired }
    }
    private func request(_ path: String, body: Data? = nil, cursor: String? = nil, onStart: (@MainActor () -> Void)? = nil) async throws -> (HTTPURLResponse, Data) {
        try Task.checkCancellation()
        var parts = URLComponents(url: try endpoint(path), resolvingAgainstBaseURL: false)!
        if let cursor { parts.queryItems = [URLQueryItem(name: "before", value: cursor)] }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = body == nil ? "GET" : "POST"
        if path == "records" {
            try validateUploadAuthorization()
            guard let invite = credential() else { throw SharingTransportError.inviteRequired }
            request.setValue("Bearer " + invite, forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            guard body.count <= 8192 else { throw SharingTransportError.responseTooLarge }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let onStart { await onStart() }
        try Task.checkCancellation()
        let (bytes, rawResponse) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = rawResponse as? HTTPURLResponse else { throw SharingTransportError.invalidResponse }
        guard !(300...399).contains(response.statusCode) else { throw SharingTransportError.redirected }
        // Authentication rejection is actionable even if an edge gateway returns HTML.
        // Do not read or log that body, and preserve the status for the coordinator.
        if [401, 403].contains(response.statusCode) { return (response, Data()) }
        guard response.expectedContentLength <= 65_536 else { throw SharingTransportError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw SharingTransportError.responseTooLarge }
            data.append(byte)
        }
        if (200...299).contains(response.statusCode) {
            guard response.mimeType?.lowercased() == "application/json" else { throw SharingTransportError.invalidResponse }
        }
        return (response, data)
    }
    func configuration(now: Date = Date()) async throws -> SharingConfig {
        let (response, data) = try await request("config")
        guard response.statusCode == 200 else { throw SharingTransportError.unavailable(response.statusCode) }
        guard let parsed = try? JSONDecoder().decode(SharingConfigResponse.self, from: data),
              SharingClientState.atLeast(parsed.minAppVersion, "0.0.0"),
              parsed.models.count <= 100, Set(parsed.models).count == parsed.models.count,
              parsed.models.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              !parsed.regions.isEmpty, Set(parsed.regions).isSubset(of: ["americas", "europe", "asia-pacific"]) else {
            throw SharingTransportError.invalidResponse
        }
        guard Set(parsed.exactEfforts) == SharingMethod.exactEfforts, parsed.exactEfforts.count == SharingMethod.exactEfforts.count, parsed.methodId == SharingMethod.id, parsed.windowSeconds == Int(SharingMethod.windowMS / 1000),
              parsed.graceSeconds == Int(SharingMethod.graceMS / 1000) else { throw SharingTransportError.methodChanged }
        return SharingConfig(enabled: parsed.enabled, minAppVersion: parsed.minAppVersion,
                             models: Set(parsed.models), regions: Set(parsed.regions), fetchedAt: now, methodId: parsed.methodId, exactEfforts: Set(parsed.exactEfforts), graceSeconds: parsed.graceSeconds)
    }
    func upload(_ attempt: SharingAttempt, onStart: (@MainActor () -> Void)? = nil) async throws -> SharingUploadResult {
        let (response, data) = try await request("records", body: attempt.body, onStart: onStart)
        if response.statusCode == 200 {
            guard let result = try? JSONDecoder().decode(SharingUploadResponse.self, from: data), result.accepted else {
                throw SharingTransportError.invalidResponse
            }
            return SharingUploadResult(status: 200, accepted: true)
        }
        return SharingUploadResult(status: response.statusCode, accepted: false)
    }
    private func cellKey(_ cell: SharingPublicCell) -> [String] {
        [String(cell.windowStart), cell.region, cell.model, cell.tier, cell.exactEffort]
    }
    func snapshot(config: SharingConfig, now: Date = Date()) async throws -> [SharingPublicCell] {
        guard config.usable(at: now) else { throw SharingTransportError.disabled }
        let current = SharingClientState.windowStart(at: now)
        var seen = Set<Data>()
        var cursors = Set<String>()
        var cursor: String? = nil
        var result: [SharingPublicCell] = []
        // Server admission caps imply at most 115,200 cells in 48 retained windows.
        // Bound total work as well as each streamed response. Never return a partial result.
        for _ in 0..<1024 {
            try Task.checkCancellation()
            let (response, data) = try await request("snapshot", cursor: cursor)
            guard response.statusCode == 200 else { throw SharingTransportError.unavailable(response.statusCode) }
            guard let parsed = try? JSONDecoder().decode(SharingSnapshotResponse.self, from: data), parsed.windows.count <= 200,
                  result.count + parsed.windows.count <= 115_200 else { throw SharingTransportError.invalidResponse }
            for cell in parsed.windows {
                guard cell.windowStart >= 0, cell.windowStart < Int64.max - SharingClientState.windowMS - SharingMethod.graceMS, cell.windowStart % SharingClientState.windowMS == 0,
                      cell.methodId == SharingMethod.id, SharingMethod.exactEfforts.contains(cell.exactEffort), cell.windowStart < current,
                      Double(cell.windowStart + SharingClientState.windowMS + SharingMethod.graceMS) <= now.timeIntervalSince1970 * 1000, cell.windowStart + SharingClientState.windowMS > Int64(now.timeIntervalSince1970 * 1000) - 86_400_000,
                      config.models.contains(cell.model), config.regions.contains(cell.region),
                      ["standard", "fast", "ultrafast"].contains(cell.tier), cell.median.isFinite,
                      (0.3...3).contains(cell.median),
                      seen.insert(try JSONEncoder().encode(cellKey(cell))).inserted else { throw SharingTransportError.invalidResponse }
            }
            result.append(contentsOf: parsed.windows)
            guard let next = parsed.nextCursor else { return result }
            guard !parsed.windows.isEmpty, next.utf8.count <= 8192, cursors.insert(next).inserted else { throw SharingTransportError.invalidResponse }
            cursor = next
        }
        throw SharingTransportError.invalidResponse
    }
}

// Orchestrates persisted attempts and HTTP. Default construction is disabled; no timers.
// This class is intentionally not instantiated by the app's preview-only setup sheet.
@MainActor final class SharingConnection {
    let controller: SharingOfflineController
    private let transport: SharingHTTPTransport
    private let clock: () -> Date
    private var inFlight: Task<Void, Never>?
    private(set) var lastStatus = "Sharing is off"
    private let history: SharingUploadHistory?
    private let destination: String
    init(controller: SharingOfflineController, transport: SharingHTTPTransport = SharingHTTPTransport(), clock: @escaping () -> Date = Date.init, history: SharingUploadHistory? = nil, destination: String = "Reviewed destination") {
        self.history = history; self.destination = destination
        self.controller = controller
        self.transport = transport
        self.clock = clock
    }
    func sendPending(now suppliedNow: Date? = nil) async {
        let now = suppliedNow ?? clock()
        guard inFlight == nil, controller.sessionActive, controller.state.pending != nil,
              !controller.state.accepted, controller.state.attempts < 5, now >= controller.state.nextAttemptAt else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var historyID: UUID?
            var uploadResult: SharingUploadResult?
            defer { history?.finish(historyID, result: uploadResult) }
            do {
                // Validate local prerequisites before fetching config or charging an attempt.
                try transport.validateUploadAuthorization()
                let config = try await transport.configuration(now: now)
                try Task.checkCancellation()
                guard let attempt = try controller.previewAttempt(config: config, now: clock()) else { return }
                let result = try await transport.upload(attempt, onStart: {
                    historyID = self.history?.begin(attempt, destination: self.destination, now: self.clock())
                })
                uploadResult = result
                try Task.checkCancellation()
                try controller.recordResult(attempt, status: result.status, now: clock())
                if [401, 403].contains(result.status) {
                    lastStatus = "Sharing paused: review or replace your beta invite, then resume"
                } else {
                    lastStatus = result.accepted ? "Accepted for this window" : "Not accepted; retry remains bounded"
                }
            } catch SharingTransportError.methodChanged {
                do {
                    try controller.stop()
                    lastStatus = "Sharing paused: method changed; review and consent again"
                } catch {
                    lastStatus = "Sharing paused; could not save the method change"
                }
            } catch SharingProblem.methodChanged {
                lastStatus = "Sharing paused: method changed; review and consent again"
            } catch SharingTransportError.unavailable(let status) where [401, 403].contains(status) {
                controller.pauseForAuthentication()
                lastStatus = "Sharing paused: review or replace your beta invite, then resume"
            } catch SharingTransportError.disabled {
                lastStatus = "Server connection is disabled"
            } catch SharingTransportError.inviteRequired {
                lastStatus = "A reviewed beta invite is required"
            } catch is CancellationError {
                lastStatus = "Sharing is off"
            } catch {
                // Deliberately do not expose/log URLs, payloads or underlying error descriptions.
                lastStatus = Task.isCancelled ? "Sharing is off" : "Could not send; check connection or local state"
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
    }
    func cancelPendingAndDiscardInvite() {
        inFlight?.cancel()
        transport.discardInvite()
    }
    func stop() throws {
        inFlight?.cancel()
        transport.cancelAll()
        lastStatus = "Sharing is off"
        try controller.stop()
    }
}
