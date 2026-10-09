//
//  NotificationManager.swift
//  Menu Bar Usage for Claude
//
//  Delivers the app's macOS notifications: session usage alerts (decided by
//  ThresholdTracker), the authentication-lost alert and the test banner.
//

import AppKit
import Foundation
import Observation
import UserNotifications

@Observable
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    /// The current macOS notification authorization status for this app.
    /// Refreshed each time the Notifications settings tab appears and
    /// once at app launch when polling starts.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Delegate setup

    /// Registers this instance as the notification center's delegate so
    /// that `willPresent` is called even when the app is in the foreground.
    /// Also registers the interactive notification category for the
    /// auth-lost alert so the "Reauthenticate" action button appears.
    /// Must be called once, early in the app lifecycle (e.g. from
    /// `startPolling()`).
    func registerAsDelegate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reauthAction = UNNotificationAction(
            identifier: Self.reauthActionIdentifier,
            title: "Reauthenticate",
            options: []
        )
        let authLostCategory = UNNotificationCategory(
            identifier: Self.authLostCategoryIdentifier,
            actions: [reauthAction],
            intentIdentifiers: []
        )

        let manageUsageAction = UNNotificationAction(
            identifier: Self.manageUsageActionIdentifier,
            title: "Manage Usage",
            options: [.foreground]
        )
        let thresholdCategory = UNNotificationCategory(
            identifier: Self.thresholdCategoryIdentifier,
            actions: [manageUsageAction],
            intentIdentifiers: []
        )

        // setNotificationCategories replaces all categories, so both
        // must be registered in a single call.
        center.setNotificationCategories([authLostCategory, thresholdCategory])
    }

    /// Always present banners and play sounds, even when the app is in the
    /// foreground. Without this, macOS silences notifications whenever the
    /// popover, Settings, or onboarding window is the key window — which
    /// is exactly when the user is most likely to trigger a threshold-
    /// crossing fetch via `refreshNow()`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Handles notification interactions by mapping them to an
    /// ``Interaction`` and performing it on the main actor. The mapping is
    /// a pure static function so it can be unit-tested without a
    /// `UNNotificationResponse`, which has no public initialiser.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        guard let interaction = Self.interaction(category: category, action: action) else { return }
        await MainActor.run { self.perform(interaction) }
    }

    // MARK: - Interaction routing

    /// What a notification interaction asks the app to do.
    nonisolated enum Interaction: Equatable, Sendable {
        /// The auth-lost notification was clicked, or its "Reauthenticate"
        /// button pressed.
        case reauthenticate
        /// The "Manage Usage" button on a threshold notification was pressed.
        case openUsageSettings
    }

    /// Invoked for ``Interaction/reauthenticate``. `UsageStore` wires this
    /// to `manualRetry()` in `startPolling()` so the notification runs the
    /// same path as the popover's "Try again" button: clear the credential
    /// cache, reset the retry guards, re-read the Keychain, and only then
    /// launch `claude` if the token is genuinely expired.
    ///
    /// The previous implementation called `CredentialRefresher` directly
    /// from the delegate callback. That launched the CLI but never told
    /// the store, so nothing re-read the Keychain until the next poll
    /// tick — the notification appeared to do nothing, while clicking the
    /// menu bar icon (which does re-read) worked immediately.
    var reauthenticateHandler: (() -> Void)?

    /// Maps a delivered notification's category and the action the user
    /// chose to the ``Interaction`` it represents, or `nil` when nothing
    /// should happen (dismissal, or clicking a banner with no click
    /// behaviour).
    nonisolated static func interaction(category: String, action: String) -> Interaction? {
        switch (category, action) {
        case (authLostCategoryIdentifier, UNNotificationDefaultActionIdentifier),
             (authLostCategoryIdentifier, reauthActionIdentifier):
            return .reauthenticate
        case (thresholdCategoryIdentifier, manageUsageActionIdentifier):
            return .openUsageSettings
        default:
            return nil
        }
    }

    /// Performs an interaction. Split from the delegate callback so tests
    /// can drive it directly.
    func perform(_ interaction: Interaction) {
        switch interaction {
        case .reauthenticate:
            reauthenticateHandler?()
        case .openUsageSettings:
            if let url = URL(string: "https://claude.ai/settings/usage") {
                BrowserHelper.open(url)
            }
        }
    }

    // MARK: - Threshold tracking

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var sessionAlerts: ThresholdTracker

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sessionAlerts = ThresholdTracker.load(from: defaults) ?? ThresholdTracker()
        super.init()
    }

    // MARK: - Authorization

    /// Re-reads the authorization status from `UNUserNotificationCenter`.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Requests notification authorization for the first time. Only has
    /// an effect when `authorizationStatus == .notDetermined` — once the
    /// user has responded to the system prompt, subsequent calls are
    /// no-ops and the status settles to `.authorized` or `.denied`.
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorizationStatus()
    }

    /// Opens System Settings → Notifications so the user can re-enable
    /// notifications after previously denying them.
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Evaluation

    private static let thresholdSettings = [
        50: SettingsKeys.notifyAt50Percent,
        75: SettingsKeys.notifyAt75Percent,
        90: SettingsKeys.notifyAt90Percent,
    ]

    private var canDeliver: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    /// Called after each successful usage fetch. Delivers the session alerts
    /// the tracker says are due and saves the tracker when it changes.
    func evaluateThresholds(snapshot: UsageSnapshot) {
        let before = sessionAlerts
        let events = sessionAlerts.evaluate(
            fraction: snapshot.session.fraction,
            resetsAt: snapshot.session.resetsAt,
            enabled: Set(Self.thresholdSettings.filter { defaults[$0.value] }.keys),
            resetAlertEnabled: defaults[SettingsKeys.notifyOnReset],
            canDeliver: canDeliver
        )
        if sessionAlerts != before {
            sessionAlerts.save(to: defaults)
        }
        for event in events {
            deliver(event)
        }
    }

    // MARK: - Test

    /// Sends a test notification so the user can verify delivery works.
    /// Refreshes authorization status first so the result is accurate.
    func sendTestNotification() async {
        await refreshAuthorizationStatus()
        deliverNotification(
            title: "Test Notification",
            body: "Notifications from Menu Bar Usage for Claude are working.",
            identifier: "usage-test",
            categoryIdentifier: Self.thresholdCategoryIdentifier
        )
    }

    // MARK: - Private helpers

    private func deliver(_ event: ThresholdTracker.Event) {
        switch event {
        case .crossed(let percent):
            deliverNotification(
                title: "Claude Usage Alert",
                body: "Your current session usage has reached \(percent)%.",
                identifier: "usage-threshold-\(percent)",
                categoryIdentifier: Self.thresholdCategoryIdentifier
            )
        case .windowReset:
            deliverNotification(
                title: "Claude Usage Reset",
                body: "Your session usage limit has reset. You're good to go!",
                identifier: "usage-reset"
            )
        }
    }

    private func deliverNotification(
        title: String,
        body: String,
        identifier: String,
        categoryIdentifier: String? = nil
    ) {
        guard canDeliver else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Authentication-lost notification

    private static let authLostCategoryIdentifier = "auth-lost"
    private static let reauthActionIdentifier = "reauth-action"
    private static let thresholdCategoryIdentifier = "usage-threshold"
    private static let manageUsageActionIdentifier = "manage-usage-action"

    /// Guards one-shot delivery: set after firing, cleared only when
    /// authentication is restored (successful API response).
    private var hasFiredAuthLostNotification = false

    /// Delivers a notification informing the user that authentication
    /// has been lost. Only fires once per auth-loss event — subsequent
    /// calls are no-ops until ``authenticationRestored()`` resets the
    /// flag.
    func notifyAuthenticationLost() {
        guard !hasFiredAuthLostNotification else { return }
        guard canDeliver else { return }
        hasFiredAuthLostNotification = true
        let content = UNMutableNotificationContent()
        content.title = "Authentication Lost"
        content.body = "Menu Bar Usage for Claude can no longer access your Claude credentials. Tap to reauthenticate."
        content.sound = .default
        content.categoryIdentifier = Self.authLostCategoryIdentifier
        let request = UNNotificationRequest(
            identifier: "auth-lost-notification",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Resets the one-shot guard so the auth-lost notification can fire
    /// again the next time authentication is lost. Called by `UsageStore`
    /// after a successful API response confirms credentials are working.
    func authenticationRestored() {
        hasFiredAuthLostNotification = false
    }
}
