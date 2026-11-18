import Foundation
import AppKit

@main struct SharingLifecycleTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_794_140_401)
        let edge = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 1800) * 1800 + 1)
        let window = SharingClientState.completedWindow(at: edge)!
        let path = root.appendingPathComponent("state.json")
        let controller = try SharingOfflineController(file: SharingStateFile(url: path), now: edge)
        let session = SharingAppSession(preparationEnabled: true, controller: controller)
        let lifecycle = SharingAppLifecycle(session: session, clock: { edge })
        var configReads = 0, payloadReads = 0
        let config = SharingConfig(enabled: true, minAppVersion: "1.0.0", models: ["synthetic"], regions: ["europe"], fetchedAt: edge)
        func configure() {
            lifecycle.configure(appVersion: "1.0.0", configuration: { configReads += 1; return config }, prepare: { _,_,_ in
                payloadReads += 1
                return SharingMeasurementDraft(methodId: SharingMethod.id, windowStart: window,
                    comparisons: [SharingComparison(model: "synthetic", tier: "standard", ratio: 1, exactEffort: "high")])
            })
        }
        func inode() throws -> UInt64 { (try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as! NSNumber).uint64Value }
        configure()
        let idleInode = try inode()
        for _ in 0..<20 { lifecycle.poll(at: edge) }
        let unchangedIdle = try inode()
        precondition(unchangedIdle == idleInode && configReads == 0)
        session.start(account: .personal, region: "europe", reviewed: true)
        // Queue the OS observer's main-actor Task, then invalidate before yielding.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        lifecycle.shutdown()
        for _ in 0..<10 { await Task.yield() }
        precondition(configReads == 0 && payloadReads == 0 && controller.state.pending == nil)
        lifecycle.resumeAfterWake(at: edge)
        precondition(configReads == 0)
        // A previous-generation activation callback must also stay invalid after reconfigure.
        configure() // immediate explicit poll legitimately prepares once
        precondition(configReads == 1 && payloadReads == 1 && controller.state.pending != nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        lifecycle.shutdown()
        configure() // one legitimate new-generation poll
        precondition(configReads == 2)
        for _ in 0..<10 { await Task.yield() }
        precondition(configReads == 2 && payloadReads == 1)
        let queuedInode = try inode()
        for _ in 0..<20 { lifecycle.poll(at: edge.addingTimeInterval(15)) }
        let unchangedQueued = try inode()
        precondition(unchangedQueued == queuedInode)
        let expired = Date(timeIntervalSince1970: Double(window + SharingMethod.windowMS + SharingMethod.graceMS) / 1000)
        lifecycle.resumeAfterWake(at: expired.addingTimeInterval(2))
        precondition(controller.state.pending == nil && !session.active)
        let expiredInode = try inode()
        for _ in 0..<20 { lifecycle.poll(at: expired.addingTimeInterval(15)) }
        let unchangedExpired = try inode()
        precondition(unchangedExpired == expiredInode)
        lifecycle.shutdown()
        print("PASS unchanged idle/queued/expired polls never rewrite archive; queued wake/activation Tasks cannot poll after shutdown or across generation change; active wake expiry pauses stale configuration")
    }
}
