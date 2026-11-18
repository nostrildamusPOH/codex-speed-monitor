import Foundation
import AppKit
import Combine

// App-owned local scheduler. No network capability, no raw data logging.
// A disabled session installs no timer/observers and never calls its providers.
@MainActor final class SharingAppLifecycle: ObservableObject {
    let session: SharingAppSession
    private var generation = 0
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private let clock: () -> Date
    private var appVersion = "0.0.0"
    private var configuration: () -> SharingConfig? = { nil }
    private var prepare: (Date, Date, Set<String>) -> SharingMeasurementDraft? = { _,_,_ in nil }
    init(session: SharingAppSession? = nil, clock: @escaping () -> Date = Date.init) { self.session = session ?? SharingAppSession(); self.clock = clock }
    func configure(appVersion: String, configuration: @escaping () -> SharingConfig?,
                   prepare: @escaping (Date, Date, Set<String>) -> SharingMeasurementDraft?) {
        self.appVersion = appVersion; self.configuration = configuration; self.prepare = prepare
        guard session.preparationEnabled, timer == nil else { return }
        generation += 1
        let scheduledGeneration = generation
        // Common run-loop modes keep cleanup independent of whether a report window is open.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduledPoll(generation: scheduledGeneration) }
        }
        timer.tolerance = 2; self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduledPoll(generation: scheduledGeneration) }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduledPoll(generation: scheduledGeneration) }
        }
        pollNow()
    }
    private func scheduledPoll(generation: Int) {
        guard generation == self.generation, timer != nil else { return }
        pollNow()
    }
    private func pollNow() { poll(at: clock()) }
    func poll(at now: Date) {
        guard session.preparationEnabled, timer != nil else { return }
        // Paused sessions never consult config. tick expires local state before
        // interpreting configuration or invoking the lazy measurement provider.
        session.tick(now: now, appVersion: appVersion, config: session.active ? configuration() : nil, prepare: prepare)
    }
    func resumeAfterWake(at now: Date) { poll(at: now) }
    var isScheduling: Bool { timer != nil }
    func shutdown() {
        generation += 1 // invalidate main-actor Tasks queued by old timer/notification callbacks
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        wakeObserver = nil; activeObserver = nil
    }
    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }
}

enum SharingStorageLocation {
    // Call only after activation is reviewed. Merely constructing the app does not
    // call this factory. Disabled use is a strict no-I/O path, including no reads.
    static func controller(enabled: Bool = false, applicationDirectory: URL? = nil, now: Date) throws -> SharingOfflineController? {
        guard enabled else { return nil }
        let fm = FileManager.default
        let base = applicationDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexSpeedMonitor", isDirectory: true)
        let attrs = try fm.attributesOfItem(atPath: base.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else { throw SharingArchiveProblem.invalidState }
        let directory = base.appendingPathComponent("Sharing", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        return try SharingOfflineController(file: SharingStateFile(url: directory.appendingPathComponent("state-v2.json"), privateDirectory: true), now: now)
    }
}

// Production composition: one onboarding owner, one session, one async poll.
// Legacy SharingAppLifecycle above remains an offline-controller test harness.
@MainActor final class SharingIntegratedRuntime: ObservableObject {
    let onboarding: SharingOnboarding
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var stateObserver: AnyCancellable?
    private var subscriptionGeneration = 0
    private var task: Task<Void, Never>?
    private var generation = 0
    private var prepare: (Date, Date, Set<String>) async -> SharingFreshDraft? = { _,_,_ in nil }
    init(onboarding: SharingOnboarding? = nil, appVersion: String = "0.0.0") {
        self.onboarding = onboarding ?? SharingOnboarding(appVersion: appVersion, makeController: { now in
            // This closure is never invoked unless the reviewed endpoint and
            // explicit account/region/method/invite consent gates all pass.
            guard let controller = try SharingStorageLocation.controller(enabled: true, now: now) else { throw SharingProblem.unavailable }
            return controller
        })
    }
    func configure(prepare: @escaping (Date, Date, Set<String>) async -> SharingFreshDraft?) {
        self.prepare = prepare
        guard onboarding.available, stateObserver == nil else { return }
        subscriptionGeneration += 1; let subscription = subscriptionGeneration
        stateObserver = onboarding.$session.sink { [weak self] _ in
            guard let self else { return }
            // Combine publishes before assignment; defer until session is installed.
            Task { @MainActor [weak self] in
                guard let self, subscription == self.subscriptionGeneration, self.stateObserver != nil else { return }
                if self.onboarding.session == nil { self.cancelPolling() } else { self.startPolling() }
            }
        }
    }
    private func startPolling() {
        guard onboarding.session != nil, timer == nil else { return }
        generation += 1; let token = generation
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduledPoll(token) }
        }
        timer.tolerance = 2; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduledPoll(token) }
        })
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduledPoll(token) }
        })
        scheduledPoll(token)
    }
    private func scheduledPoll(_ token: Int) {
        guard token == generation, timer != nil else { return }; poll()
    }
    func poll() {
        guard onboarding.available, onboarding.session != nil, timer != nil, task == nil else { return }
        onboarding.maintainLocalState()
        guard onboarding.session?.active == true else { return }
        let token = generation
        task = Task { @MainActor [weak self] in
            guard let self, token == self.generation, !Task.isCancelled else { return }
            await self.onboarding.prepareAndSend(self.prepare)
            if token == self.generation { self.task = nil }
        }
    }
    var isScheduling: Bool { timer != nil }
    private func cancelPolling() {
        generation += 1; task?.cancel(); task = nil; timer?.invalidate(); timer = nil
        if !observers.isEmpty {
            NSWorkspace.shared.notificationCenter.removeObserver(observers[0])
            if observers.count > 1 { NotificationCenter.default.removeObserver(observers[1]) }
        }
        observers = []
    }
    func stop() { onboarding.stop(); cancelPolling() }
    func shutdown() { subscriptionGeneration += 1; stateObserver?.cancel(); stateObserver = nil; stop() }
    deinit {
        timer?.invalidate(); task?.cancel()
        if !observers.isEmpty { NSWorkspace.shared.notificationCenter.removeObserver(observers[0]) }
        if observers.count > 1 { NotificationCenter.default.removeObserver(observers[1]) }
    }
}
