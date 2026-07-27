# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Osaurus is a native Swift/SwiftUI macOS app (Apple Silicon, macOS 15.5+) that acts as a local AI harness: agents, memory, tools, identity, an OpenAI/Anthropic/Ollama-compatible HTTP server, an MCP server + client, and a Linux sandbox VM. Local inference runs through MLX via the `vmlx-swift` package.

## Commands

Everything routes through the `Makefile` (`make help` lists all targets).

```bash
make cli          # xcodebuild the osaurus-cli scheme
make app          # build the app, embed the CLI, bundle the sandbox kernel
make install-cli  # symlink /usr/local/bin/osaurus to the dev build
make serve        # build + run the server (PORT=1337, EXPOSE=1)
make status
make clean
```

### Tests

The full OsaurusCore suite is ~5000 tests / ~30 minutes. **Do not run it during normal iteration** — run targeted tests, and run the full suite once right before opening a PR (see `.cursor/rules/testing-workflow.mdc`).

```bash
# Targeted (development loop)
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-test \
OSU_MODELS_DIR=/tmp/osaurus-test-models \
swift test --package-path Packages/OsaurusCore --filter "SuiteOrTestName"

# Compile check only
swift build --package-path Packages/OsaurusCore

# Full suite (same env prefix), once, pre-PR
make test

# Other packages
swift test --package-path Packages/OsaurusCLI --parallel
swift test --package-path Packages/OsaurusRepository --parallel
swift test --package-path Packages/OsaurusPluginTestKit --parallel
swift test --package-path Packages/OsaurusPlugins/StatsPack
make evals-test           # OsaurusEvals harness unit tests (token-free)
make evals-deterministic  # token-free eval suites + floors gate (CI-safe, no model)

make ci-test              # reproduce the CI test-core job (xcodebuild + xcbeautify)
                          # -> open build/Tests.xcresult on failure
```

The three env vars matter:

- `OSAURUS_TEST_ROOT` redirects `~/.osaurus` (see `Utils/OsaurusPaths.swift`).
- `OSU_MODELS_DIR` pointed at an empty dir stops dispatch-style tests from resolving real `~/MLXModels` bundles — the SwiftPM harness has no Metal kernels and a real load dies with `MLX/MLXArray.swift precondition failed`. With the override, sends fail fast with `modelUnavailable`, matching CI.
- `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1` makes Keychain wrappers no-op instead of prompting. Keychain-gated suites (e.g. `PluginAgentScopingTests`) fail *by design* under this flag — run those without it when you touch that area.

### Lint / gates (all enforced in CI)

```bash
swift-format lint --strict --recursive Packages App   # also the lefthook pre-push hook
swift-format format --in-place --recursive Packages App
swiftlint lint
bash scripts/i18n/check.sh                            # string catalogs + Swift literal lint
find scripts -name '*.sh' -print0 | xargs -0 shellcheck --severity=warning
```

`scripts/i18n/check.sh` requires `de,zh-Hans,ko,ru` coverage in `Packages/OsaurusCore/Resources/Localizable.xcstrings` and `App/osaurus/InfoPlist.xcstrings`, verifies every catalog key referenced from Swift exists, and flags hardcoded SwiftUI/AppKit string literals. New user-facing strings must go through the catalog.

### Evals

`make evals` / `make evals-all` run suites from `Packages/OsaurusEvals/Suites/*` against a live model (`MODEL=`, `FILTER=`, `EVALS_SUITE=`). `make evals-loop`, `evals-matrix`, `evals-diff`, `evals-contribute` cover the optimization/crowdsourcing lanes — see `COMMUNITY_EVALS.md` and `docs/EVAL_WATCHER.md`.

Live-app smoke: `scripts/live-proof/launch-keychain-free-osaurus.sh`.

## Architecture

`App/` is a thin SwiftUI shell (`osaurusApp.swift`, `AppIntents/`, assets, entitlements). **Essentially all logic, including the SwiftUI views, lives in `Packages/OsaurusCore/`.** Build via `osaurus.xcworkspace`, not the bare xcodeproj.

| Package | Role |
| --- | --- |
| `OsaurusCore` | The app: models, services, managers, views, HTTP server, storage, identity, tools, sandbox, plugin ABI |
| `OsaurusCLI` | The `osaurus` command (`serve`, `ui`, `status`, `mcp`, `tools`, `bench`) |
| `OsaurusRepository` | Plugin registry, install, minisign verification |
| `OsaurusPlugins/StatsPack` | First-party plugin |
| `OsaurusPluginTestKit` | Harness for plugin authors |
| `OsaurusEvals` | Eval harness + suites |
| `OsaurusNetworking` | Tiny shared leaf (global proxy config) used by Core |

### OsaurusCore layering

Enforced by convention; `docs/CONTRIBUTING.md` has the full rules.

- **`Models/`** — pure data, organized by domain. No `@Published`, no `static let shared`.
- **`Services/`** — business logic as `actor` (concurrent) or stateless `struct`. Never `ObservableObject`/`@Observable`, never UI-aware. Suffix `Service` or `Engine`.
- **`Managers/`** — `@MainActor` observable UI state that views bind to; coordinates services. Suffix `Manager`.
- **`Views/`** — SwiftUI, organized by feature folder; `Common/` is only generic primitives.
- **`Networking/`**, **`Storage/`** (SQLite, suffix `Database`), **`Identity/`**, **`Tools/`**, **`Utils/`** — as named.
- Tests mirror the source directory under `Tests/`.

### Request path

`Networking/OsaurusServer.swift` (SwiftNIO) → `Networking/HTTPHandler.swift` (~12k lines: all route dispatch for `/v1/chat/completions`, `/anthropic/v1/messages`, `/api/chat`, `/agents/{id}/run`, `/mcp/*`, `/admin/*`) → `Services/Chat/ChatEngine.swift` + `PromptBuilder`/`SystemPromptComposer` → `Services/ModelRuntime/` (MLX adapter, leases, residency, load coordination) or a remote provider under `Services/Provider/`.

`ServerController` owns lifecycle; `RelayTunnelManager` handles the `agent.osaurus.ai` tunnel; `HostAPIBridgeServer` is the vsock bridge into the sandbox VM.

`/chat/completions` keeps **strict OpenAI semantics**: it returns `tool_calls` and the client executes them. Server-side autonomous loops are `POST /agents/{id}/run` (`Services/Chat/AgentToolLoop.swift`).

### Tool calling

- OpenAI-compatible DTOs live in `Models/API/OpenAIAPI.swift`.
- Prompt templating and tool-call detection are owned by `vmlx-swift` (`BatchEngine.generate` emits `Generation.toolCall`). Osaurus does **not** assemble prompts or parse tool calls itself — `Services/ModelRuntime/GenerationEventMapper.swift` just translates events into `ModelRuntimeEvent`.
- Wire-level streaming deltas are written in `Networking/HTTPHandler.swift` and `Models/Chat/ResponseWriters.swift`.

### Data locations

`Utils/OsaurusPaths.swift` is the single source of path truth: everything lives under `~/.osaurus/` (config, agents, chat-history, schedules, watchers, …), overridable via `OSAURUS_TEST_ROOT`. Models live in `~/MLXModels` (`OSU_MODELS_DIR`). Storage is plaintext by default with opt-in SQLCipher (`Storage/`, `docs/STORAGE.md`).

## Dependencies

The workspace lockfile `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved` is the source of truth and must be committed; CI builds with `-disableAutomaticPackageResolution` and fails on a stale lockfile. Per-package `Packages/*/Package.resolved` are gitignored.

Local inference comes from **one consolidated `vmlx-swift` pin** (MLX, MLXLLM/VLM, Tokenizers, Jinja, chat templates, reasoning parsers, cache layers, media, MTP). Do not add root dependencies on `mlx-swift`, `swift-transformers`, `Jinja`, or similar, and do not add package-level `moduleAliases` for the inference graph. Keep the two SwiftPM mirror configs (workspace + `App/osaurus.xcodeproj/…`) in sync.

## Model runtime non-negotiables

`AGENTS.md` holds the full list; the essentials, because they are easy to violate accidentally:

- Never make a model *appear* coherent: no forced thinking tags, parser repair, hidden sampler defaults, repetition-penalty rescues, close-token bias, or prompt/template coercion.
- Never add fake guards, placeholder gates, hardcoded model allowlists, or synthetic output filters to make a runtime row look safe. Trace and fix the real function; if it isn't fixed, document the row as `PARTIAL`/`BLOCKED` with exact evidence.
- Chat/API generation defaults come from the model bundle's `generation_config.json`, not from synthetic Osaurus defaults. Reasoning/tool/template behavior is auto-detected from the bundle, tokenizer, and runtime config.
- Memory limits apply only through documented settings and the resolved runtime plan — no hidden RAM percentage blocks or fake load refusals. Fail before unsafe MLX/Metal allocation with a typed error.
- Runtime proof is live-app proof, not source reading: token/s recorded per generation row, physical footprint from Activity Monitor, multi-turn coherency, cache telemetry matching the model's architecture (KV / hybrid SSM companion / CCA pooling / SWA pools), and server settings toggled and verified end to end. Load-only or single-prompt results do not qualify.

## Docs

`docs/FEATURES.md` is the feature source of truth; update it (and the relevant guide) when adding or changing a feature. Key guides: `docs/AGENT_LOOP.md`, `docs/MEMORY.md`, `docs/SANDBOX.md`, `docs/INFERENCE_RUNTIME.md`, `docs/IDENTITY.md`, `docs/STORAGE.md`, `docs/plugins/README.md`, `docs/LOCALIZATION.md`, `docs/CONTRIBUTING.md`.

## Conventions

- Branches: `feat/…`, `fix/…`, `docs/…` off `main`; Conventional Commits where practical.
- Do not spawn recursive local agent workers or use Python/shell as an orchestration layer to farm work out to other agents. Python is fine for deterministic parsing and proof harnesses.
