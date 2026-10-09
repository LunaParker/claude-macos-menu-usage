//
//  LegacyURLCacheTests.swift
//  ClaudeUsageTests
//
//  Builds before the ephemeral session left `Cache.db` and its companions in
//  the app's caches folder, holding copies of the OAuth bearer token. Launch
//  deletes those files and must leave anything else alone.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("LegacyURLCache")
struct LegacyURLCacheTests {

    @Test("removes the URL cache files the shared session left behind, and nothing else")
    func removesCacheFiles() throws {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = caches.appendingPathComponent("com.example.app")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("fsCachedData"), withIntermediateDirectories: true)
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData/0A1B", "unrelated.txt"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }

        LegacyURLCache.remove(cachesDirectory: caches, bundleIdentifier: "com.example.app")

        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] {
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) survived")
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("unrelated.txt").path))
    }
}
