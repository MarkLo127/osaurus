//
//  ClaudeCodeConfiguration.swift
//  osaurus
//
//  Static configuration for the Claude Code provider: locating the user's
//  `claude` binary, the model catalog, and the argument vector.
//
//  Osaurus drives the user's own locally-authenticated Claude Code install as
//  a subprocess. There are no credentials here by design — the user runs
//  `claude login` once in their terminal and the CLI owns that session. This
//  is the sanctioned way to reach a Claude Pro/Max subscription
//  programmatically; Osaurus never mints or stores an Anthropic token.
//

import Foundation
import SwiftUI

/// How much of Claude Code's own agent loop the caller wants.
public enum ClaudeCodeMode: String, Codable, Sendable, CaseIterable {
    /// Claude Code runs its own tools and multi-turn loop; Osaurus renders the
    /// text plus a sanitized read-only tool trace.
    case agent
    /// All built-in tools disabled — the CLI is a plain text generator and
    /// Osaurus's own agent loop runs on top.
    ///
    /// Note that Osaurus's tools are *not* forwarded to the CLI in this mode:
    /// `claude -p` accepts tool definitions only over MCP, never as
    /// OpenAI-style schemas. Text-only genuinely means "no tools at all".
    case textOnly
}

/// Model aliases Osaurus exposes for the CLI. These are Claude Code's own
/// `--model` aliases rather than pinned model ids, so the CLI keeps resolving
/// them to whatever the current generation is without an Osaurus release.
public enum ClaudeCodeModel: String, CaseIterable, Sendable {
    case sonnet
    case opus
    case haiku

    /// Routing id surfaced to the model picker and matched by
    /// `ClaudeCodeService.handles(requestedModel:)`.
    public var pickerId: String { "\(ClaudeCodeConfiguration.modelPrefix)\(rawValue)" }

    public var displayName: String {
        switch self {
        case .sonnet: return "Claude Code (Sonnet)"
        case .opus: return "Claude Code (Opus)"
        case .haiku: return "Claude Code (Haiku)"
        }
    }

    /// Parse a routing id such as `claude-code/sonnet` back into an alias.
    public static func fromPickerId(_ id: String) -> ClaudeCodeModel? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(ClaudeCodeConfiguration.modelPrefix) else { return nil }
        let alias = String(trimmed.dropFirst(ClaudeCodeConfiguration.modelPrefix.count))
        return ClaudeCodeModel(rawValue: alias.lowercased())
    }
}

public enum ClaudeCodeError: LocalizedError, Sendable, Equatable {
    case binaryNotFound(searchedPath: String)
    case notAuthenticated(detail: String)
    case launchFailed(String)
    case exited(code: Int32, stderrTail: String)
    case rateLimited(detail: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return L(
                "Claude Code isn't installed, or its `claude` command isn't on this app's PATH. Install it, then restart Osaurus."
            )
        case .notAuthenticated:
            return L("Claude Code isn't signed in. Run `claude login` in a terminal, then try again.")
        case .launchFailed(let detail):
            return String(format: L("Couldn't start Claude Code: %@"), detail)
        case .exited(let code, let tail):
            if tail.isEmpty {
                return String(format: L("Claude Code exited with code %d."), Int(code))
            }
            return String(format: L("Claude Code exited with code %d: %@"), Int(code), tail)
        case .rateLimited(let detail):
            return String(format: L("Claude Code hit a subscription rate limit: %@"), detail)
        }
    }
}

/// Decoded `claude auth status --json`.
///
/// Only the fields Osaurus actually shows are modeled; the CLI adds keys over
/// time and unknown ones are ignored by the synthesized decoder. Everything
/// except `loggedIn` is optional because an enterprise/gateway login reports a
/// different subset than a personal claude.ai one.
public struct ClaudeCodeAuthStatus: Codable, Sendable, Equatable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let subscriptionType: String?
    public let email: String?
    public let orgName: String?

    public init(
        loggedIn: Bool,
        authMethod: String? = nil,
        subscriptionType: String? = nil,
        email: String? = nil,
        orgName: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.subscriptionType = subscriptionType
        self.email = email
        self.orgName = orgName
    }

    /// Human-facing plan name — `"pro"` → `"Pro"`. Nil when the CLI didn't
    /// report one (an API-key or gateway login has no subscription tier).
    public var displayPlan: String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// True when this login actually draws on a Claude subscription, rather
    /// than billing an API key through the CLI. Drives whether we tell the user
    /// they're set up for subscription use.
    public var usesSubscription: Bool {
        loggedIn && displayPlan != nil
    }
}

/// The three states the setup UI renders.
public enum ClaudeCodeSetupState: Sendable, Equatable {
    case notInstalled(searchedPath: String)
    case signedOut
    case signedIn(ClaudeCodeAuthStatus)
}

public enum ClaudeCodeConfiguration {
    /// Routing prefix. Chosen so it can't collide with an MLX bundle id or a
    /// remote provider's `<provider-name>/` prefix.
    public static let modelPrefix = "claude-code/"

    /// Claude's brand gradient, from Anthropic's published accent orange
    /// (#D97757) to a darker shade of the same hue.
    ///
    /// Deliberately not the accent color: the picker's generic `.symbol` rows
    /// all hover to the accent, so an accent-tinted Claude Code row was
    /// indistinguishable from "Use an API key". Measured against every existing
    /// row gradient, the nearest in the same list is OpenRouter at ΔE 22.7
    /// (CIELAB) — comfortably distinguishable.
    public static let brandGradient: [Color] = [
        Color(red: 0.851, green: 0.467, blue: 0.341),
        Color(red: 0.749, green: 0.373, blue: 0.259),
    ]

    /// The command we look for on PATH.
    public static let executableName = "claude"

    /// Read-only built-ins allowed by default. Anything outside this list is
    /// refused by `--permission-mode dontAsk`, which is what makes the default
    /// fail-closed: a non-interactive run can't prompt, so an un-allowlisted
    /// tool is denied rather than silently approved.
    public static let defaultAllowedTools = ["Read", "Grep", "Glob"]

    /// Tools added when the agent opts into writes.
    public static let writeTools = ["Edit", "Write", "NotebookEdit"]

    /// Tools added when the agent opts into shell access.
    public static let shellTools = ["Bash"]

    // MARK: - Binary resolution

    /// Absolute path to the user's `claude`, or nil when it isn't installed
    /// / isn't visible on this app's PATH.
    public static func resolveExecutable(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        ExecutableLocator.resolve(command: executableName, env: env)
    }

    public static func searchedPath(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        ExecutableLocator.searchPath(env: env)
    }

    /// Cheap availability probe: does the binary exist and is it executable?
    ///
    /// Deliberately does *not* spawn `claude --version` — this is called during
    /// model-picker layout, and paying a process spawn there would stall the UI.
    /// Authentication state is discovered on the first real run instead, where
    /// it surfaces as a typed `notAuthenticated` error.
    public static func isAvailable(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        resolveExecutable(env: env) != nil
    }

    // MARK: - Argument vector

    /// Build the `claude` argument vector for one non-interactive turn.
    ///
    /// - Parameters:
    ///   - model: alias passed straight through to `--model`.
    ///   - mode: agent vs text-only.
    ///   - allowedTools: auto-approved tools in agent mode. Ignored in
    ///     text-only mode, where all built-ins are disabled.
    ///   - systemPrompt: appended to Claude Code's own system prompt rather
    ///     than replacing it, so its tool contract stays intact.
    public static func arguments(
        model: ClaudeCodeModel,
        mode: ClaudeCodeMode,
        allowedTools: [String],
        systemPrompt: String?
    ) -> [String] {
        var args = [
            "--print",
            "--output-format", "stream-json",
            "--verbose",
            // Without this the CLI emits only whole messages, so the chat
            // would sit blank and then paint the full answer at once.
            "--include-partial-messages",
            // One Osaurus turn is one CLI invocation; nothing should be
            // written to the user's ~/.claude session history.
            "--no-session-persistence",
            // Only MCP servers Osaurus passes explicitly (currently none) may
            // load. Without this the CLI would silently inherit whatever the
            // user configured for their terminal sessions.
            "--strict-mcp-config",
            "--model", model.rawValue,
        ]

        switch mode {
        case .textOnly:
            // The CLI's documented "disable every built-in" form.
            args += ["--tools", ""]
        case .agent:
            // Fail-closed: un-allowlisted tools are denied, not prompted for.
            args += ["--permission-mode", "dontAsk"]
            if !allowedTools.isEmpty {
                args += ["--allowedTools", allowedTools.joined(separator: ",")]
            }
        }

        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--append-system-prompt", systemPrompt]
        }

        return args
    }

    /// Tools to auto-approve given an agent's opt-ins.
    public static func allowedTools(allowWrites: Bool, allowShell: Bool) -> [String] {
        var tools = defaultAllowedTools
        if allowWrites { tools += writeTools }
        if allowShell { tools += shellTools }
        return tools
    }

    // MARK: - Authentication

    /// Decode a `claude auth status --json` payload.
    ///
    /// Split out from `authStatus()` so the parsing is testable without a
    /// subprocess. The CLI prints JSON on stdout for both signed-in and
    /// signed-out states, so a decode failure means something else went wrong
    /// (old CLI without `auth status`, a crash) and is reported as signed-out
    /// rather than guessed at.
    public static func decodeAuthStatus(_ data: Data) -> ClaudeCodeAuthStatus? {
        try? JSONDecoder().decode(ClaudeCodeAuthStatus.self, from: data)
    }

    /// Ask the CLI who is signed in.
    ///
    /// Unlike `isAvailable()` this *does* spawn a process, so it is only called
    /// from the settings sheet — never from model-picker layout.
    public static func authStatus(
        env: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 10
    ) async -> ClaudeCodeAuthStatus? {
        guard let executable = resolveExecutable(env: env) else { return nil }
        guard
            let data = await runCapturing(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                env: env,
                timeout: timeout
            )
        else { return nil }
        return decodeAuthStatus(data)
    }

    /// Resolve what the setup UI should show.
    public static func setupState(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) async -> ClaudeCodeSetupState {
        guard resolveExecutable(env: env) != nil else {
            return .notInstalled(searchedPath: searchedPath(env: env))
        }
        guard let status = await authStatus(env: env), status.loggedIn else {
            return .signedOut
        }
        return .signedIn(status)
    }

    /// Start the CLI's own browser sign-in.
    ///
    /// `claude auth login` opens the system browser and blocks until the round
    /// trip finishes, so this returns only once the user has completed (or
    /// abandoned) the flow. Osaurus never sees the credential — the CLI writes
    /// it to its own store, exactly as it would from a terminal.
    ///
    /// Returns the post-login status so the caller can update in place.
    public static func login(
        env: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 300
    ) async -> ClaudeCodeAuthStatus? {
        guard let executable = resolveExecutable(env: env) else { return nil }
        _ = await runCapturing(
            executable: executable,
            arguments: ["auth", "login"],
            env: env,
            timeout: timeout
        )
        return await authStatus(env: env)
    }

    /// Run a short-lived `claude` subcommand and collect stdout.
    ///
    /// Deliberately simpler than `ClaudeCodeProcessRunner`: these are one-shot
    /// control commands with bounded output, so there is no streaming, no
    /// partial-line framing, and no idle watchdog — just a wall-clock deadline
    /// and a SIGTERM. Returns nil on launch failure, timeout, or non-zero exit.
    private static func runCapturing(
        executable: String,
        arguments: [String],
        env: [String: String],
        timeout: TimeInterval
    ) async -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        // Keep the child off the app's stderr; callers surface their own copy.
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled, process.isRunning {
                process.terminate()
            }
        }
        defer { deadline.cancel() }

        // Read before waiting: a child that fills the pipe buffer would block
        // forever on write if we waited for exit first.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
