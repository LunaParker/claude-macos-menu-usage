//
//  NotificationManager.swift
//  Menu Bar Usage for Claude
//
//  Manages macOS user notifications for session usage threshold alerts.
//  Evaluates each new UsageSnapshot against the user's opt-in thresholds
//  and delivers a notification when a threshold is crossed for the first
//  time in a given session window.
//

import AppKit
import Foundation
import Observation
import UserNotifications

@Observable
@MainActor
final class NotificationManager {

    /// The current macOS notification authorization status for this app.
    /// Refreshed each time the Notifications settings tab appears and
    /// once at app launch when polling starts.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Threshold tracking

    /// Thresholds (as integer percentages) that have already fired in the
    /// current session window. Cleared when `resetsAt` changes so each
    /// threshold can fire again in the new window.
    private var firedThresholds: Set<Int> = []

    /// The `resetsAt` date from the most recently evaluated snapshot.
    /// Used to detect when the session window has rotated.
    private var trackedResetsAt: Date?

    /// Set to `true` when we observe session utilisation at 100%.
    /// Cleared after the reset notification fires (or when the session
    /// window rotates without having reached capacity).
    private var sawCapacity: Bool = false

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

    /// The percentage thresholds that can trigger notifications.
    private static let thresholdPercents = [50, 75, 90]

    /// Called after each successful usage fetch. Compares the session bar
    /// against the user's enabled thresholds and delivers notifications
    /// for any newly crossed thresholds.
    func evaluateThresholds(snapshot: UsageSnapshot) {
        let fraction = snapshot.session.fraction
        let resetsAt = snapshot.session.resetsAt

        // Detect session window rotation (or first evaluation after launch).
        if !isSameResetTime(resetsAt, trackedResetsAt) {
            // Only fire the reset notification when we've actually been
            // tracking a previous window (not on first launch) AND that
            // window reached capacity.
            if trackedResetsAt != nil && sawCapacity {
                deliverResetNotificationIfEnabled()
            }
            // Pre-seed with thresholds already surpassed so we only fire
            // the highest applicable one — avoids a burst of stale alerts
            // on app launch or session window rotation.
            let exceeded = Self.thresholdPercents.filter { fraction >= Double($0) / 100.0 }
            firedThresholds = Set(exceeded.dropLast())
            sawCapacity = false
            trackedResetsAt = resetsAt
        }

        if fraction >= 1.0 {
            sawCapacity = true
        }

        checkThreshold(50, fraction: fraction, key: SettingsKeys.notifyAt50Percent)
        checkThreshold(75, fraction: fraction, key: SettingsKeys.notifyAt75Percent)
        checkThreshold(90, fraction: fraction, key: SettingsKeys.notifyAt90Percent)
    }

    // MARK: - Test

    /// Sends a test notification so the user can verify delivery works.
    /// Refreshes authorization status first so the result is accurate.
    func sendTestNotification() async {
        await refreshAuthorizationStatus()
        deliverNotification(
            title: "Test Notification",
            body: "Notifications from Menu Bar Usage for Claude are working.",
            identifier: "usage-test"
        )
    }

    // MARK: - Private helpers

    private func checkThreshold(_ percent: Int, fraction: Double, key: String) {
        let target = Double(percent) / 100.0
        guard fraction >= target,
              !firedThresholds.contains(percent),
              UserDefaults.standard.bool(forKey: key) else { return }
        // Only consume the threshold when delivery is possible. If
        // authorization hasn't been determined yet (startup race with
        // refreshAuthorizationStatus), the threshold stays unfired so
        // it can be re-checked on the next poll tick.
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        firedThresholds.insert(percent)
        deliverNotification(
            title: "Claude Usage Alert",
            body: "Your current session usage has reached \(percent)%.",
            identifier: "usage-threshold-\(percent)"
        )
    }

    /// Compares two optional reset-at dates with a tolerance window.
    /// The usage endpoint returns fractional seconds that jitter between
    /// responses for the same session window. The old `Int()` truncation
    /// approach broke when two timestamps straddled a whole-second
    /// boundary (e.g. …00.93 vs …01.07), causing false rotation
    /// detections that cleared `firedThresholds` and re-fired
    /// notifications. A 2-second tolerance eliminates jitter while
    /// still correctly detecting real 5-hour window rotations.
    private func isSameResetTime(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let a?, let b?):
            return abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) < 2
        }
    }

    private func deliverResetNotificationIfEnabled() {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifyOnReset) else { return }
        deliverNotification(
            title: "Claude Usage Reset",
            body: "Your session usage limit has reset. You're good to go!",
            identifier: "usage-reset"
        )
    }

    private func deliverNotification(title: String, body: String, identifier: String) {
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
