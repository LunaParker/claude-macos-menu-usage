//
//  SettingsTests.swift
//  ClaudeUsageTests
//
//  Typed setting keys carry their own default, and launch migrates
//  preferences written by older builds. Every test uses its own defaults
//  suite: the test host shares the real app's preferences domain.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("Settings")
struct SettingsTests {

    @Test("an unset setting reads as its default; a stored value wins")
    func defaultsAndOverrides() {
        let defaults = TestDefaults.make()

        #expect(defaults[SettingsKeys.serviceStatusEnabled] == true)
        #expect(defaults[SettingsKeys.pollIntervalSeconds] == 300)

        defaults.set(false, forKey: SettingsKeys.serviceStatusEnabled.name)
        defaults.set(180, forKey: SettingsKeys.pollIntervalSeconds.name)

        #expect(defaults[SettingsKeys.serviceStatusEnabled] == false)
        #expect(defaults[SettingsKeys.pollIntervalSeconds] == 180)
    }

    @Test("a completed path-scoped onboarding flag carries over to the single key")
    func onboardingCarriesOver() {
        let defaults = TestDefaults.make()
        defaults.set(true, forKey: "hasCompletedOnboarding_234b92955a64")
        defaults.set(false, forKey: "hasCompletedOnboarding_cd1e5fe2395d")

        PreferenceMigrations.run(on: defaults)

        #expect(defaults[SettingsKeys.hasCompletedOnboarding] == true)
        #expect(defaults.object(forKey: "hasCompletedOnboarding_234b92955a64") == nil)
        #expect(defaults.object(forKey: "hasCompletedOnboarding_cd1e5fe2395d") == nil)
    }

    @Test("without a completed path-scoped flag, onboarding stays pending")
    func onboardingStaysPending() {
        let defaults = TestDefaults.make()
        defaults.set(false, forKey: "hasCompletedOnboarding_cd1e5fe2395d")

        PreferenceMigrations.run(on: defaults)

        #expect(defaults[SettingsKeys.hasCompletedOnboarding] == false)
    }

    @Test("the removed Sonnet-bar setting is deleted")
    func removesSonnetSetting() {
        let defaults = TestDefaults.make()
        defaults.set(true, forKey: "hideSonnetBarWhenZero")

        PreferenceMigrations.run(on: defaults)

        #expect(defaults.object(forKey: "hideSonnetBarWhenZero") == nil)
    }
}
