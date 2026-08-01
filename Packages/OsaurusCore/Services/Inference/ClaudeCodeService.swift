//
//  ClaudeCodeService.swift
//  osaurus
//
//  A `ToolCapableService` backed by the user's locally-installed, already
//  signed-in Claude Code CLI. This is how Osaurus reaches a Claude Pro/Max
//  subscription without an Anthropic API key: Claude Code is itself the
//  licensed client, and Anthropic supports driving it programmatically.
//  Osaurus never mints, stores, or sees an Anthropic credential.
//
//  Plugs in as a peer of `FoundationModelService` — non-HTTP, non-MLX, and
//  invisible to the routing layer beyond `isAvailable()` / `handles(_:)`.
//

import Foundation

/// Per-agent options for one Claude Code run.
public struct ClaudeCodeRunOptions: Sendable, Equatable {
    public var mode: ClaudeCodeMode
    /// Agent mode only: auto-approve the file-writing built-ins.
    public var allowWrites: Bool
    /// Agent mode only: auto-approve `Bash`.
    public var allowShell: Bool
    /// The chat's working folder. Nil falls back to a scratch directory, so a
    /// run without a folder can't wander into the app bundle or the user's home.
    public var workingDirectory: URL?

    public init(
        mode: ClaudeCodeMode = .agent,
        allowWrites: Bool = false,
        allowShell: Bool = false,
        workingDirectory: URL? = nil
    ) {
        self.mode = mode
        self.allowWrites = allowWrites
        self.allowShell = allowShell
        self.workingDirectory = workingDirectory
    }

    public static let `default` = ClaudeCodeRunOptions()
}

actor ClaudeCodeService: ToolCapableService {
    static let serviceId = "claude-code"
    nonisolated let id: String = serviceId

    nonisolated func isAvailable() -> Bool {
        ClaudeCodeConfiguration.isAvailable()
    }

    /// Claims only its own `claude-code/…` ids. Unlike `FoundationModelService`
    /// it never claims the empty / "default" model, so installing Claude Code
    /// can't silently take over the system default.
    nonisolated func handles(requestedModel: String?) -> Bool {
        guard let requestedModel else { return false }
        return ClaudeCodeModel.fromPickerId(requestedModel) != nil
    }

    // MARK: - ModelService

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        let stream = try await streamDeltas(
            messages: messages,
            parameters: parameters,
            requestedModel: requestedModel,
            stopSequences: []
        )
        return try await Self.collectVisibleText(from: stream)
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        let model = ClaudeCodeModel.fromPickerId(requestedModel ?? "") ?? .sonnet
        let options = parameters.claudeCode ?? .default

        guard let executable = ClaudeCodeConfiguration.resolveExecutable() else {
            throw ClaudeCodeError.binaryNotFound(searchedPath: ClaudeCodeConfiguration.searchedPath())
        }

        let rendered = Self.renderPrompt(messages: messages)
        let arguments = ClaudeCodeConfiguration.arguments(
            model: model,
            mode: options.mode,
            allowedTools: ClaudeCodeConfiguration.allowedTools(
                allowWrites: options.allowWrites,
                allowShell: options.allowShell
            ),
            systemPrompt: rendered.systemPrompt
        )

        let events = ClaudeCodeProcessRunner.stream(
            executable: executable,
            arguments: arguments,
            prompt: rendered.prompt,
            workingDirectory: options.workingDirectory ?? Self.scratchDirectory()
        )

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producerTask = Task {
            do {
                for try await event in events {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    for delta in Self.encode(event) {
                        continuation.yield(delta)
                    }
                }
                continuation.finish()
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }
        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }
        return stream
    }

    // MARK: - ToolCapableService

    /// Osaurus's tools are never forwarded to the CLI.
    ///
    /// In agent mode Claude Code runs its own loop with its own tools, so the
    /// host loop must stay out of the way — the same short-circuit
    /// `RemoteProviderService` uses for a Mode 2 remote agent run.
    ///
    /// In text-only mode the CLI has no tools at all: `claude -p` accepts tool
    /// definitions only over MCP, never as OpenAI-style schemas, so there is no
    /// way to hand it `tools`. Either way the correct behavior is to stream
    /// text and never throw `ServiceToolInvocation`.
    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await streamDeltas(
            messages: messages,
            parameters: parameters,
            requestedModel: requestedModel,
            stopSequences: stopSequences
        )
    }

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        let stream = try await streamWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            requestedModel: requestedModel
        )
        return try await Self.collectVisibleText(from: stream)
    }

    // MARK: - Event encoding

    /// Map a decoded CLI event onto the in-band wire contract every Osaurus
    /// service shares (plain text + `\u{FFFE}` sentinels).
    static func encode(_ event: ClaudeCodeStreamEvent) -> [String] {
        switch event {
        case .text(let text):
            return [text]

        case .reasoning(let text):
            return [StreamingReasoningHint.encode(text)]

        case .toolTrace(let trace):
            return [StreamingAgentToolHint.encode(trace)]

        case .stats(let outputTokens, let tokensPerSecond, let stopReason):
            return [
                StreamingStatsHint.encode(
                    tokenCount: outputTokens,
                    tokensPerSecond: tokensPerSecond,
                    stopReason: stopReason
                )
            ]

        case .rateLimit(let status, let utilization, _):
            // Surfaced, never retried — this is the user's interactive Pro/Max
            // budget and silently re-spending it would be worse than saying so.
            // Only warn once the CLI itself flags a threshold breach.
            guard status != "allowed" else { return [] }
            let percent = Int((utilization * 100).rounded())
            return [
                StreamingAgentToolHint.encode(
                    StreamingAgentToolHint.Trace(
                        phase: "completed",
                        name: "rate limit \(percent)%",
                        callId: nil,
                        isError: status != "allowed_warning",
                        endRun: false
                    )
                )
            ]

        case .failure:
            // Surfaced as a thrown error by the runner's exit handling; the
            // in-band frame carries no extra signal worth showing twice.
            return []
        }
    }

    // MARK: - Prompt rendering

    struct RenderedPrompt {
        let systemPrompt: String?
        let prompt: String
    }

    /// Flatten the OpenAI-style message array into what `claude -p` accepts.
    ///
    /// The CLI's print mode takes a single prompt string plus an appended
    /// system prompt; there is no structured multi-turn input short of
    /// `--input-format stream-json`, which only carries user messages. So
    /// prior turns are rendered as a labeled transcript. This is a real
    /// fidelity limit of the CLI surface, not an oversight — assistant turns
    /// reach the model as quoted history rather than as native assistant
    /// messages.
    static func renderPrompt(messages: [ChatMessage]) -> RenderedPrompt {
        var systemParts: [String] = []
        var transcript: [String] = []

        for message in messages {
            let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch message.role {
            case "system":
                systemParts.append(text)
            case "assistant":
                transcript.append("Assistant: \(text)")
            case "tool":
                transcript.append("Tool result: \(text)")
            default:
                transcript.append("User: \(text)")
            }
        }

        // A single trailing user turn is by far the common case; sending it
        // bare (no "User:" label) keeps the prompt identical to what the user
        // would have typed into the CLI themselves.
        let prompt: String
        if transcript.count == 1, let only = transcript.first, only.hasPrefix("User: ") {
            prompt = String(only.dropFirst("User: ".count))
        } else {
            prompt = transcript.joined(separator: "\n\n")
        }

        return RenderedPrompt(
            systemPrompt: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"),
            prompt: prompt
        )
    }

    // MARK: - Helpers

    /// Concatenate visible prose, dropping every `\u{FFFE}` control frame.
    /// Mirrors `MLXService.generateOneShot` so a non-streaming caller never
    /// finds a sentinel embedded in `content`.
    private static func collectVisibleText(
        from stream: AsyncThrowingStream<String, Error>
    ) async throws -> String {
        var out = ""
        for try await delta in stream where !StreamingToolHint.isSentinel(delta) {
            out += delta
        }
        return out
    }

    /// Scratch cwd for runs with no working folder. Inside Osaurus's own
    /// directory so it's covered by existing cleanup and never the app bundle.
    private static func scratchDirectory() -> URL {
        let dir = OsaurusPaths.root().appendingPathComponent("claude-code", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
