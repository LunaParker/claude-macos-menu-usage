//
//  TestDefaults.swift
//  ClaudeUsageTests
//

import Foundation

enum TestDefaults {
    /// An empty, throwaway defaults suite. The test host's `.standard` is the
    /// real app's preferences, which tests must never write to.
    static func make() -> UserDefaults {
        let name = "ClaudeUsageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
