//
//  ClaudeCodeConfigurationTests.swift
//  osaurusTests
//
//  Argument-vector, model-id, and PATH-resolution coverage for the Claude
//  Code backend. Token-free — no subprocess, no network.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Claude Code configuration")
struct ClaudeCodeConfigurationTests {

    // MARK: - Model ids

    @Test func pickerIdsRoundTrip() {
        for model in ClaudeCodeModel.allCases {
            #expect(ClaudeCodeModel.fromPickerId(model.pickerId) == model)
        }
    }

    @Test func foreignModelIdsAreRejected() {
        #expect(ClaudeCodeModel.fromPickerId("mlx-community/Qwen3-8B") == nil)
        #expect(ClaudeCodeModel.fromPickerId("openai/gpt-5") == nil)
        #expect(ClaudeCodeModel.fromPickerId("") == nil)
        // Right prefix, unknown alias.
        #expect(ClaudeCodeModel.fromPickerId("claude-code/nonexistent") == nil)
    }

    /// The service must not claim the empty / "default" model the way
    /// `FoundationModelService` does — installing Claude Code should never
    /// silently take over the system default.
    @Test func serviceOnlyClaimsItsOwnIds() {
        let service = ClaudeCodeService()
        #expect(service.handles(requestedModel: "claude-code/sonnet"))
        #expect(!service.handles(requestedModel: nil))
        #expect(!service.handles(requestedModel: ""))
        #expect(!service.handles(requestedModel: "default"))
        #expect(!service.handles(requestedModel: "foundation"))
    }

    // MARK: - Argument vector

    @Test func agentModeIsFailClosedByDefault() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: ClaudeCodeConfiguration.allowedTools(allowWrites: false, allowShell: false),
            systemPrompt: nil
        )
        // `dontAsk` is what makes an un-allowlisted tool a denial rather than a
        // silent approval in a non-interactive run.
        #expect(args.contains("--permission-mode"))
        #expect(args.contains("dontAsk"))

        guard let allowedIndex = args.firstIndex(of: "--allowedTools") else {
            Issue.record("expected an --allowedTools flag in \(args)")
            return
        }
        let allowed = args[allowedIndex + 1]
        #expect(allowed.contains("Read"))
        #expect(!allowed.contains("Bash"))
        #expect(!allowed.contains("Write"))
    }

    @Test func optingIntoWritesAndShellWidensTheAllowlist() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .opus,
            mode: .agent,
            allowedTools: ClaudeCodeConfiguration.allowedTools(allowWrites: true, allowShell: true),
            systemPrompt: nil
        )
        guard let allowedIndex = args.firstIndex(of: "--allowedTools") else {
            Issue.record("expected an --allowedTools flag in \(args)")
            return
        }
        let allowed = args[allowedIndex + 1]
        #expect(allowed.contains("Read"))
        #expect(allowed.contains("Write"))
        #expect(allowed.contains("Bash"))
    }

    /// `--tools ""` is the CLI's documented "disable every built-in" form.
    @Test func textOnlyModeDisablesEveryBuiltinTool() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .haiku,
            mode: .textOnly,
            allowedTools: ["Read", "Bash"],
            systemPrompt: nil
        )
        guard let toolsIndex = args.firstIndex(of: "--tools") else {
            Issue.record("expected a --tools flag in \(args)")
            return
        }
        #expect(args[toolsIndex + 1].isEmpty)
        // Permission mode is meaningless with no tools, and an allowlist would
        // contradict the disable.
        #expect(!args.contains("--allowedTools"))
        #expect(!args.contains("--permission-mode"))
    }

    @Test func everyRunIsStatelessAndIgnoresUserMCPServers() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: [],
            systemPrompt: nil
        )
        // Without this the CLI writes into the user's ~/.claude history.
        #expect(args.contains("--no-session-persistence"))
        // Without this the CLI silently inherits whatever MCP servers the user
        // configured for their own terminal sessions.
        #expect(args.contains("--strict-mcp-config"))
        // Without this the chat sits blank and paints the whole answer at once.
        #expect(args.contains("--include-partial-messages"))
        #expect(args.contains("--print"))

        guard let formatIndex = args.firstIndex(of: "--output-format") else {
            Issue.record("expected an --output-format flag in \(args)")
            return
        }
        #expect(args[formatIndex + 1] == "stream-json")
    }

    @Test func modelAliasIsPassedThrough() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .opus,
            mode: .agent,
            allowedTools: [],
            systemPrompt: nil
        )
        guard let modelIndex = args.firstIndex(of: "--model") else {
            Issue.record("expected a --model flag in \(args)")
            return
        }
        #expect(args[modelIndex + 1] == "opus")
    }

    /// Appending rather than replacing keeps Claude Code's own tool contract
    /// intact.
    @Test func systemPromptIsAppendedNotReplaced() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: [],
            systemPrompt: "You are terse."
        )
        #expect(args.contains("--append-system-prompt"))
        #expect(args.contains("You are terse."))
        #expect(!args.contains("--system-prompt"))
    }

    @Test func blankSystemPromptIsOmitted() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: [],
            systemPrompt: "   \n "
        )
        #expect(!args.contains("--append-system-prompt"))
    }

    // MARK: - Prompt rendering

    private func message(_ role: String, _ content: String) -> ChatMessage {
        ChatMessage(role: role, content: content)
    }

    @Test func singleUserTurnIsSentBare() {
        let rendered = ClaudeCodeService.renderPrompt(messages: [message("user", "hi there")])
        #expect(rendered.prompt == "hi there")
        #expect(rendered.systemPrompt == nil)
    }

    @Test func systemMessagesAreHoistedOutOfTheTranscript() {
        let rendered = ClaudeCodeService.renderPrompt(messages: [
            message("system", "Be brief."),
            message("user", "hi"),
        ])
        #expect(rendered.systemPrompt == "Be brief.")
        #expect(rendered.prompt == "hi")
    }

    @Test func priorTurnsAreRenderedAsALabeledTranscript() {
        let rendered = ClaudeCodeService.renderPrompt(messages: [
            message("user", "one"),
            message("assistant", "two"),
            message("user", "three"),
        ])
        #expect(rendered.prompt == "User: one\n\nAssistant: two\n\nUser: three")
    }

    @Test func emptyMessagesAreSkipped() {
        let rendered = ClaudeCodeService.renderPrompt(messages: [
            message("system", "   "),
            message("user", "only this"),
        ])
        #expect(rendered.systemPrompt == nil)
        #expect(rendered.prompt == "only this")
    }

    // MARK: - Executable resolution

    @Test func absoluteAndTildePathsBypassThePathWalk() {
        #expect(ExecutableLocator.resolve(command: "/bin/sh", env: [:]) == "/bin/sh")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ExecutableLocator.expandUserPath("~/bin/claude") == "\(home)/bin/claude")
        #expect(ExecutableLocator.expandUserPath("~") == home)
        #expect(ExecutableLocator.expandUserPath("/opt/claude") == "/opt/claude")
    }

    /// GUI-launched apps inherit a sparse PATH; the fallbacks are what make
    /// a Homebrew or `~/.local/bin` install discoverable at all.
    @Test func searchPathAppendsCommonInstallLocations() {
        let path = ExecutableLocator.searchPath(env: ["PATH": "/custom/first"])
        let entries = path.split(separator: ":").map(String.init)

        #expect(entries.first == "/custom/first")
        #expect(entries.contains("/opt/homebrew/bin"))
        // Where the official Claude Code installer puts the binary.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(entries.contains("\(home)/.local/bin"))
    }

    @Test func searchPathStillWorksWithNoInheritedPath() {
        let entries = ExecutableLocator.searchPath(env: [:]).split(separator: ":").map(String.init)
        #expect(entries.contains("/usr/bin"))
        #expect(entries.contains("/opt/homebrew/bin"))
    }

    @Test func missingBareCommandResolvesToNil() {
        let resolved = ExecutableLocator.resolve(
            command: "osaurus-definitely-not-a-real-binary",
            env: ["PATH": "/usr/bin:/bin"]
        )
        #expect(resolved == nil)
    }

    @Test func bareCommandIsFoundOnPath() {
        // `sh` exists on every macOS install.
        #expect(ExecutableLocator.resolve(command: "sh", env: ["PATH": "/bin"]) == "/bin/sh")
    }

    // MARK: - Agent config

    /// Older agent JSON has no `claudeCode` key at all, and a future build
    /// could write a `mode` this build doesn't know. Neither may lose the
    /// user's agent.
    @Test func agentConfigDecodeFallsBackToSafeDefaults() throws {
        let decoder = JSONDecoder()

        let empty = try decoder.decode(ClaudeCodeAgentConfig.self, from: Data("{}".utf8))
        #expect(empty == .default)
        #expect(empty.mode == .agent)
        #expect(!empty.allowWrites)
        #expect(!empty.allowShell)

        let futureMode = try decoder.decode(
            ClaudeCodeAgentConfig.self,
            from: Data(#"{"mode":"someFutureMode","allowWrites":true}"#.utf8)
        )
        #expect(futureMode.mode == .agent)
        #expect(futureMode.allowWrites)
    }

    @Test func agentConfigRoundTrips() throws {
        let original = ClaudeCodeAgentConfig(mode: .textOnly, allowWrites: true, allowShell: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClaudeCodeAgentConfig.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Auth status

    /// The exact shape `claude auth status --json` emits for a personal
    /// subscription login, captured from the CLI.
    @Test func decodesSubscriptionLogin() throws {
        let json = """
            {
              "loggedIn": true,
              "authMethod": "claude.ai",
              "apiProvider": "firstParty",
              "email": "someone@example.com",
              "orgId": "4366ad70-efb4-4d0c-8ee3-475e0e512f77",
              "orgName": "Someone",
              "subscriptionType": "pro"
            }
            """
        let status = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(json.utf8)))

        #expect(status.loggedIn)
        #expect(status.email == "someone@example.com")
        #expect(status.subscriptionType == "pro")
        #expect(status.displayPlan == "Pro")
        #expect(status.usesSubscription)
    }

    /// `apiProvider` and `orgId` are deliberately not modeled; an unknown key
    /// must not fail the decode, or a CLI update would break sign-in detection.
    @Test func ignoresUnmodeledKeys() throws {
        let json = #"{"loggedIn":true,"subscriptionType":"max","brandNewField":123}"#
        let status = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(json.utf8)))

        #expect(status.loggedIn)
        #expect(status.displayPlan == "Max")
    }

    @Test func decodesSignedOut() throws {
        let status = try #require(
            ClaudeCodeConfiguration.decodeAuthStatus(Data(#"{"loggedIn":false}"#.utf8))
        )

        #expect(!status.loggedIn)
        #expect(status.displayPlan == nil)
        #expect(!status.usesSubscription)
    }

    /// An API-key or gateway login reports no `subscriptionType`. The UI keys
    /// off `usesSubscription` to avoid claiming a subscription that isn't there.
    @Test func loggedInWithoutSubscriptionIsNotSubscriptionBacked() throws {
        let json = #"{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty"}"#
        let status = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(json.utf8)))

        #expect(status.loggedIn)
        #expect(status.displayPlan == nil)
        #expect(!status.usesSubscription)
    }

    @Test func malformedPayloadDecodesToNil() {
        #expect(ClaudeCodeConfiguration.decodeAuthStatus(Data("not json".utf8)) == nil)
        #expect(ClaudeCodeConfiguration.decodeAuthStatus(Data()) == nil)
        // `loggedIn` is required — a payload without it is not a status.
        #expect(ClaudeCodeConfiguration.decodeAuthStatus(Data(#"{"email":"a@b.c"}"#.utf8)) == nil)
    }

    @Test func displayPlanNormalizesWhitespaceAndEmpty() {
        #expect(ClaudeCodeAuthStatus(loggedIn: true, subscriptionType: "  ").displayPlan == nil)
        #expect(ClaudeCodeAuthStatus(loggedIn: true, subscriptionType: "").displayPlan == nil)
        #expect(ClaudeCodeAuthStatus(loggedIn: true, subscriptionType: " pro ").displayPlan == "Pro")
    }
}
