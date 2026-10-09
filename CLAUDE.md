# CLAUDE.md - Menu Bar Usage for Claude

## Project Overview

A native macOS menu bar app (SwiftUI) that displays Claude Code usage quotas — session, weekly limit, and (on Max plans) the model-scoped Fable weekly limit — by polling the undocumented `/api/oauth/usage` endpoint using OAuth credentials stored in the macOS login keychain by the `claude` CLI.

- **Bundle ID:** `com.shyowlstudios.ClaudeUsage`
- **Product name:** `Menu Bar Usage for Claude`
- **Minimum macOS:** 26.4
- **Language mode:** Swift 6, default actor isolation `MainActor`, Approachable Concurrency
- **Sandbox:** Disabled (required to launch `/usr/bin/security` to read Keychain items written by `claude` CLI)
- **Hardened runtime:** Enabled
- **No external dependencies** — pure SwiftUI + Foundation

## Project Structure

```
ClaudeUsage/
  MenuBarUsageForClaudeApp.swift — @main app: scenes, owns UsageStore, StatusStore and
                                   NotificationManager, launch-time side effects
  AppLifecycle.swift             — LaunchContext (unit-test host detection), SingleInstance,
                                   AppReset (factory reset)
  Settings.swift                 — SettingKey<Value> + SettingsKeys (keys with defaults),
                                   @AppStorage/UserDefaults helpers, PreferenceMigrations, WindowIDs
  MenuBarLabel.swift             — Menu bar gauge icon + optional percentage; starts polling
                                   or opens onboarding
  UsageStore.swift               — @Observable store: polling, refresh triggers, credential cache,
                                   fetch outcomes, background-refresh state machine
  UsageState.swift               — UsageFailure, UsagePresentation, AuthPhase, RefreshPolicy
  UsageAPI.swift                 — Wire format, UsageFetching, UsageAPIClient, date decoding
  UsageSnapshot.swift            — Display model and its builder
  HTTPClient.swift               — Ephemeral session shared by both clients, RetryAfter,
                                   RateLimitPolicy, LegacyURLCache cleanup
  KeychainCredentials.swift      — ClaudeCredentials, CredentialSource/KeychainCredentialSource
                                   (off-main reads), KeychainCredentialStore (security CLI,
                                   SecItemCopyMatching, ~/.claude/.credentials.json)
  ClaudeCLI.swift                — ClaudeCLILocator, RefreshStrategy, ClaudeCLIRefresher (launch
                                   + timeout), CredentialRefreshing/ClaudeRefreshService
  ProcessRunner.swift            — Short-lived helper processes with a kill timeout
  Scheduler.swift                — Delayed main-actor work behind a protocol (tests run it on demand)
  DisplaySleepMonitor.swift      — Display sleep/wake tracking (DarkWake keeps displays off)
  NotificationManager.swift      — macOS notifications: usage alerts, auth-lost, test banner
  ThresholdTracker.swift         — Pure, persisted session-alert decisions
  StatusStore.swift              — status.claude.com: components, snapshot, client, store
  DiagnosticLog.swift            — Diagnostic log (unified log + file + in-memory list), LogSink
  DiagnosticLogView.swift        — Diagnostic Log window
  UsagePopoverView.swift         — Popover: quota bars, Extra Usage card, failure views, status row,
                                   CapsuleBar, MenuBarPanel
  SettingsView.swift             — Settings window: General, Notifications, Developer tabs
  OnboardingWindowView.swift     — First-run welcome flow, Keychain permission primer
  BrowserHelper.swift            — Opens links in the preferred browser
  ClaudeUsage.entitlements       — Disables sandbox, hardened runtime defaults
  Assets.xcassets/               — App icon (white gauge on orange gradient), accent color
ClaudeUsageTests/                — Swift Testing suites; Support/ holds fakes and stubs
scripts/deploy.sh                — Release build, install to ~/Applications, relaunch
```

### Architecture

- **UsageStore** is the single source of truth. All views observe it via `@Environment`. It takes its collaborators through `UsageStore.Dependencies` (credential source, fetcher, refresher, notifier, scheduler, display state, clock, defaults), so the tests drive it with fakes.
- The store keeps `snapshot` (last good data) and `failure` (a typed `UsageFailure`) side by side. `UsagePresentation` decides what the popover shows: failures only the user can fix (signed out, unreadable credentials, sign-in expired, `claude` not found) replace the bars; transient ones (offline, server error, unexpected response, 429, a refresh in progress) keep them with a footer notice. The menu bar keeps the last values through a transient failure but drops data older than 30 minutes.
- Every refresh goes through `refresh(trigger:)`. Triggers are `.poll`, `.popover` (debounced 60 s against the last success), `.manual` ("Try again", the Reauthenticate notification and Force Refresh, via `manualRetry()`), `.retry`, `.postRefresh` and `.wake` (debounced like `.popover`). Guards, in order: re-entrancy (a `.postRefresh` or `.manual` call that arrives mid-refresh reruns once it ends), display sleep (everything except `.manual` is skipped while the displays are asleep), the debounce, then the 429 cooldown.
- Transient failures retry after 30 s, doubling up to the poll interval; a success cancels the retry.
- **Display sleep:** the poll timer would otherwise fire in DarkWake, the brief maintenance wakes during sleep, where nobody sees the result and a launched `claude` freezes mid-refresh when the Mac sleeps again. `DisplaySleepMonitor` follows `screensDidSleep`/`screensDidWake`; five seconds after the displays wake the store fetches once (never before onboarding has finished).
- A 401/403 on a cached token is treated as a possible token rotation first: the store re-reads the Keychain and silently retries once if it finds a different, unexpired token (Claude Code rotates the access token on every refresh and the old one is rejected immediately). Only if that fails does the background refresh start.
- Onboarding gates polling — Keychain access only happens after the user completes onboarding. The flag is one global key (`hasCompletedOnboarding`); `PreferenceMigrations` carries over the old bundle-path-scoped keys.
- Notification actions go through the store: the app wires `NotificationManager.reauthenticateHandler` to `UsageStore.manualRetry()`, which re-reads the Keychain afterwards. Never launch the refresh directly from a notification.

## Usage API

The app polls `GET https://api.anthropic.com/api/oauth/usage` (undocumented endpoint used by Claude Code itself).

**Required headers:**
- `Authorization: Bearer <accessToken>`
- `anthropic-beta: oauth-2025-04-20`
- `User-Agent` identifying the app, `MenuBarUsageForClaude/<CFBundleShortVersionString> (macOS menu bar)`

**Response shape (`UsageResponse`):**
- `fiveHour` — 5-hour rolling session window (capacity + usage + resetsAt)
- `sevenDay` — 7-day weekly limit (capacity + usage + resetsAt)
- `limits` — generalised limits array (`kind`, integer `percent` 0–100, `resets_at`, `scope`). The model-scoped weekly quota (currently Fable, Max 5x/20x only) exists **only** here as a `weekly_scoped` entry — there is no `seven_day_fable` field. The bar is presence-gated and titled from `scope.model.display_name`.
- `extraUsage` — paid overflow credits (used, remaining, monthlyLimit)

`seven_day_opus` is returned but not decoded. The response is decoded into a `UsageSnapshot` with pre-computed `Bar` values (fraction 0...1, percent label, reset time). `peakUtilization` (max of all bar fractions) drives the menu bar icon variant.

**Networking:** both API clients send through `HTTPClient`, an ephemeral `URLSession` with no URL cache and no cookie storage. `URLSession.shared` used to write every response, with its request (bearer token included), into `~/Library/Caches/com.shyowlstudios.ClaudeUsage/Cache.db`; launch deletes that cache and sets `URLCache.shared` to zero capacity. The usage request times out after 20 s, the status request after 10 s.

**Rate-limit handling:** HTTP 429 responses set a cooldown (`rateLimitedUntil`) using the `Retry-After` header with a 60-second floor (`RateLimitPolicy`). The popover shows a live countdown during cooldown.

## Keychain Credentials

OAuth credentials are stored by the `claude` CLI in the macOS login keychain:
- **Service:** `Claude Code-credentials`
- **Class:** `kSecClassGenericPassword`

**Reading credentials:** The app reads credentials by shelling out to `/usr/bin/security find-generic-password` rather than calling `SecItemCopyMatching`. When Claude Code writes the keychain item, `/usr/bin/security` ends up on the item's ACL, so subsequent reads via the same binary succeed silently — no macOS Keychain access prompt. A two-pass lookup tries the current macOS username as the account field first (the post-refresh entry), then falls back to no account filter (the initial-login entry). If both `/usr/bin/security` passes fail, the app falls back to `SecItemCopyMatching` (which may trigger a Keychain prompt but ensures the app still works if the ACL changes). `KeychainCredentialSource` runs all of this on a background queue, never the main thread, and `security` is killed if it takes longer than 5 s.

**Plaintext fallback:** When a Keychain write fails (a non-zero `security` exit; a timeout doesn't count), Claude Code writes the same JSON to `~/.claude/.credentials.json` and **deletes the Keychain item**. Its next successful Keychain write moves the credentials back and deletes the file. So when `SecItemCopyMatching` also reports the item missing, `load()` reads that file (`KeychainReadMethod.credentialsFile`). The file also holds MCP servers' OAuth tokens (`mcpOAuth`), so it can exist without a `claudeAiOauth` entry, which reads as not signed in.

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

`ClaudeCredentials` deliberately doesn't decode `refreshToken`: the app never uses it, so it never holds it. `isExpired` compares `expiresAt` (ms) to the current time.

**Background refresh:** When the token is unusable (expired, or rejected with no rotated replacement in the Keychain), the store launches `claude mcp list` so Claude Code refreshes its own token and writes it back to the Keychain. Bare `claude` needs a TTY and never reaches the OAuth refresh; `claude auth status` only reports cached state. Don't switch commands without proving the refresh against a genuinely expired token.

- `ClaudeCLILocator` finds the binary without a shell: the cached path (`claudeCLIPath` in defaults), then `~/.local/bin` (native installer), `~/.claude/local`, Homebrew, npm, Bun and Volta locations. When none has it, a background login-shell `command -v claude` finds and caches it.
- The first attempt of an outage launches `claude` directly, with its folder first on PATH. Every later attempt uses the proven login-shell launch: `<shell> -i -l -c 'command -v claude >/dev/null 2>&1 || exit 127; exec claude mcp list'`. Exit 127 means `claude` isn't on the login shell's PATH.
- `claude` runs in an empty per-user folder under `$TMPDIR` (`ClaudeUsage-refresh`), not `/tmp`: anyone can write to `/tmp`, and Claude Code reads project config such as `.mcp.json` from its working directory. Either way it stays out of TCC-protected folders.
- stdin/stdout/stderr go to `/dev/null`. A 30-second timeout, on the suspending clock so time asleep doesn't count, kills a hung process.
- The store's `AuthPhase` drives the flow: `.ok` → `.refreshing(attempt, pid, strategy)` → `.checking` when the process exits (the Keychain is re-read once, 2 s later) → back to `.ok`, or `.waiting(failedAttempts, until)`. `RefreshPolicy` sets the backoff: a failed direct launch retries through the login shell 30 s later without telling the user; a failed login-shell launch posts "Authentication Lost" (once per outage) and backs off 5, 5, 15, then 60 minutes. Exit 127 shows "Couldn't find the claude command" and re-checks hourly. A manual retry skips the wait.
- A success in any phase ends the outage and only **detaches** from a still-running process; its exit is ignored because its pid no longer matches. Never signal it: SIGTERMing `claude` mid-write fails its Keychain write and triggers the plaintext fallback above. That happened on 2026-09-26, when a kill landed as the CLI resumed after a DarkWake. Only the 30-second timeout kills the process.
- `NotificationManager.authenticationRestored()` removes a delivered "Authentication Lost" banner once credentials work again; launch clears one left over from a previous run.

## Notification Threshold Logic

`ThresholdTracker` decides which session alerts are due; `NotificationManager` delivers them and saves the tracker (under `sessionAlertTracker` in defaults) whenever it changes, so a relaunch in the same window doesn't repeat an alert.

- **Thresholds:** 50%, 75%, 90% of session capacity (each individually toggleable in Settings)
- **Deduplication:** each threshold fires at most once per session window. A crossing waits, unconsumed, until the threshold is enabled and notification permission is granted.
- **Window rotation detection:** Compares `resetsAt` timestamps with a 2-second tolerance (the API jitters fractional seconds between responses; session windows are 5 hours apart so this is safe). When the session window rotates:
  - If the previous window reached 100% (`sawCapacity`), a "capacity reset" notification fires (if enabled)
  - The fired set is re-seeded with the thresholds already exceeded except the highest, so a launch or new window fires at most one alert
  - `sawCapacity` is cleared
- **Authorization:** Requests notification permission on first toggle; shows "Open Notification Settings" if previously denied

## Diagnostic Log

`DiagnosticLog.log(_:_:)` works from any thread and stamps the entry when called. Each entry goes to:
- the unified log (subsystem `com.shyowlstudios.ClaudeUsage`, one category per log category, messages public);
- `~/Library/Logs/ClaudeUsage/diagnostic.log` (millisecond timestamps, trimmed to the newest 256 KB whenever it passes 512 KB);
- the Diagnostic Log window's list (newest 500, kept in time order).

To see app events next to the system's own: `/usr/bin/log show --predicate 'subsystem == "com.shyowlstudios.ClaudeUsage" OR process == "security"'` (zsh's `log` builtin shadows `/usr/bin/log`). A unit-test host logs to a scratch file instead.

## Tests

The unit tests run inside the app (`TEST_HOST`). `LaunchContext.isUnitTestHost` makes the launch code skip single-instance enforcement (which would quit the installed copy), preference migrations, the cache cleanup, onboarding and polling. Tests must use throwaway `UserDefaults` suites (`TestDefaults.make()`), never `.standard`, which is the real app's preferences domain.

```bash
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Debug -destination 'platform=macOS' test
```

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
scripts/deploy.sh
```

It clean-builds Release into `./build` (`-derivedDataPath build`, so the DerivedData hash doesn't matter), quits the running app, replaces `~/Applications/Menu Bar Usage for Claude.app` and relaunches it. `scripts/deploy.sh --build-only` stops after the build.
