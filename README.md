# Codex Speed Monitor

An unofficial macOS menu-bar app that measures how quickly Codex generates your
responses. See output tokens per second, compare Fast and Standard, review
recent history and export your own results to CSV.

Version 0.1.0 is a source preview. Measurements stay on your Mac. The Everyone
sharing feature is disabled.

## Install from source

You need macOS 14 or newer, Codex installed and signed in, and the Xcode Command
Line Tools. To install the tools if needed, run `xcode-select --install`.

1. Download the source ZIP from the v0.1.0 GitHub release and unzip it.
2. Open Terminal in the extracted folder and run:

   ```sh
   ./scripts/install.sh
   ```

The installer builds the menu-bar app, installs it in `~/Applications` and
starts a background collector for your macOS user. It backs up your Codex
configuration before adding a local telemetry exporter. If an `[otel]` section
already exists, the installer leaves it in place.

Restart Codex if it was open, then send a new message. If the menu-bar app
doesn't appear, open `~/Applications/CodexSpeedMonitor.app` or run
`./scripts/doctor.sh` from the extracted folder to check setup.

## Update or uninstall

To update, download the newer release and run its installer. To remove the app
and collector, run `./scripts/uninstall.sh` from the extracted folder. Add
`--purge` only if you also want to remove the local database and logs.

## Privacy

The collector stores data in `~/Library/Application Support/CodexSpeedMonitor`.
The database and logs can include response IDs, timing, model names and selected
raw telemetry. Keep those files private. See [Security and privacy](SECURITY.md)
for what to include in a bug report.

## Community

Use GitHub Discussions for setup questions and feedback. Use Issues for
reproducible bugs. See [Contributing](CONTRIBUTING.md). The project uses the
[MIT license](LICENSE).

## Project credit

Maintained by Speed Monitor Maintainers. This project builds on the original MIT-licensed
Codex Speed Monitor. The original copyright notice is preserved in the LICENSE.
