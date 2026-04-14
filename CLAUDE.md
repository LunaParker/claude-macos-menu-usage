# CLAUDE.md - Menu Bar Usage for Claude

## Project Overview

A native macOS menu bar app (SwiftUI) that displays Claude Code usage quotas — session, weekly limit, and Sonnet (for Max subscribers) — by polling the undocumented `/api/oauth/usage` endpoint using OAuth credentials stored in the macOS login keychain by the `claude` CLI.

- **Bundle ID:** `com.shyowlstudios.ClaudeUsage`
- **Product name:** `Menu Bar Usage for Claude`
- **Minimum macOS:** 26.4
- **Sandbox:** Disabled (required to read Keychain items written by `claude` CLI)
- **Hardened runtime:** Enabled
- **No external dependencies** — pure SwiftUI + Foundation

## Project Structure

```
ClaudeUsage/
  MenuBarUsageForClaudeApp.swift  — @main app entry, MenuBarExtra scene, single-instance
                                    enforcement, factory reset, SettingsKeys enum
  UsageStore.swift                — @Observable data store, API client, polling loop,
                                    rate-limit handling, credential refresh orchestration
  UsagePopoverView.swift          — Popover UI: quota bars, Extra Usage card, error/
                                    rate-limit countdown views
  SettingsView.swift              — Settings window: General, Notifications, Developer tabs
  OnboardingWindowView.swift      — First-run welcome flow, Keychain permission primer
  NotificationManager.swift       — macOS notification delivery, threshold tracking,
                                    session-window rotation detection
  KeychainCredentials.swift       — Keychain query for Claude Code OAuth credentials,
                                    credential parsing, background CLI token refresh
  ClaudeUsage.entitlements        — Disables sandbox, hardened runtime defaults
  Assets.xcassets/                — App icon (white gauge on orange gradient), accent color
```

### Architecture

- **UsageStore** is the single source of truth. All views observe it via `@Environment`.
- Three refresh entry points (background poll, popover-open debounce, manual button) funnel through one guarded `refresh()` method with re-entrancy, debounce, and rate-limit layers.
- Onboarding gates polling — Keychain access only happens after the user completes onboarding and understands the permission prompt.
- The onboarding flag is scoped to the bundle path hash, so moving the app or rebuilding from DerivedData re-triggers onboarding.

## Usage API

The app polls `GET https://api.claude.ai/api/oauth/usage` (undocumented endpoint used by Claude Code itself).

**Required headers:**
- `Authorization: Bearer <accessToken>`
- `anthropic-beta: oauth-2025-04-20`
- Custom `User-Agent` identifying the app

**Response shape (`UsageResponse`):**
- `fiveHour` — 5-hour rolling session window (capacity + usage + resetsAt)
- `sevenDay` — 7-day weekly limit (capacity + usage + resetsAt)
- `sevenDayOpus` — weekly Opus usage (Max subscribers only)
- `sevenDaySonnet` — weekly Sonnet usage (Max subscribers only, displayed as a fourth bar)
- `extraUsage` — paid overflow credits (used, remaining, monthlyLimit)

The response is decoded into a `UsageSnapshot` with pre-computed `Bar` values (fraction 0...1, percent label, reset time). `peakUtilization` (max of all bar fractions) drives the menu bar icon variant.

**Rate-limit handling:** HTTP 429 responses set a cooldown (`rateLimitedUntil`) using the `Retry-After` header with a 60-second floor. The popover shows a live countdown during cooldown.

## Keychain Credentials

OAuth credentials are stored by the `claude` CLI in the macOS login keychain:
- **Service:** `Claude Code-credentials`
- **Class:** `kSecClassGenericPassword` (no account filter — one credential per user)

**JSON envelope shape:**
```json
{
  "accessToken": "...",
  "refreshToken": "...",
  "expiresAt": 1234567890000,   // milliseconds since epoch
  "scopes": ["..."],
  "subscriptionType": "max",    // or "pro", etc.
  "rateLimitTier": "..."
}
```

Key computed properties on `ClaudeCredentials`:
- `isExpired` — compares `expiresAt` (ms) to current time
- `isMaxSubscription` — determines whether the Sonnet bar should display

**Auto-refresh:** When credentials are expired, `CredentialRefresher.refreshInBackground()` launches the `claude` CLI hidden in the background via `/bin/bash -l -c "command -v claude && claude"` with stdin/stdout/stderr redirected to `/dev/null` and a 30-second timeout. The CLI refreshes the token in the keychain on startup; the app picks up the fresh credentials on the next poll.

## Notification Threshold Logic

`NotificationManager` tracks and delivers macOS notifications for usage milestones:

- **Thresholds:** 50%, 75%, 90% of session capacity (each individually toggleable in Settings)
- **Deduplication:** `firedThresholds: Set<Int>` ensures each threshold fires only once per session window
- **Window rotation detection:** Compares `resetsAt` timestamps with a 2-second tolerance (the API jitters fractional seconds between responses; session windows are 5 hours apart so this is safe). When the session window rotates:
  - If the previous window reached 100% (`sawCapacity` flag), a "capacity reset" notification fires (if enabled)
  - `firedThresholds` is re-seeded with thresholds already exceeded in the new window (prevents false re-fires)
  - `sawCapacity` is cleared
- **Authorization:** Requests notification permission on first toggle; shows "Open Notification Settings" if previously denied

## Build Verification

**After every batch of code changes, rebuild the project to verify it compiles:**

```bash
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release build 2>&1 | tail -3
```

The last line must read `** BUILD SUCCEEDED **`. If it does not, fix all errors before proceeding.

## Build, Archive & Deploy

Once all changes in a batch are complete and the build succeeds, **ask the user** whether they would like to build and archive the app, then install it to `~/Applications`. If the user confirms the build, also ask whether they would like to commit and push the changes to the remote.

If the user confirms, run:

```bash
# 1. Clean build Release
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release clean build 2>&1 | tail -3

# 2. Kill the running app if it exists
pkill -x "Menu Bar Usage for Claude" 2>/dev/null; sleep 1

# 3. Copy the built .app to ~/Applications, replacing the existing copy
rm -rf ~/Applications/Menu\ Bar\ Usage\ for\ Claude.app
cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeUsage-advaaptdjppahfecvxrnwhzgbjev/Build/Products/Release/Menu\ Bar\ Usage\ for\ Claude.app ~/Applications/

# 4. Relaunch the app
open ~/Applications/Menu\ Bar\ Usage\ for\ Claude.app
```

> **Note:** The DerivedData hash (`advaaptdjppahfecvxrnwhzgbjev`) is stable for this project unless the workspace is regenerated. If the path doesn't exist, re-derive it with:
> ```bash
> xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release -showBuildSettings 2>/dev/null | grep ' CONFIGURATION_BUILD_DIR'
> ```
