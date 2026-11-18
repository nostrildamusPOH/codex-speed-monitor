import SwiftUI

@main
@MainActor struct CodexSpeedMonitorMenuApp: App {
    @StateObject private var store: TelemetryStore
    @StateObject private var sharing: SharingIntegratedRuntime
    init() {
        let store = TelemetryStore()
        _store = StateObject(wrappedValue: store)
        let lifecycle = SharingIntegratedRuntime(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
        lifecycle.configure { start, _, models in
            let report = await store.readSharingSnapshot()
            guard !Task.isCancelled else { return nil }
            let now = Date(), window = Int64(start.timeIntervalSince1970 * 1000)
            let freshness = SharingFreshDraft(checkedAt: report.checkedAt, snapshotAt: report.snapshotAt, heartbeat: report.heartbeat, draft: nil)
            guard freshness.isFresh(window: window, now: now) else { return freshness }
            return SharingFreshDraft(checkedAt: report.checkedAt, snapshotAt: report.snapshotAt, heartbeat: report.heartbeat,
                draft: SharingMeasurementPreviewBuilder.evaluate(report, windowStart: start, asOf: now,
                    publicModels: models, proposal: .provisionalV1).preparedDraft())
        }
        _sharing = StateObject(wrappedValue: lifecycle)
    }

    var body: some Scene {
        MenuBarExtra {
            WidgetView(store: store)
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("Token speed")
        }
        .menuBarExtraStyle(.window)

        Window("Codex Speed Report", id: "report") {
            ReportView(store: store, onboarding: sharing.onboarding)
        }
        .defaultSize(width: 1040, height: 720)
    }
}
