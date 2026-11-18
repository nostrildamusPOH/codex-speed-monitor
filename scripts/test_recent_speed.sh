#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/codex-recent-speed-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc "$ROOT/sharing-worker/client/SharingProtocol.swift" "$ROOT/sharing-worker/client/SharingTransport.swift" "$ROOT/sharing-worker/client/SharingOnboarding.swift" "$ROOT/sharing-worker/client/SharingEveryone.swift" "$ROOT/sharing-worker/client/SharingProjection.swift" "$ROOT/CodexSpeedMonitorViewer/Views/SharingProjectionView.swift" "$ROOT/CodexSpeedMonitorViewer/Views/SharingEveryoneView.swift" "$ROOT/CodexSpeedMonitorViewer/Views/SharingOnboardingView.swift" -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$TEST_DIR/modules}" \
 "$ROOT/tests/test_recent_speed.swift" \
 "$ROOT/sharing-worker/client/SharingMeasurementPreview.swift" \
 "$ROOT/CodexSpeedMonitorViewer/Models/RecentSpeed.swift" \
 "$ROOT/CodexSpeedMonitorViewer/Models/TelemetryModels.swift" \
 "$ROOT/CodexSpeedMonitorViewer/Support/Formatting.swift" \
 "$ROOT/CodexSpeedMonitorViewer/Stores/TelemetryStore.swift" \
 "$ROOT/CodexSpeedMonitorViewer/Views/WidgetView.swift" \
 "$ROOT/CodexSpeedMonitorViewer/Views/SharingSetupView.swift" \
  "$ROOT/CodexSpeedMonitorViewer/Views/ReportView.swift" \
 -framework SwiftUI -framework AppKit -lsqlite3 -o "$TEST_DIR/checks"
"$TEST_DIR/checks" "$@"
