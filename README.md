# Menu Bar Usage for Claude

A native macOS menu bar app that tracks your Claude Code usage quotas — the same three progress bars that Claude Desktop shows (*Current Session*, *Weekly Limit*, and *Sonnet* for Max plans), available at a glance from the menu bar without having to open Claude Desktop or run `claude /status` in a terminal.

Built with SwiftUI, `MenuBarExtra`, and Observation for macOS 26+.

![Screenshot of the Menu Bar Usage for Claude popover showing a Current Session bar at 17 percent with 4 hours until reset and a Weekly Limit bar at 2 percent with 8 hours until reset. The macOS menu bar above it shows the app's gauge icon displaying 17 percent.](docs/screenshot.png)

> **Disclaimer.** This project is not affiliated with or endorsed by Anthropic. It reads from an undocumented community-discovered endpoint (`/api/oauth/usage`) that Claude Code itself uses for its status line, authenticated with the OAuth token that the `claude` CLI already stored in your login keychain. The endpoint is not a stable public API and may change or be removed at any time.

## Purpose

If you're a Claude Pro or Max subscriber and you use Claude Code, you probably want to know how much of your current-session, weekly, and Sonnet-weekly quotas you have left — without having to open Claude Desktop, context-switch into a terminal, or run `/status` inside an active session. This app puts those three bars in your menu bar, refreshes them every 2–5 minutes in the background, and optionally displays the current session percentage next to the menu bar icon.

## Features

- **Three live quota bars** that mirror Claude Desktop:
  - **Current Session** — the 5-hour rolling window
  - **Weekly Limit** — the 7-day rolling all-models window
  - **Sonnet** — the 7-day rolling Sonnet-only window (Max plans only; hidden on Pro)
- **Read-only Extra Usage card** — appears automatically when you enable Extra Usage at [claude.ai/settings/usage](https://claude.ai/settings/usage). Shows used vs. monthly cap, credits remaining, and a link back to the web UI for management.
- **Menu bar gauge icon** with an SF Symbol that tints itself based on peak utilisation (0% / 33% / 67% / 100%), plus an optional text percentage next to the icon for the current session.
- **Tabbed Settings window** (`General` + `Developer`):
  - Launch at login (via `SMAppService.mainApp`)
  - Show session percentage in menu bar
  - Refresh interval picker (2 / 3 / 4 / 5 minutes, default 5)
  - Live diagnostic counters: total network requests, last attempt, last success, tracking window, average rate
  - Live rate-limit cooldown indicator
  - Force Refresh and Reset Counters actions
- **First-run onboarding window** — a dedicated Welcome window that explains what the app does before the first Keychain access is attempted.
- **Live rate-limit countdown** — when the endpoint responds with HTTP 429, the popover shows a real-time "Retrying in 4m 23s" countdown sourced from the store's `rateLimitedUntil` timestamp, with a minimum 60-second cooldown floor to protect the endpoint even if the server returns `Retry-After: 0`.

## Authentication

The app reuses the OAuth credentials that the `claude` CLI already wrote to your login keychain. It does **not** ask you to sign in again, does **not** need an API key, and does **not** store any credentials of its own.

Specifically:

- **Keychain item.** `kSecClassGenericPassword` with service name `Claude Code-credentials`, created by Claude Code when you first run `claude` → `/login`. The data is a JSON blob containing an OAuth access token, refresh token, expiry, scopes, and subscription tier. The app reads it via `/usr/bin/security find-generic-password` — this binary is already on the keychain item's ACL, so reads succeed silently without triggering a macOS Keychain access prompt. Falls back to `SecItemCopyMatching` (which may prompt) if the CLI approach fails.
- **Endpoint.** `GET https://api.anthropic.com/api/oauth/usage`, with headers `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`. Returns the session / weekly / Sonnet utilisation windows and the Extra Usage state. This is the same endpoint the `claude` CLI's status line hits.
- **Sandbox:** Disabled because the app needs to launch `/usr/bin/security` to read keychain items created by Claude Code, and sandboxed apps cannot spawn arbitrary processes. As such, this app can't be published to the App Store.
- **What the app does not do:** No analytics, no telemetry, no remote logging. Every network request goes directly from your Mac to `api.anthropic.com` over HTTPS. The OAuth token never leaves your machine.

## Project Structure

```
ClaudeUsage/
├── ClaudeUsage.xcodeproj/            # Xcode project
└── ClaudeUsage/                      # Source tree (PBXFileSystemSynchronizedRootGroup)
    ├── MenuBarUsageForClaudeApp.swift  # @main, scenes, SettingsKeys, WindowIDs, AppReset, MenuBarLabel
    ├── KeychainCredentials.swift       # /usr/bin/security wrapper for Claude Code-credentials
    ├── UsageStore.swift                # @Observable store, API client, polling loop, snapshot builder
    ├── UsagePopoverView.swift          # Menu bar popover: bars, Extra Usage card, rate-limit/error views
    ├── OnboardingWindowView.swift      # First-run Welcome window
    ├── SettingsView.swift              # Tabbed settings (General + Developer)
    └── Assets.xcassets/                # App icon and accent color
```

### Architecture notes

- **`UsageStore`** is the single source of truth, an `@Observable @MainActor` class that owns the background poll task, the fetch state machine, and all diagnostic counters. Views observe it via `@Environment(UsageStore.self)`.
- **`MenuBarLabel.task`** is the only place the app starts polling. If `hasCompletedOnboarding` is `false`, it opens the `OnboardingWindowView` instead of touching the Keychain, so the very first `KeychainCredentialStore.load()` call happens only after the user clicks Continue.
- **Three poll-entry points** — the background loop (`startPolling`), the popover-open debounced refresh (`refreshNow`, 15 s debounce), and manual refresh buttons — all funnel through a single `refresh(minIntervalSinceLastSuccess:)` method with three layers of guards: re-entrancy, debounce, and rate-limit cooldown.
- **Scenes** — the app declares three SwiftUI scenes: `MenuBarExtra` for the menu bar popover, `Window` for the onboarding flow, and `Settings` for the preferences window. All three receive the `UsageStore` via `.environment(usage)` so they can interact with the same state.

## Build

### Requirements

- macOS 26 (Tahoe) or later — the deployment target is `MACOSX_DEPLOYMENT_TARGET = 26.4`
- Xcode 26.4 or later
- Claude Code installed and signed in:
  ```sh
  # Install (pick one)
  npm install -g @anthropic-ai/claude-code
  # or
  brew install claude

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
3. The three bars populate and the menu bar icon updates.

### Production deployment

For day-to-day use outside of Xcode, copy the built **`Menu Bar Usage for Claude.app`** into `/Applications`, then launch it from there. This matters for the **Launch at login** feature — `SMAppService.mainApp` registers the current bundle path with LaunchServices, so registering from a DerivedData location causes `.notFound` errors on next login. Running from `/Applications` avoids this entirely. (The app's onboarding flag is hashed against the bundle path, so moving to `/Applications` re-shows the welcome window once.)

## Alternatives

- **[Notch Pilot](https://github.com/devmegablaster/Notch-Pilot)** — A macOS app that displays Claude Code usage in the Dynamic Island / notch area. Notch Pilot also reads from the same undocumented usage endpoint and inspired our `/usr/bin/security`-based keychain reading approach, which avoids the macOS Keychain access prompt entirely.

## License

MIT — see [LICENSE.md](LICENSE.md).
