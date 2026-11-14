//
//  ClaudeCLIVersionTests.swift
//  ClaudeUsageTests
//
//  The installed `claude` version, read from the files an install leaves
//  behind, never by running the CLI.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("ClaudeCLIVersion")
struct ClaudeCLIVersionTests {

    @Test("the native installer's symlink names the version")
    func nativeInstall() throws {
        let root = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("share/claude/versions/2.1.322")
        try Self.write("binary", to: binary)
        let link = root.appendingPathComponent("bin/claude")
        try Self.link(link, to: binary)

        #expect(ClaudeCLIVersion.read(executable: link) == "2.1.322")
    }

    @Test("an npm install's package.json has the version")
    func npmInstall() throws {
        let root = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code")
        try Self.write("#!/usr/bin/env node", to: package.appendingPathComponent("cli.js"))
        try Self.write(#"{"name": "@anthropic-ai/claude-code", "version": "2.1.300"}"#, to: package.appendingPathComponent("package.json"))
        let link = root.appendingPathComponent("bin/claude")
        try Self.link(link, to: package.appendingPathComponent("cli.js"))

        #expect(ClaudeCLIVersion.read(executable: link) == "2.1.300")
    }

    @Test("another package's package.json, or a plain binary, gives no version")
    func unknownInstall() throws {
        let root = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("lib/node_modules/other")
        try Self.write("x", to: other.appendingPathComponent("cli.js"))
        try Self.write(#"{"name": "other", "version": "9.9.9"}"#, to: other.appendingPathComponent("package.json"))
        let plain = root.appendingPathComponent("bin/claude")
        try Self.write("binary", to: plain)

        #expect(ClaudeCLIVersion.read(executable: other.appendingPathComponent("cli.js")) == nil)
        #expect(ClaudeCLIVersion.read(executable: plain) == nil)
    }

    private static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCLIVersionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func link(_ url: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    }
}
