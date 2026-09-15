# CLAUDE.md - Menu Bar Usage for Claude

## Project Overview

A native macOS menu bar app (SwiftUI) that displays Claude Code usage quotas — session, weekly limit, and (on Max plans) the model-scoped Fable weekly limit — by polling the undocumented `/api/oauth/usage` endpoint using OAuth credentials stored in the macOS login keychain by the `claude` CLI.

- **Bundle ID:** `com.shyowlstudios.ClaudeUsage`
- **Product name:** `Menu Bar Usage for Claude`
- **Minimum macOS:** 26.4
- **Sandbox:** Disabled (required to launch `/usr/bin/security` to read Keychain items written by `claude` CLI)
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
  KeychainCredentials.swift       — /usr/bin/security wrapper for Claude Code OAuth
                                    credentials, credential parsing, background CLI
                                    token refresh
  ClaudeUsage.entitlements        — Disables sandbox, hardened runtime defaults
  Assets.xcassets/                — App icon (white gauge on orange gradient), accent color
```

### Architecture

- **UsageStore** is the single source of truth. All views observe it via `@Environment`.
- Four refresh entry points funnel through one guarded `refresh()` method with re-entrancy, debounce, and rate-limit layers: the background poll, the popover-open debounce, the popover's "Try again" button, and the auth-lost notification's "Reauthenticate" action. The last two share `manualRetry()`, which drops the credential cache and resets the retry guards first. The notification must go through the store (never `CredentialRefresher` directly), or nothing re-reads the Keychain afterwards.
- A 401/403 on a cached token is treated as a possible token rotation first: the store re-reads the Keychain and silently retries once if it finds a different, unexpired token (Claude Code rotates the access token on every refresh and the old one is rejected immediately). Only if that fails does it notify and launch the background CLI refresh.
- Onboarding gates polling — Keychain access only happens after the user completes onboarding.
- The onboarding flag is scoped to the bundle path hash, so moving the app or rebuilding from DerivedData re-triggers onboarding.

## Usage API

The app polls `GET https://api.anthropic.com/api/oauth/usage` (undocumented endpoint used by Claude Code itself).

**Required headers:**
- `Authorization: Bearer <accessToken>`
- `anthropic-beta: oauth-2025-04-20`
- Custom `User-Agent` identifying the app

**Response shape (`UsageResponse`):**
- `fiveHour` — 5-hour rolling session window (capacity + usage + resetsAt)
- `sevenDay` — 7-day weekly limit (capacity + usage + resetsAt)
- `sevenDayOpus` — weekly Opus usage (Max subscribers only; decoded but not displayed)
- `limits` — generalised limits array (`kind`, integer `percent` 0–100, `resets_at`, `scope`). The model-scoped weekly quota (currently Fable, Max 5x/20x only) exists **only** here as a `weekly_scoped` entry — there is no `seven_day_fable` field. The bar is presence-gated and titled from `scope.model.display_name`.
- `extraUsage` — paid overflow credits (used, remaining, monthlyLimit)

The response is decoded into a `UsageSnapshot` with pre-computed `Bar` values (fraction 0...1, percent label, reset time). `peakUtilization` (max of all bar fractions) drives the menu bar icon variant.

**Rate-limit handling:** HTTP 429 responses set a cooldown (`rateLimitedUntil`) using the `Retry-After` header with a 60-second floor. The popover shows a live countdown during cooldown.

## Keychain Credentials

OAuth credentials are stored by the `claude` CLI in the macOS login keychain:
- **Service:** `Claude Code-credentials`
- **Class:** `kSecClassGenericPassword`

**Reading credentials:** The app reads credentials by shelling out to `/usr/bin/security find-generic-password` rather than calling `SecItemCopyMatching`. When Claude Code writes the keychain item, `/usr/bin/security` ends up on the item's ACL, so subsequent reads via the same binary succeed silently — no macOS Keychain access prompt. A two-pass lookup tries the current macOS username as the account field first (the post-refresh entry), then falls back to no account filter (the initial-login entry). If both `/usr/bin/security` passes fail, the app falls back to `SecItemCopyMatching` (which may trigger a Keychain prompt but ensures the app still works if the ACL changes).

**JSON envelope shape:**
```json
{
  "claudeAiOauth": {
    "accessToken": "...",
    "refreshToken": "...",
    "expiresAt": 1234567890000,   // milliseconds since epoch
    "scopes": ["..."],
    "subscriptionType": "max",    // or "pro", etc.
    "rateLimitTier": "..."
  }
}
```

Key computed properties on `ClaudeCredentials`:
- `isExpired` — compares `expiresAt` (ms) to current time

**Auto-refresh:** When credentials are expired (or a 401 survives the Keychain re-read), `CredentialRefresher.refreshInBackground()` launches `claude mcp list` hidden in the background through the user's login shell (`<shell> -i -l -c "command -v claude &>/dev/null && claude mcp list"`, cwd `/tmp`, stdin/stdout/stderr on `/dev/null`, 30-second timeout). Bare `claude` needs a TTY and never reaches the OAuth refresh; `claude auth status` only reports cached state. The CLI writes the refreshed token to the keychain on startup. When the process exits, `UsageStore` clears its credential cache and re-fetches two seconds later (one automatic retry per outage, re-armed by `manualRetry()`).

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
