#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

make_workspace() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/.ralph"

  cat > "$dir/RALPH_TASK.md" <<'EOF'
---
task: Smoke test
test_command: "true"
---

# Task

## Success Criteria

1. [x] Existing thing works
2. [ ] Dashboard shows current task state
3. [ ] Signals are persisted
EOF

  cat > "$dir/.ralph/progress.md" <<'EOF'
<!-- RALPH_COMPACT_KEEP_START -->
# Progress Log

- Smoke test initialized
<!-- RALPH_COMPACT_KEEP_END -->

## Session History

### 2026-03-19 12:00:00
Dashboard smoke test seeded.
EOF

  cat > "$dir/.ralph/activity.log" <<'EOF'
# Activity Log

[12:00:00] 🟢 TOKENS: 120 / 200000 (0%) [read:0KB write:0KB assist:0KB shell:0KB]
EOF

  cat > "$dir/.ralph/errors.log" <<'EOF'
# Error Log

EOF

  cat > "$dir/.ralph/signals.log" <<'EOF'
# Signal Log

[2026-03-19 12:00:00] source=parser iteration=1 signal=WARN model=test | Approaching token limit
EOF

  cat > "$dir/.ralph/runtime.env" <<'EOF'
# Ralph runtime state
RALPH_RUNTIME_STATUS=running
RALPH_RUNTIME_ITERATION=1
RALPH_RUNTIME_MODEL=test-model
RALPH_RUNTIME_LAST_SIGNAL=WARN
RALPH_RUNTIME_LAST_EVENT=Context\ warning\ issued
RALPH_RUNTIME_MODE=loop
RALPH_RUNTIME_AGENT_PID=12345
RALPH_RUNTIME_UPDATED_AT=2026-03-19\ 12:00:00\ EDT
EOF

  cat > "$dir/.ralph/.last-session.env" <<'EOF'
RALPH_SESSION_ITERATION=1
RALPH_SESSION_ID=cursor-session-123
RALPH_SESSION_REQUEST_ID=request-456
RALPH_SESSION_PERMISSION_MODE=default
RALPH_SESSION_MODEL=test-model
RALPH_SESSION_SIGNAL=WARN
RALPH_SESSION_TOKENS=120
RALPH_SESSION_BYTES_READ=0
RALPH_SESSION_BYTES_WRITTEN=0
RALPH_SESSION_ASSISTANT_CHARS=0
RALPH_SESSION_SHELL_OUTPUT_CHARS=0
RALPH_SESSION_TOOL_CALLS=0
RALPH_SESSION_READ_CALLS=1
RALPH_SESSION_WRITE_CALLS=0
RALPH_SESSION_WORK_WRITE_CALLS=0
RALPH_SESSION_SHELL_CALLS=0
RALPH_SESSION_LARGE_READS=0
RALPH_SESSION_LARGE_READ_REREADS=0
RALPH_SESSION_LARGE_READ_THRASH_HIT=0
EOF

  printf '%s\n' "$dir"
}

assert_contains() {
  local file="$1"
  local pattern="$2"

  if ! grep -Fq -- "$pattern" "$file"; then
    echo "Assertion failed: expected '$pattern' in $file" >&2
    exit 1
  fi
}

run_parser_case() {
  local name="$1"
  local expected_signal="$2"
  local payload="$3"
  local workspace
  workspace="$(make_workspace)"

  printf '%s\n' "$payload" | WARN_THRESHOLD=700 ROTATE_THRESHOLD=900 bash "$REPO_DIR/scripts/stream-parser.sh" "$workspace" >"$workspace/parser.out"

  assert_contains "$workspace/.ralph/signals.log" "signal=${expected_signal}"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_SIGNAL=${expected_signal}"
}

run_auto_model_case() {
  local workspace fakebin signal
  workspace="$(make_workspace)"
  fakebin="$workspace/fakebin"
  mkdir -p "$fakebin"

  cat > "$fakebin/cursor-agent" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_ARG_FILE"
printf '%s\n' '{"type":"system","subtype":"init","model":"cursor-default","session_id":"cursor-session-auto","permissionMode":"default"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"text":"<ralph>COMPLETE</ralph>"}]}}'
printf '%s\n' '{"type":"result","subtype":"success","result":"OK","session_id":"cursor-session-auto","request_id":"request-auto-123"}'
EOF
  chmod +x "$fakebin/cursor-agent"

  (
    export PATH="$fakebin:$PATH"
    export TEST_ARG_FILE="$workspace/agent-args.txt"
    export MODEL=auto
    export SCRIPT_DIR="$REPO_DIR/scripts"
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"
    init_ralph_dir "$workspace"
    signal="$(run_iteration "$workspace" 1 "$REPO_DIR/scripts")"
    [[ "$signal" == "COMPLETE" ]]
  )

  if grep -qx -- '--model' "$workspace/agent-args.txt"; then
    echo "Assertion failed: MODEL=auto should not pass --model to cursor-agent" >&2
    exit 1
  fi
  if grep -qx -- 'auto' "$workspace/agent-args.txt"; then
    echo "Assertion failed: MODEL=auto should not be forwarded literally" >&2
    exit 1
  fi
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_ID=cursor-session-auto"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_REQUEST_ID=request-auto-123"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_PERMISSION_MODE=default"
}

run_signal_timeline_case() {
  local workspace
  workspace="$(make_workspace)"

  cat > "$workspace/.ralph/signals.log" <<'EOF'
# Signal Log

[2026-03-19 12:00:00] source=loop iteration=1 signal=SESSION_START | model=test
[2026-03-19 12:00:01] source=loop iteration=1 signal=LOOP_START | max_iterations=5
[2026-03-19 12:00:02] source=loop iteration=1 signal=THRASH | repeated rotate-without-progress
[2026-03-19 12:00:03] source=loop iteration=1 signal=ABORT | Agent launch/runtime failure
EOF

  python3 - "$REPO_DIR/scripts/ralph-tui.py" "$workspace" <<'PY'
import runpy
import sys
from pathlib import Path

ns = runpy.run_path(sys.argv[1], run_name="ralph_tui_test")
state = ns["load_dashboard_state"](Path(sys.argv[2]))

assert ns["signal_from_line"](
    "[2026-03-19 12:00:03] source=loop iteration=1 signal=ABORT | Agent launch/runtime failure"
) == "ABORT"
assert ns["signal_from_line"](
    "[2026-03-19 12:00:01] source=loop iteration=1 signal=LOOP_START | max_iterations=5"
) == "LOOP_START"
assert state.signal_timeline[-4:] == ["SESSION_START", "LOOP_START", "THRASH", "ABORT"], state.signal_timeline
assert state.latest_signals[-1].endswith("Agent launch/runtime failure"), state.latest_signals
assert ns["cursor_session_summary"](state) == "session cursor-session-123 | req request-456 | perm default"
PY
}

run_parser_session_metadata_case() {
  local workspace
  workspace="$(make_workspace)"

  printf '%s\n' \
    '{"type":"system","subtype":"init","model":"Cursor Model With Spaces","session_id":"cursor-session-parser","permissionMode":"default"}' \
    '{"type":"result","subtype":"success","result":"OK","session_id":"cursor-session-parser","request_id":"request-parser-789"}' \
    | WARN_THRESHOLD=700 ROTATE_THRESHOLD=900 bash "$REPO_DIR/scripts/stream-parser.sh" "$workspace" >"$workspace/parser.out"

  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_ID=cursor-session-parser"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_REQUEST_ID=request-parser-789"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_PERMISSION_MODE=default"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_MODEL=Cursor\\ Model\\ With\\ Spaces"
}

main() {
  local workspace snapshot_file
  workspace="$(make_workspace)"
  snapshot_file="$workspace/snapshot.txt"

  python3 "$REPO_DIR/scripts/ralph-tui.py" --snapshot "$workspace" >"$snapshot_file"
  assert_contains "$snapshot_file" "Ralph Dashboard"
  assert_contains "$snapshot_file" "Views:"
  assert_contains "$snapshot_file" "Dashboard shows current task state"
  assert_contains "$snapshot_file" "Timeline:"
  assert_contains "$snapshot_file" "Cursor: session cursor-session-123 | req request-456 | perm default"

  if python3 - <<'PY' >/dev/null 2>&1
import textual
PY
  then
    RALPH_TUI_HEADLESS=1 RALPH_TUI_SMOKE_EXIT=1 \
      python3 "$REPO_DIR/scripts/ralph-tui.py" monitor "$workspace" >/dev/null
  fi

  run_parser_case \
    "complete" \
    "COMPLETE" \
    '{"type":"assistant","message":{"content":[{"text":"<ralph>COMPLETE</ralph>"}]}}'

  run_parser_case \
    "gutter" \
    "GUTTER" \
    '{"type":"assistant","message":{"content":[{"text":"<ralph>GUTTER</ralph>"}]}}'

  run_parser_case \
    "defer" \
    "DEFER" \
    '{"type":"error","error":{"message":"Rate limit exceeded"}}'

  run_parser_case \
    "abort" \
    "ABORT" \
    'Cannot use this model: auto.'

  local rotate_workspace
  rotate_workspace="$(make_workspace)"
  printf '%s\n' \
    '{"type":"system","subtype":"init","model":"test-model"}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/demo.ts"},"result":{"success":{"totalLines":50,"contentSize":1800}}}}}' \
    | WARN_THRESHOLD=400 ROTATE_THRESHOLD=700 bash "$REPO_DIR/scripts/stream-parser.sh" "$rotate_workspace" >"$rotate_workspace/parser.out"

  assert_contains "$rotate_workspace/parser.out" "ROTATE"
  assert_contains "$rotate_workspace/.ralph/signals.log" "signal=ROTATE"
  assert_contains "$rotate_workspace/.ralph/.last-session.env" "RALPH_SESSION_READ_TOKENS="
  assert_contains "$rotate_workspace/.ralph/.last-session.env" "RALPH_SESSION_TOOL_OVERHEAD_TOKENS="

  local gutter_rotate_workspace
  gutter_rotate_workspace="$(make_workspace)"
  printf '%s\n' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"shellToolCall":{"args":{"command":"pnpm test"},"result":{"exitCode":1,"stdout":"","stderr":"fail"}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"shellToolCall":{"args":{"command":"pnpm test"},"result":{"exitCode":1,"stdout":"","stderr":"fail"}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"shellToolCall":{"args":{"command":"pnpm test"},"result":{"exitCode":1,"stdout":"","stderr":"fail"}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/heavy.ts"},"result":{"success":{"totalLines":120,"contentSize":2600}}}}}' \
    | WARN_THRESHOLD=1100 ROTATE_THRESHOLD=1400 bash "$REPO_DIR/scripts/stream-parser.sh" "$gutter_rotate_workspace" >"$gutter_rotate_workspace/parser.out"

  assert_contains "$gutter_rotate_workspace/parser.out" "GUTTER"
  assert_contains "$gutter_rotate_workspace/parser.out" "ROTATE"
  assert_contains "$gutter_rotate_workspace/.ralph/signals.log" "signal=GUTTER"
  assert_contains "$gutter_rotate_workspace/.ralph/signals.log" "signal=ROTATE"
  assert_contains "$gutter_rotate_workspace/.ralph/.last-session.env" "RALPH_SESSION_SIGNAL=ROTATE"

  run_auto_model_case
  run_parser_session_metadata_case
  run_signal_timeline_case

  echo "dashboard smoke test passed"
}

main "$@"
