//
//  LaunchContextTests.swift
//  ClaudeUsageTests
//
//  The test bundle is hosted in the app, so the app's launch code runs before
//  any test does. It must recognise that host launch and skip its side
//  effects: quitting other instances (the user's installed copy) and opening
//  the Welcome window.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("LaunchContext")
struct LaunchContextTests {

    @Test("this process, the test host, is recognised as one")
    func recognisesTheRealTestHost() {
        #expect(LaunchContext.isUnitTestHost(environment: ProcessInfo.processInfo.environment))
    }

    @Test("an ordinary launch environment is not a test host")
    func ordinaryLaunch() {
        let environment = [
            "HOME": "/Users/someone",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "__CFBundleIdentifier": "com.shyowlstudios.ClaudeUsage",
        ]
        #expect(!LaunchContext.isUnitTestHost(environment: environment))
    }
}
