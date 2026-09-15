//
//  NotificationInteractionTests.swift
//  ClaudeUsageTests
//
//  Covers how `NotificationManager` routes notification interactions. The
//  delegate callback itself can't be exercised in a unit test because
//  `UNNotificationResponse` has no public initialiser, so the routing is
//  split into a pure (category, action) → `Interaction` mapping and a
//  `perform(_:)` step, both tested here.
//
//  The identifier strings are deliberately literal: they are what macOS
//  stores inside already-delivered notifications, so renaming them in the
//  app would orphan any banner still sitting in Notification Center.
//

import Foundation
import Testing
import UserNotifications
@testable import ClaudeUsage

@Suite("NotificationManager interaction routing")
struct NotificationInteractionTests {

    // MARK: (category, action) → Interaction

    @Test("Reauthenticate button on the auth-lost notification maps to .reauthenticate")
    func reauthenticateButton() {
        #expect(
            NotificationManager.interaction(category: "auth-lost", action: "reauth-action")
                == .reauthenticate
        )
    }

    @Test("tapping the auth-lost banner body also maps to .reauthenticate")
    func authLostDefaultAction() {
        #expect(
            NotificationManager.interaction(
                category: "auth-lost",
                action: UNNotificationDefaultActionIdentifier
            ) == .reauthenticate
        )
    }

    @Test("Manage Usage on a threshold notification maps to .openUsageSettings")
    func manageUsageButton() {
        #expect(
            NotificationManager.interaction(category: "usage-threshold", action: "manage-usage-action")
                == .openUsageSettings
        )
    }

    @Test("dismissing the auth-lost notification does nothing")
    func dismissIsIgnored() {
        #expect(
            NotificationManager.interaction(
                category: "auth-lost",
                action: UNNotificationDismissActionIdentifier
            ) == nil
        )
    }

    @Test("tapping a threshold banner body does nothing")
    func thresholdDefaultActionIsIgnored() {
        #expect(
            NotificationManager.interaction(
                category: "usage-threshold",
                action: UNNotificationDefaultActionIdentifier
            ) == nil
        )
    }

    @Test("an unknown category does nothing")
    func unknownCategoryIsIgnored() {
        #expect(NotificationManager.interaction(category: "usage-reset", action: "reauth-action") == nil)
    }

    // MARK: perform(_:)

    @Test("performing .reauthenticate invokes the store-wired handler exactly once")
    func reauthenticateInvokesHandler() {
        let manager = NotificationManager()
        var calls = 0
        manager.reauthenticateHandler = { calls += 1 }

        manager.perform(.reauthenticate)

        #expect(calls == 1)
    }

    @Test("performing .reauthenticate before a handler is wired is a no-op")
    func reauthenticateWithoutHandlerIsSafe() {
        let manager = NotificationManager()

        manager.perform(.reauthenticate)

        #expect(manager.reauthenticateHandler == nil)
    }
}
