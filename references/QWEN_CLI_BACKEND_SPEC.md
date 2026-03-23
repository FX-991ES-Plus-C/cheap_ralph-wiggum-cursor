# Qwen CLI Backend Support Spec

Status: Draft

Date: 2026-03-23

Owner: cheap-ralph-wiggum-cursor

## Summary

Add first-class support for Qwen Code CLI as an alternate local agent backend for Ralph without introducing any dependency on ralph-tui. Cursor remains the default backend, but Ralph can also run end to end with Qwen using the same loop, state files, rotation logic, dashboard, and smoke-test coverage.

This work should be implemented through the repo's own Ralph workflow and task scaffolding, not through ralph-tui conversion or orchestration.

## Problem Statement

The current implementation is hard-wired to Cursor:

- `scripts/ralph-common.sh` builds a `cursor-agent` command directly.
- `scripts/ralph-common.sh` hard-fails if `cursor-agent` is not installed.
- `scripts/ralph-common.sh` treats `auto` as "Cursor Auto only".
- `scripts/stream-parser.sh` expects Cursor-specific `tool_call` payloads for read, write, and shell metrics.
- `README.md`, `install.sh`, and `init-ralph.sh` describe Cursor as the only supported CLI.

Qwen Code now supports headless `stream-json` output and an approval mode compatible with non-interactive agent runs, so the blocking issue is no longer transport. The remaining gap is backend abstraction and event normalization.

## Goals

- Support `cursor-agent` and `qwen` as interchangeable Ralph agent backends.
- Preserve current Cursor behavior as the default and fully backward compatible path.
- Keep Ralph's existing user-facing flow:
  - sequential loop
  - single iteration mode
  - parallel mode
  - dashboard mode
  - state files in `.ralph/`
  - signal handling (`WARN`, `ROTATE`, `GUTTER`, `COMPLETE`, `DEFER`, `ABORT`)
- Preserve or improve tool accounting for:
  - reads
  - writes
  - shell calls
  - shell mutation tracing
  - large-file reread and thrash detection
- Keep implementation local to this repo's own scripts and docs.

## Non-Goals

- Replacing Cursor as the default backend.
- Adding ralph-tui integration, PRD conversion, or bead generation.
- Supporting every Qwen feature or control-plane mode on day one.
- Adding remote/cloud execution for Qwen.
- Reworking the dashboard UX beyond what is required to show correct runtime state.

## Constraints

- Existing Cursor behavior must keep working without requiring any config changes.
- Existing root `RALPH_TASK.md` should not be overwritten automatically if it is already present.
- Bash compatibility matters, including macOS defaults.
- The parser currently relies on lightweight shell tools and `jq`; the design should stay consistent with that environment.
- Smoke tests should remain runnable from shell scripts already in the repo.

## Current State

### Current hard-coded assumptions

- Command construction:
  - `scripts/ralph-common.sh` launches `cursor-agent -p --force --output-format stream-json`.
- Backend prerequisite:
  - `scripts/ralph-common.sh` requires `cursor-agent` to be on `PATH`.
- Model semantics:
  - `MODEL=auto` is enforced as "Cursor Auto only".
- Stream parsing:
  - `scripts/stream-parser.sh` understands Cursor `system`, `assistant`, `result`, and `tool_call` events.
  - Read/write/shell accounting is based on Cursor-specific tool payloads such as `readToolCall`, `writeToolCall`, and `shellToolCall`.

### Useful discovery from Qwen CLI

Qwen is closer to compatible than it first appears:

- Qwen supports `--output-format stream-json`.
- Qwen supports `--approval-mode yolo` for non-interactive execution.
- Qwen emits `system`, `assistant`, and `result` messages with `session_id` and `permission_mode`.
- Qwen tool usage is represented differently from Cursor. Important built-in tool names include:
  - `read_file`
  - `write_file`
  - `edit`
  - `run_shell_command`
  - `grep_search`
  - `glob`
  - `list_directory`
  - `todo_write`
  - `web_fetch`
  - `web_search`

This means session tracking is mostly compatible already, but tool accounting is not.

## Proposed User Experience

### Backend selection

Add a backend selector with this precedence:

1. CLI flag: `--agent-backend cursor|qwen`
2. Environment variable: `RALPH_AGENT_BACKEND`
3. Default: `cursor`

This selector should be supported in:

- `scripts/ralph-loop.sh`
- `scripts/ralph-once.sh`
- `scripts/ralph-setup.sh`
- `scripts/ralph-parallel.sh`

### Backend-specific command mapping

Cursor backend:

```bash
cursor-agent -p --force --output-format stream-json --model auto "$prompt"
```

Qwen backend:

```bash
qwen -p --output-format stream-json --approval-mode yolo "$prompt"
```

Notes:

- For Qwen, do not pass `--model` when Ralph requests `auto`.
- If explicit non-`auto` model support is added later, it can map to `qwen --model ...`.
- Day-one scope should keep the public Ralph contract as "auto only" for both backends, but reinterpret `auto` as "backend default" for Qwen.

### Setup UX

`scripts/ralph-setup.sh` should prompt for backend before iteration count and options:

- Cursor
- Qwen

If `gum` is not installed, fall back to a simple numbered prompt.

## Proposed Architecture

### High-level approach

Introduce a small backend abstraction layer plus a normalized event contract used by the parser.

The cleanest implementation is:

1. Backend selection resolves which CLI to launch.
2. Backend-specific normalizer converts raw agent stream output into a common internal event shape.
3. `stream-parser.sh` consumes only the normalized event shape for metrics and signals.

This avoids scattering backend-specific conditionals across the parser's core accounting logic.

### New internal event contract

Define a normalized line-oriented JSON contract between the backend normalizer and `stream-parser.sh`.

Required normalized event types:

- `system`
- `assistant_text`
- `result`
- `error`
- `tool_call`

#### Normalized `system`

```json
{
  "type": "system",
  "subtype": "init",
  "backend": "qwen",
  "session_id": "abc123",
  "model": "qwen3.5-plus",
  "permission_mode": "yolo"
}
```

#### Normalized `assistant_text`

```json
{
  "type": "assistant_text",
  "backend": "qwen",
  "text": "Implemented the parser changes."
}
```

#### Normalized `result`

```json
{
  "type": "result",
  "backend": "qwen",
  "session_id": "abc123",
  "request_id": "",
  "duration_ms": 12345
}
```

#### Normalized `error`

```json
{
  "type": "error",
  "backend": "qwen",
  "message": "Rate limit exceeded"
}
```

#### Normalized `tool_call`

```json
{
  "type": "tool_call",
  "subtype": "completed",
  "backend": "qwen",
  "call_id": "tool-1",
  "tool_name": "read_file",
  "tool_kind": "read",
  "path": "README.md",
  "bytes": 2048,
  "lines": 40,
  "success": true
}
```

Optional fields for `tool_call`:

- `command`
- `exit_code`
- `stdout`
- `stderr`
- `content`
- `bytes`
- `lines`
- `path`
- `success`
- `raw_output`

### Backend normalizer design

Add a new script:

- `scripts/agent-normalizer.sh`

Responsibilities:

- Accept backend name and workspace.
- Read raw agent `stream-json` from stdin.
- Emit normalized JSON events to stdout.
- Remain stateless where possible, but allow small temp files for call-id tracking when needed.

Suggested interface:

```bash
"${agent_cmd[@]}" "$prompt" 2>&1 \
  | "$script_dir/agent-normalizer.sh" "$AGENT_BACKEND" "$workspace" \
  | "$script_dir/stream-parser.sh" "$workspace" > "$fifo"
```

### Cursor normalizer behavior

Cursor path should be mostly pass-through:

- Map `system/init` directly.
- Convert assistant text payload into `assistant_text`.
- Convert `result` directly.
- Convert retryable/non-retryable `error` directly.
- Convert Cursor `tool_call` payloads into normalized `tool_call` events.

This is the opportunity to simplify the parser by moving Cursor-specific field extraction out of `stream-parser.sh`.

### Qwen normalizer behavior

Qwen requires correlation across messages:

- `system/init`:
  - emit normalized `system`
- `assistant`:
  - emit normalized `assistant_text` from all text blocks
  - record any `tool_use` blocks by `call_id`, including:
    - tool name
    - args
    - inferred tool kind
- `user`:
  - inspect `tool_result` blocks
  - look up the matching recorded `tool_use`
  - emit normalized `tool_call` completion events
- `result`:
  - emit normalized `result`
- `error`:
  - emit normalized `error`

### Tool kind mapping for Qwen

Qwen tool names should map to normalized kinds as follows:

- `read_file` -> `read`
- `grep_search` -> `read`
- `glob` -> `read`
- `list_directory` -> `read`
- `write_file` -> `write`
- `edit` -> `write`
- `run_shell_command` -> `shell`
- `todo_write` -> `other`
- `task` -> `other`
- `skill` -> `other`
- `web_fetch` -> `other`
- `web_search` -> `other`
- any unknown tool -> `other`

### Estimation rules for Qwen tool metrics

Qwen will not provide Cursor-identical payloads, so normalized metrics should be derived with deterministic heuristics:

- `read_file`
  - `path` from tool input
  - `bytes` from result content length
  - `lines` from newline count of result content
- `write_file`
  - `path` from tool input
  - `bytes` from input content length if available, otherwise from filesystem stat after write
  - `lines` from input content newline count if available
- `edit`
  - `path` from tool input
  - rely primarily on existing workspace snapshot diff and shell-edit-style mutation tracing
  - estimate bytes from changed file size or diff payload if available
- `run_shell_command`
  - `command` from tool input
  - `stdout` and `stderr` from result content if structured output is available
  - if only plain text is available, capture the raw text as `stdout`
  - use existing shell-edit tracing to detect real file mutations

Important:

- Preserve the current snapshot-based mutation detection because it remains useful even when backend payloads are incomplete.
- Favor stable estimates over brittle parsing tricks.

## Parser Changes

`scripts/stream-parser.sh` should be simplified to consume normalized events only.

### Required parser updates

- Replace direct Cursor payload inspection with normalized field handling.
- Rename internal variables from Cursor-specific names where practical:
  - `CURSOR_MODEL` -> `RALPH_RUNTIME_MODEL_RESOLVED` or similar
  - `CURSOR_SESSION_ID` -> `RALPH_AGENT_SESSION_ID`
  - `CURSOR_REQUEST_ID` -> `RALPH_AGENT_REQUEST_ID`
  - `CURSOR_PERMISSION_MODE` -> `RALPH_AGENT_PERMISSION_MODE`

Variable renaming is not required for v1 correctness, but it is strongly recommended to reduce future confusion.

### Signal logic

Keep the existing signal rules unchanged:

- `WARN` on token threshold
- `ROTATE` on token threshold
- `GUTTER` on repeated failures, large-file rereads, and thrash
- `COMPLETE` when assistant emits `<ralph>COMPLETE</ralph>`
- `DEFER` on retryable errors
- `ABORT` on non-retryable errors or invalid runtime configuration

### Model-policy semantics

Current behavior aborts if requested `auto` resolves to a non-`auto` model name. That must change.

New rule:

- If backend is `cursor` and requested model is `auto`, resolved model must still be accepted as Cursor Auto semantics.
- If backend is `qwen` and requested model is `auto`, any resolved model from Qwen is valid and should be logged, not treated as a policy violation.

## Script and CLI Changes

### `scripts/ralph-common.sh`

Add:

- backend default and validation helpers
- backend-aware prerequisite checks
- backend-aware model formatting
- backend-aware agent command builder

Suggested helpers:

- `normalize_backend_name`
- `require_supported_backend`
- `resolve_agent_binary`
- `build_agent_command`

### `scripts/ralph-loop.sh`

Add:

- `--agent-backend cursor|qwen`
- help text updates
- environment documentation for `RALPH_AGENT_BACKEND`

### `scripts/ralph-once.sh`

Add:

- `--agent-backend cursor|qwen`
- help text updates

### `scripts/ralph-setup.sh`

Add:

- backend selection prompt
- display of selected backend in confirmation summary

### `scripts/ralph-parallel.sh`

Add:

- propagation of selected backend into isolated worktree agent runs
- backend-aware binary checks
- backend-aware launch command logging

## Installer and Documentation Changes

### `install.sh`

Update messaging so installation does not imply Cursor is the only supported CLI.

Required changes:

- prerequisite copy should say "Cursor or Qwen CLI"
- install summary should mention backend selection
- preserve existing behavior when neither CLI is installed, but make error/help text backend-aware

### `scripts/init-ralph.sh`

Mirror installer messaging and prerequisite logic updates.

### `README.md`

Update:

- title/intro copy where appropriate to mention alternate agent backends
- architecture diagram so it no longer names only `cursor-agent`
- prerequisites table
- setup section
- troubleshooting section
- examples using `RALPH_AGENT_BACKEND=qwen`

Keep Cursor examples as the primary path, but add Qwen equivalents.

## File-Level Change Plan

Files expected to change:

- `scripts/ralph-common.sh`
- `scripts/ralph-loop.sh`
- `scripts/ralph-once.sh`
- `scripts/ralph-setup.sh`
- `scripts/ralph-parallel.sh`
- `scripts/stream-parser.sh`
- `scripts/init-ralph.sh`
- `install.sh`
- `README.md`
- `scripts/test-dashboard-smoke.sh`

New file(s):

- `scripts/agent-normalizer.sh`

Optional follow-up files if tests are split out:

- `scripts/test-qwen-smoke.sh`

## Implementation Phases

### Phase 1: Backend selection and command construction

- Add backend option parsing to loop/once/setup/parallel scripts.
- Add backend validation and command building in `ralph-common.sh`.
- Keep Cursor as default.
- Ensure Qwen can launch in a single iteration with no parser changes yet.

Exit criteria:

- `--agent-backend qwen` is accepted everywhere.
- Missing binary errors point to the correct backend.

### Phase 2: Normalizer introduction

- Add `scripts/agent-normalizer.sh`.
- Convert Cursor stream into normalized events first.
- Update `stream-parser.sh` to read normalized Cursor events.

Exit criteria:

- Cursor smoke tests still pass through the new normalizer path.

### Phase 3: Qwen event normalization

- Add Qwen message parsing in `agent-normalizer.sh`.
- Correlate assistant `tool_use` to user `tool_result`.
- Emit normalized read/write/shell events.

Exit criteria:

- Qwen session start, assistant text, result, and tool completions are visible to the parser.

### Phase 4: Metrics and signal parity

- Tune Qwen read/write/shell estimators.
- Ensure large-read tracking, shell failure tracking, and gutter detection behave reasonably under Qwen.
- Ensure `<ralph>COMPLETE</ralph>` and `<ralph>GUTTER</ralph>` still work.

Exit criteria:

- Qwen backend produces useful `.ralph/activity.log`, `.ralph/signals.log`, and `.last-session.env` data.

### Phase 5: Parallel/dashboard compatibility

- Verify runtime state and dashboard summaries still render correctly.
- Verify parallel mode propagates backend selection.

Exit criteria:

- Dashboard shows session/model/permission details for both backends.
- Parallel runs launch the selected backend consistently.

### Phase 6: Docs and installer

- Update README, installer, and init flows.
- Add examples and troubleshooting for Qwen.

Exit criteria:

- Fresh users can discover and use Qwen support from docs alone.

## Test Plan

### Existing smoke test coverage to preserve

- Cursor auto model forwarding
- session start/result parsing
- model-policy behavior
- token/signal logging
- dashboard snapshots
- shell mutation tracing

### New Qwen smoke test scenarios

Add fixture/stub coverage for:

1. Qwen session start
   - emits `system/init`
   - parser writes session id, model, and permission mode

2. Qwen text assistant output
   - parser counts assistant chars
   - completion and gutter sigils still trigger

3. Qwen `read_file`
   - normalized to `tool_kind=read`
   - bytes/lines estimated from result content
   - large-read tracking works

4. Qwen `write_file`
   - normalized to `tool_kind=write`
   - work-write counts increment
   - workspace snapshot entry updates

5. Qwen `edit`
   - normalized to `tool_kind=write`
   - mutation tracing still records changed files

6. Qwen `run_shell_command`
   - normalized to `tool_kind=shell`
   - shell calls increment
   - exit-code failure tracking works

7. Qwen retryable error
   - rate limit or network text emits `DEFER`

8. Qwen non-retryable error
   - parser emits `ABORT`

9. Backend propagation in parallel mode
   - worker launch uses `qwen` rather than `cursor-agent`

### Required quality gates

The feature is not done until these pass:

- `bash scripts/test-dashboard-smoke.sh`
- `bash scripts/test-installer-upgrade-smoke.sh`

If Qwen coverage is split into its own test file, that command must also pass:

- `bash scripts/test-qwen-smoke.sh`

## Acceptance Criteria

The implementation is complete when all of the following are true:

- Ralph can run with Cursor exactly as before without any required config changes.
- Ralph can run with Qwen by selecting `--agent-backend qwen` or `RALPH_AGENT_BACKEND=qwen`.
- Qwen backend supports sequential, once, parallel, and dashboard flows.
- Session/model/permission metadata is stored correctly in `.ralph/.last-session.env`.
- Qwen read/write/shell activity contributes to the same signal and health systems as Cursor.
- README and installer text clearly document Cursor and Qwen support.
- Smoke tests cover both backends and pass.

## Risks and Mitigations

### Risk: Qwen result payloads are less structured than Cursor payloads

Mitigation:

- Normalize to a generic contract.
- Use deterministic estimators plus filesystem snapshot checks.

### Risk: backend-specific logic leaks back into the parser

Mitigation:

- Keep backend parsing inside `agent-normalizer.sh`.
- Keep `stream-parser.sh` backend-agnostic after refactor.

### Risk: `auto` semantics become confusing

Mitigation:

- Document that `auto` means:
  - Cursor Auto for Cursor
  - backend default model for Qwen

### Risk: existing root `RALPH_TASK.md` is unrelated

Mitigation:

- Do not overwrite it automatically.
- Use the companion task template below when ready to execute this feature through Ralph.

## Suggested Ralph Execution Task

The current root `RALPH_TASK.md` in this repo appears to be an unrelated example task. Do not overwrite it automatically. When ready to execute this feature through this repo's own Ralph flow, replace that file intentionally with a task like the following:

```md
---
task: Add Qwen CLI as an alternate Ralph agent backend without breaking Cursor support
test_command: "bash scripts/test-dashboard-smoke.sh"
max_iterations: 50
---

# Task: Qwen CLI Backend Support

## Overview

Add first-class support for `qwen` as an alternate agent backend for Ralph. Keep `cursor-agent` as the default backend and preserve the existing loop, dashboard, state files, and smoke-test coverage.

## Requirements

### Functional Requirements

1. Ralph supports backend selection via CLI flag and environment variable.
2. Ralph can launch Qwen in sequential, once, parallel, and dashboard flows.
3. Qwen output is normalized so the existing signal and metrics pipeline still works.
4. Documentation and installer messaging describe both Cursor and Qwen support.

### Constraints

- Preserve existing Cursor behavior by default.
- Do not depend on ralph-tui.
- Use this repo's own Ralph flow and state files.

## Success Criteria

1. [ ] Add backend selection and backend-aware command/prerequisite handling across loop, once, setup, and parallel modes. <!-- group: 1 -->
2. [ ] Introduce a backend normalizer and migrate Cursor parsing to the normalized event contract without regressions. <!-- group: 2 -->
3. [ ] Implement Qwen normalization for system, assistant text, result, read, write, and shell events. <!-- group: 3 -->
4. [ ] Restore signal, runtime-state, and dashboard compatibility for both Cursor and Qwen. <!-- group: 4 -->
5. [ ] Update installer/init/docs to describe both backends and Qwen usage examples. <!-- group: 5 -->
6. [ ] Extend smoke coverage for Qwen and make all required test commands pass. <!-- group: 6 -->

## Notes

- Required quality gates:
  - `bash scripts/test-dashboard-smoke.sh`
  - `bash scripts/test-installer-upgrade-smoke.sh`
- If Qwen tests are split out, they must also pass.
```

## Recommended Delivery Order

Implement in this order:

1. backend flags and command builder
2. normalizer introduction with Cursor pass-through
3. Qwen normalization
4. parser cleanup and parity fixes
5. test expansion
6. docs and installer

This order keeps the repo runnable throughout the change and minimizes the size of each risky step.
