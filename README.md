# Menu Bar Usage for Claude

A native macOS menu bar app that tracks your Claude Code usage quotas — the same progress bars that Claude Desktop shows (*Current Session*, *Weekly Limit*, and — on Max plans — *Fable*), available at a glance from the menu bar without having to open Claude Desktop or run `claude /status` in a terminal.

Built with SwiftUI, `MenuBarExtra`, and Observation for macOS 26+.

![Screenshot of the Menu Bar Usage for Claude popover showing a Current Session bar at 17 percent with 4 hours until reset and a Weekly Limit bar at 2 percent with 8 hours until reset. The macOS menu bar above it shows the app's gauge icon displaying 17 percent.](docs/screenshot.png)

> **Disclaimer.** This project is not affiliated with or endorsed by Anthropic. It reads from an undocumented community-discovered endpoint (`/api/oauth/usage`) that Claude Code itself uses for its status line, authenticated with the OAuth token that the `claude` CLI already stored in your login keychain. The endpoint is not a stable public API and may change or be removed at any time.

## Purpose

If you're a Claude Pro or Max subscriber and you use Claude Code, you probably want to know how much of your current-session, weekly, and — on Max plans — Fable quotas you have left — without having to open Claude Desktop, context-switch into a terminal, or run `/status` inside an active session. This app puts those bars in your menu bar, refreshes them every 2–5 minutes in the background, and optionally displays the current session percentage next to the menu bar icon.

## Features

- **Live quota bars** that mirror Claude Desktop:
  - **Current Session** — the 5-hour rolling window
  - **Weekly Limit** — the 7-day rolling all-models window
  - **Fable** — the model-scoped 7-day window (Max 5x/20x plans only; the bar appears whenever the API reports a model-scoped weekly limit and is titled by the API, so it follows any future rename)
- **Read-only Extra Usage card** — appears automatically when you enable Extra Usage at [claude.ai/settings/usage](https://claude.ai/settings/usage). Shows used vs. monthly cap, credits remaining, and a link back to the web UI for management.
- **Menu bar gauge icon** with an SF Symbol that tints itself based on peak utilisation (0% / 33% / 67% / 100%), plus an optional text percentage next to the icon for the current session.
- **Session usage alerts** — optional notifications at 50%, 75% and 90% of the session, each at most once per session window (even across relaunches), plus an optional alert when a session that hit 100% resets.
- **Claude service status** — an optional row in the popover summarising [status.claude.com](https://status.claude.com) for the services you pick (claude.ai and Claude Code by default), with links to active incidents.
- **Resilient refreshing** — a network blip keeps the last bars on screen with a note saying why they may be stale, and the app retries within 30 seconds. When Claude Code's token expires, the app has Claude Code refresh it in the background, and only tells you if that doesn't work. Polling pauses while your displays sleep, so the app doesn't wake the network overnight.
- **Tabbed Settings window** (`General`, `Notifications`, `Developer`):
  - Launch at login (via `SMAppService.mainApp`), session percentage in the menu bar, refresh interval (2 / 3 / 4 / 5 minutes, default 5), service-status options and the browser web links open in
  - Usage alert toggles and notification permission
  - Live diagnostic counters, store state, token-refresh state, the Keychain read method, Force Refresh, a test notification, a simulated outage and a factory reset
- **Diagnostic log** — a window of timestamped Keychain, API, refresh, status and sleep/wake events, also written to `~/Library/Logs/ClaudeUsage/diagnostic.log` and the unified log (subsystem `com.shyowlstudios.ClaudeUsage`).
- **First-run onboarding window** — a dedicated Welcome window that explains what the app does before the first Keychain access is attempted.
- **Live rate-limit countdown** — when the endpoint responds with HTTP 429, the popover shows a real-time "Retrying in 4m 23s" countdown, with a minimum 60-second cooldown floor to protect the endpoint even if the server returns `Retry-After: 0`.

## Authentication

The app reuses the OAuth credentials that the `claude` CLI already wrote to your login keychain. It does **not** ask you to sign in again, does **not** need an API key, and does **not** store any credentials of its own.

Specifically:

- **Keychain item.** `kSecClassGenericPassword` with service name `Claude Code-credentials`, created by Claude Code when you first run `claude` → `/login`. The data is a JSON blob containing an OAuth access token, refresh token, expiry, scopes, and subscription tier. The app reads it via `/usr/bin/security find-generic-password` — this binary is already on the keychain item's ACL, so reads succeed silently without triggering a macOS Keychain access prompt. Falls back to `SecItemCopyMatching` (which may prompt) if the CLI approach fails. If the Keychain item is missing entirely, the app reads `~/.claude/.credentials.json`, where Claude Code keeps the same credentials whenever it can't write to the Keychain.
- **Endpoint.** `GET https://api.anthropic.com/api/oauth/usage`, with headers `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`. Returns the session and weekly utilisation windows, a generalised `limits` array (the only source of the model-scoped Fable quota), and the Extra Usage state. This is the same endpoint the `claude` CLI's status line hits. Requests go through an ephemeral session with no URL cache, so neither the token nor the responses are written to disk.
- **Token refresh.** When the access token expires, the app runs `claude mcp list` in the background, which makes Claude Code refresh its own token and write the new one to the Keychain. It launches `claude` directly when it can find it, falling back to your login shell. It runs it in a private, empty folder, never in a shared one like `/tmp`.
- **Sandbox:** Disabled because the app needs to launch `/usr/bin/security` to read keychain items created by Claude Code, and sandboxed apps cannot spawn arbitrary processes. As such, this app can't be published to the App Store.
- **What the app does not do:** No analytics, no telemetry, no remote logging. Every network request goes directly from your Mac to `api.anthropic.com` over HTTPS. The OAuth token never leaves your machine.

## Project Structure

```
ClaudeUsage/
├── ClaudeUsage.xcodeproj/              # Xcode project
├── ClaudeUsage/                        # App sources (PBXFileSystemSynchronizedRootGroup)
│   ├── MenuBarUsageForClaudeApp.swift  # @main, scenes, launch-time setup
│   ├── UsageStore.swift                # Polling, fetch outcomes, background-refresh state machine
│   ├── UsageState.swift                # Failures, what the popover shows, refresh phases and policy
│   ├── UsageAPI.swift                  # /api/oauth/usage client and wire format
│   ├── UsageSnapshot.swift             # Display model and builder
│   ├── HTTPClient.swift                # Ephemeral session, Retry-After, 429 policy
│   ├── KeychainCredentials.swift       # Credential reads (security CLI, Security framework, file)
│   ├── ClaudeCLI.swift                 # Finding and launching `claude` for token refreshes
│   ├── ThresholdTracker.swift          # Usage-alert decisions
│   ├── NotificationManager.swift       # macOS notifications
│   ├── StatusStore.swift               # status.claude.com
│   ├── DiagnosticLog*.swift            # Diagnostic log and its window
│   ├── UsagePopoverView.swift          # Menu bar popover
│   ├── SettingsView.swift              # Settings window
│   └── …                               # Onboarding, menu bar label, settings keys, helpers
├── ClaudeUsageTests/                   # Swift Testing suites
└── scripts/deploy.sh                   # Release build, install to ~/Applications, relaunch
```

### Architecture notes

- **`UsageStore`** is the single source of truth, an `@Observable @MainActor` class that owns the background poll task, the fetch and background-refresh state, and the diagnostic counters. Views observe it via `@Environment(UsageStore.self)`. It takes its collaborators (credential source, fetcher, refresher, notifier, scheduler, display state, clock) as injected dependencies, so the tests drive it with fakes.
- **`MenuBarLabel.task`** is the only place the app starts polling. If onboarding hasn't been completed, it opens the `OnboardingWindowView` instead of touching the Keychain, so the very first credential read happens only after the user clicks Continue.
- **One refresh path** — the background loop, popover opens (debounced 60 s), manual refreshes, quick retries, post-refresh checks and display wakes all go through `refresh(trigger:)`, which guards against re-entrancy, display sleep, the debounce and the 429 cooldown.
- **Scenes** — the app declares four SwiftUI scenes: `MenuBarExtra` for the menu bar popover, `Window`s for the onboarding flow and the diagnostic log, and `Settings` for the preferences window.

## Build

### Requirements

- macOS 26 (Tahoe) or later — the deployment target is `MACOSX_DEPLOYMENT_TARGET = 26.4`
- Xcode 26.4 or later
- Claude Code installed and signed in:
  ```sh
  # Install (pick one)
  curl -fsSL https://claude.ai/install.sh | bash
  # or
  brew install --cask claude-code

  # Sign in
  claude
  # then type /login and follow the OAuth flow
  ```

### Building

1. Open `ClaudeUsage.xcodeproj` in Xcode.
2. Select the `ClaudeUsage` scheme and *My Mac* as the run destination.
3. **Product → Run** (⌘R), or **Product → Build** (⌘B) followed by launching `Menu Bar Usage for Claude.app` from the Products group.

On first launch after a build:

1. The Welcome window appears explaining what the app does.
2. Click **Continue**.
3. The bars populate and the menu bar icon updates.

### Production deployment

For day-to-day use outside of Xcode, copy the built **`Menu Bar Usage for Claude.app`** into `/Applications` (or `~/Applications`), then launch it from there. This matters for the **Launch at login** feature — `SMAppService.mainApp` registers the current bundle path with LaunchServices, so registering from a DerivedData location causes `.notFound` errors on next login. `scripts/deploy.sh` does the whole round trip: it builds Release into `./build`, quits the running copy, replaces `~/Applications/Menu Bar Usage for Claude.app` and relaunches it.

### Tests

```sh
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Debug -destination 'platform=macOS' test
```

The tests are hosted in the app, which recognises the test run and skips its launch side effects, so running them leaves an installed copy alone.

## Alternatives

- **[Notch Pilot](https://github.com/devmegablaster/Notch-Pilot)** — A macOS app that displays Claude Code usage in the Dynamic Island / notch area. Notch Pilot also reads from the same undocumented usage endpoint and inspired our `/usr/bin/security`-based keychain reading approach, which avoids the macOS Keychain access prompt entirely.

## License

MIT — see [LICENSE.md](LICENSE.md).
