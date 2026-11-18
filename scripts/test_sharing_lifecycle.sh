#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/codex-sharing-lifecycle-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
xcrun swiftc "$ROOT/sharing-worker/client/SharingProtocol.swift" "$ROOT/sharing-worker/client/SharingAppLifecycle.swift" "$ROOT/sharing-worker/client/SharingTransport.swift" "$ROOT/sharing-worker/client/SharingOnboarding.swift" "$ROOT/tests/test_sharing_lifecycle.swift" -framework AppKit -o "$TMP/checks"
"$TMP/checks"
