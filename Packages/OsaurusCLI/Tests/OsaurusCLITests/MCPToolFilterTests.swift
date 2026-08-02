//
//  MCPToolFilterTests.swift
//  OsaurusCLITests
//
//  Allow-list parsing and matching for `osaurus mcp --tools`. Pure logic —
//  no server, no subprocess.
//

import Foundation
import Testing

@testable import OsaurusCLICore

@Suite("MCP tool filter")
struct MCPToolFilterTests {

    // MARK: - Matching

    @Test func exactNamesMatchOnlyThemselves() throws {
        let filter = try #require(MCPToolFilter(patterns: "osaurus_status,osaurus_list"))

        #expect(filter.admits("osaurus_status"))
        #expect(filter.admits("osaurus_list"))
        #expect(!filter.admits("osaurus_agent"))
        // Exact means exact: a longer name sharing the prefix is not admitted.
        #expect(!filter.admits("osaurus_status_extra"))
    }

    @Test func trailingStarMatchesByPrefix() throws {
        let filter = try #require(MCPToolFilter(patterns: "osaurus_*"))

        #expect(filter.admits("osaurus_status"))
        #expect(filter.admits("osaurus_agent"))
        // The prefix is stripped of the star, so the bare stem still matches.
        #expect(filter.admits("osaurus_"))
        #expect(!filter.admits("shell_run"))
        #expect(!filter.admits("prefix_osaurus_status"))
    }

    @Test func mixesExactAndPrefixPatterns() throws {
        let filter = try #require(MCPToolFilter(patterns: "osaurus_*,shell_run"))

        #expect(filter.admits("osaurus_describe"))
        #expect(filter.admits("shell_run"))
        #expect(!filter.admits("read_file"))
    }

    @Test func bareStarAdmitsEverything() throws {
        let filter = try #require(MCPToolFilter(patterns: "*"))

        #expect(filter.admits("anything"))
        #expect(filter.admits(""))
    }

    // MARK: - Parsing hygiene

    @Test func whitespaceAndEmptyEntriesAreIgnored() throws {
        let filter = try #require(MCPToolFilter(patterns: " osaurus_status , , osaurus_list ,"))

        #expect(filter.admits("osaurus_status"))
        #expect(filter.admits("osaurus_list"))
        #expect(!filter.admits(""))
    }

    /// A value with no usable patterns must read as "no filter" rather than
    /// "admit nothing" — the latter would silently produce an empty server.
    @Test func emptyPatternsProduceNoFilter() {
        #expect(MCPToolFilter(patterns: "") == nil)
        #expect(MCPToolFilter(patterns: "   ") == nil)
        #expect(MCPToolFilter(patterns: ",,,") == nil)
    }

    // MARK: - Argument extraction

    @Test func parsesSpaceSeparatedForm() throws {
        let filter = try #require(MCPToolFilter.parse(args: ["mcp", "--tools", "osaurus_*"]))
        #expect(filter.admits("osaurus_status"))
    }

    @Test func parsesEqualsForm() throws {
        let filter = try #require(MCPToolFilter.parse(args: ["mcp", "--tools=osaurus_status"]))
        #expect(filter.admits("osaurus_status"))
        #expect(!filter.admits("osaurus_agent"))
    }

    @Test func absentFlagMeansProxyEverything() {
        #expect(MCPToolFilter.parse(args: ["mcp"]) == nil)
        #expect(MCPToolFilter.parse(args: ["mcp", "--access-key", "osk-v1"]) == nil)
        // A dangling `--tools` with no value can't be honored; treat as absent.
        #expect(MCPToolFilter.parse(args: ["mcp", "--tools"]) == nil)
    }

    @Test func summaryListsParsedPatterns() throws {
        let filter = try #require(MCPToolFilter(patterns: "osaurus_status,osaurus_*"))
        #expect(filter.summary.contains("osaurus_status"))
        #expect(filter.summary.contains("osaurus_*"))
    }
}
