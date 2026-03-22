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

[2026-03-19 12:00:00] source=parser iteration=1 signal=WARN model=test-model | Approaching token limit
EOF

  cat > "$dir/.ralph/runtime.env" <<'EOF'
# Ralph runtime state
RALPH_RUNTIME_STATUS=running
RALPH_RUNTIME_ITERATION=1
RALPH_RUNTIME_MODEL=auto
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
RALPH_SESSION_TOOL_CALLS=1
RALPH_SESSION_READ_CALLS=1
RALPH_SESSION_WRITE_CALLS=0
RALPH_SESSION_WORK_WRITE_CALLS=0
RALPH_SESSION_SHELL_CALLS=0
RALPH_SESSION_SHELL_EDIT_CALLS=0
RALPH_SESSION_SHELL_WORK_EDIT_CALLS=0
RALPH_SESSION_WORK_EDIT_CALLS=0
RALPH_SESSION_LARGE_READS=0
RALPH_SESSION_LARGE_READ_REREADS=0
RALPH_SESSION_LARGE_READ_THRASH_HIT=0
RALPH_SESSION_HOT_FILE=src/demo.ts
RALPH_SESSION_HOT_FILE_READS=2
RALPH_SESSION_HOT_FILE_BYTES=4096
RALPH_SESSION_HOT_FILE_LINES=120
RALPH_SESSION_THRASH_PATH=
RALPH_SESSION_PROMPT_TOKENS=480
RALPH_SESSION_READ_TOKENS=120
RALPH_SESSION_WRITE_TOKENS=60
RALPH_SESSION_ASSISTANT_TOKENS=90
RALPH_SESSION_SHELL_TOKENS=10
RALPH_SESSION_TOOL_OVERHEAD_TOKENS=12
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

assert_not_contains() {
  local file="$1"
  local pattern="$2"

  if grep -Fq -- "$pattern" "$file"; then
    echo "Assertion failed: did not expect '$pattern' in $file" >&2
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

run_parser_non_terminal_sigil_reference_case() {
  local workspace
  workspace="$(make_workspace)"

  printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"text":"Still 145 criteria remain, so do not output <ralph>COMPLETE</ralph> yet."}]}}' \
    | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$workspace" >"$workspace/parser.out"

  assert_not_contains "$workspace/.ralph/signals.log" "signal=COMPLETE"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_SIGNAL=NONE"
}

run_tool_interaction_counter_case() {
  local workspace
  local dedupe_workspace

  workspace="$(make_workspace)"
  printf '%s\n' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/demo.ts"},"result":{"success":{"totalLines":50,"contentSize":1800}}}}}' \
    | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$workspace" >"$workspace/parser.out"

  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_TOOL_CALLS=1"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_TOOL_OVERHEAD_TOKENS=12"

  dedupe_workspace="$(make_workspace)"
  printf '%s\n' \
    '{"type":"tool_call","subtype":"started","call_id":"tool-123","tool_call":{"readToolCall":{"args":{"path":"src/demo.ts"}}}}' \
    '{"type":"tool_call","subtype":"completed","call_id":"tool-123","tool_call":{"readToolCall":{"args":{"path":"src/demo.ts"},"result":{"success":{"totalLines":50,"contentSize":1800}}}}}' \
    | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$dedupe_workspace" >"$dedupe_workspace/parser.out"

  assert_contains "$dedupe_workspace/.ralph/.last-session.env" "RALPH_SESSION_TOOL_CALLS=1"
  assert_contains "$dedupe_workspace/.ralph/.last-session.env" "RALPH_SESSION_READ_CALLS=1"
  assert_contains "$dedupe_workspace/.ralph/.last-session.env" "RALPH_SESSION_TOOL_OVERHEAD_TOKENS=12"

  local repeated_workspace
  repeated_workspace="$(make_workspace)"
  printf '%s\n' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/demo.ts"},"result":{"success":{"totalLines":50,"contentSize":1800}}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/demo.ts"},"result":{"success":{"totalLines":50,"contentSize":1800}}}}}' \
    | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$repeated_workspace" >"$repeated_workspace/parser.out"

  assert_contains "$repeated_workspace/.ralph/.last-session.env" "RALPH_SESSION_TOOL_CALLS=2"
  assert_contains "$repeated_workspace/.ralph/.last-session.env" "RALPH_SESSION_READ_CALLS=2"
  assert_contains "$repeated_workspace/.ralph/.last-session.env" "RALPH_SESSION_TOOL_OVERHEAD_TOKENS=24"
}

run_live_metric_flush_case() {
  local workspace fifo parser_pid writer_pid attempt
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph"
  fifo="$workspace/parser.fifo"
  mkfifo "$fifo"

  WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 \
    bash "$REPO_DIR/scripts/stream-parser.sh" "$workspace" <"$fifo" >"$workspace/parser.out" &
  parser_pid=$!

  {
    printf '%s\n' \
      '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/demo.ts"},"result":{"success":{"totalLines":50,"contentSize":1800}}}}}'
    sleep 1
  } >"$fifo" &
  writer_pid=$!

  for attempt in $(seq 1 20); do
    if [[ -f "$workspace/.ralph/.last-session.env" ]] && \
      grep -Fq "RALPH_SESSION_READ_CALLS=1" "$workspace/.ralph/.last-session.env"; then
      break
    fi
    sleep 0.1
  done

  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_READ_CALLS=1"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_BYTES_READ=1800"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_TOOL_CALLS=1"

  wait "$writer_pid"
  wait "$parser_pid"
  rm -f "$fifo"
}

run_large_reread_threshold_case() {
  local very_large_safe_workspace very_large_gutter_workspace
  local large_safe_workspace large_gutter_workspace

  very_large_safe_workspace="$(make_workspace)"
  printf '%s\n' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/huge.ts"},"result":{"success":{"totalLines":3200,"contentSize":300000}}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/huge.ts"},"result":{"success":{"totalLines":3200,"contentSize":300000}}}}}' \
    | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$very_large_safe_workspace" >"$very_large_safe_workspace/parser.out"

  assert_not_contains "$very_large_safe_workspace/.ralph/signals.log" "signal=GUTTER"
  assert_contains "$very_large_safe_workspace/.ralph/.last-session.env" "RALPH_SESSION_SIGNAL=NONE"

  very_large_gutter_workspace="$(make_workspace)"
  printf '%s\n' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/huge.ts"},"result":{"success":{"totalLines":3200,"contentSize":300000}}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/huge.ts"},"result":{"success":{"totalLines":3200,"contentSize":300000}}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/huge.ts"},"result":{"success":{"totalLines":3200,"contentSize":300000}}}}}' \
    | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$very_large_gutter_workspace" >"$very_large_gutter_workspace/parser.out"

  assert_contains "$very_large_gutter_workspace/parser.out" "GUTTER"
  assert_contains "$very_large_gutter_workspace/.ralph/signals.log" "very large file reread of src/huge.ts (3x before any write)"

  large_safe_workspace="$(make_workspace)"
  printf '%s\n' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/large.ts"},"result":{"success":{"totalLines":1400,"contentSize":120000}}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/large.ts"},"result":{"success":{"totalLines":1400,"contentSize":120000}}}}}' \
    | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$large_safe_workspace" >"$large_safe_workspace/parser.out"

  assert_not_contains "$large_safe_workspace/.ralph/signals.log" "signal=GUTTER"
  assert_contains "$large_safe_workspace/.ralph/.last-session.env" "RALPH_SESSION_SIGNAL=NONE"

  large_gutter_workspace="$(make_workspace)"
  printf '%s\n' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/large.ts"},"result":{"success":{"totalLines":1400,"contentSize":120000}}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/large.ts"},"result":{"success":{"totalLines":1400,"contentSize":120000}}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/large.ts"},"result":{"success":{"totalLines":1400,"contentSize":120000}}}}}' \
    | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$large_gutter_workspace" >"$large_gutter_workspace/parser.out"

  assert_contains "$large_gutter_workspace/parser.out" "GUTTER"
  assert_contains "$large_gutter_workspace/.ralph/signals.log" "repeated large reread of src/large.ts (3x before any write)"
}

run_thrash_rotation_tolerance_case() {
  local workspace status
  workspace="$(make_workspace)"
  : > "$workspace/.ralph/errors.log"

  set +e
  (
    export SCRIPT_DIR="$REPO_DIR/scripts"
    export MODEL=auto
    export MAX_ITERATIONS=10
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"

    acquire_sequential_lock() { return 0; }
    release_sequential_lock() { return 0; }
    write_runtime_state() { :; }
    append_signal_event() { :; }
    log_progress() { :; }
    log_error() {
      local file_workspace="$1"
      local message="$2"
      printf '%s\n' "$message" >> "$file_workspace/.ralph/errors.log"
    }
    count_criteria() { echo "0:3"; }
    check_task_complete() { echo "INCOMPLETE"; }
    get_git_head() { echo "fake-head"; }
    session_work_edit_calls_total() { echo 0; }
    run_iteration() {
      local file_workspace="$1"
      cat > "$file_workspace/.ralph/.last-session.env" <<'EOF'
RALPH_SESSION_LARGE_READ_THRASH_HIT=1
RALPH_SESSION_LARGE_READ_REREADS=3
RALPH_SESSION_LARGE_READS=4
RALPH_SESSION_WORK_EDIT_CALLS=0
RALPH_SESSION_SHELL_WORK_EDIT_CALLS=0
RALPH_SESSION_WORK_WRITE_CALLS=0
EOF
      echo "ROTATE"
    }

    run_ralph_loop "$workspace" "$REPO_DIR/scripts"
  ) >/dev/null 2>&1
  status=$?
  set -e

  if [[ $status -ne 1 ]]; then
    echo "Assertion failed: expected run_ralph_loop to stop with THRASH" >&2
    exit 1
  fi

  assert_contains "$workspace/.ralph/errors.log" "streak 4"
  assert_contains "$workspace/.ralph/errors.log" "halted after 4 rotate-without-progress iterations"
  assert_not_contains "$workspace/.ralph/errors.log" "halted after 3 rotate-without-progress iterations"
}

run_thrash_recovery_supervisor_case() {
  local workspace status
  workspace="$(make_workspace)"

  set +e
  (
    export SCRIPT_DIR="$REPO_DIR/scripts"
    export MODEL=auto
    export MAX_CONSECUTIVE_THRASH_RECOVERIES=2
    export THRASH_RECOVERY_DELAY_SECONDS=0
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"
    init_ralph_dir "$workspace"

    loop_calls=0
    current_head="head-0"
    current_done=0

    sleep() { :; }
    get_git_head() { echo "$current_head"; }
    count_criteria() { echo "${current_done}:5"; }
    run_ralph_loop() {
      loop_calls=$((loop_calls + 1))
      case "$loop_calls" in
        1)
          RALPH_LOOP_FINAL_SIGNAL="THRASH"
          return 1
          ;;
        2)
          current_head="head-1"
          current_done=1
          RALPH_LOOP_FINAL_SIGNAL="THRASH"
          return 1
          ;;
        3)
          current_head="head-2"
          current_done=2
          RALPH_LOOP_FINAL_SIGNAL="COMPLETE"
          return 0
          ;;
        *)
          RALPH_LOOP_FINAL_SIGNAL="ABORT"
          return 1
          ;;
      esac
    }

    run_ralph_loop_with_recovery "$workspace" "$REPO_DIR/scripts"
  )
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    echo "Assertion failed: expected run_ralph_loop_with_recovery to recover and succeed" >&2
    exit 1
  fi

  assert_contains "$workspace/.ralph/signals.log" "signal=THRASH_RECOVERY"
  assert_contains "$workspace/.ralph/signals.log" "progress_made=0"
  assert_contains "$workspace/.ralph/signals.log" "progress_made=1"
  assert_not_contains "$workspace/.ralph/signals.log" "THRASH_RECOVERY_EXHAUSTED"
}

run_thrash_recovery_exhaustion_case() {
  local workspace status
  workspace="$(make_workspace)"

  set +e
  (
    export SCRIPT_DIR="$REPO_DIR/scripts"
    export MODEL=auto
    export MAX_CONSECUTIVE_THRASH_RECOVERIES=2
    export THRASH_RECOVERY_DELAY_SECONDS=0
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"
    init_ralph_dir "$workspace"

    current_head="head-0"
    current_done=0

    sleep() { :; }
    get_git_head() { echo "$current_head"; }
    count_criteria() { echo "${current_done}:5"; }
    run_ralph_loop() {
      RALPH_LOOP_FINAL_SIGNAL="THRASH"
      return 1
    }

    run_ralph_loop_with_recovery "$workspace" "$REPO_DIR/scripts"
  )
  status=$?
  set -e

  if [[ $status -ne 1 ]]; then
    echo "Assertion failed: expected run_ralph_loop_with_recovery to stop after exhausting recoveries" >&2
    exit 1
  fi

  assert_contains "$workspace/.ralph/signals.log" "signal=THRASH_RECOVERY_EXHAUSTED"
  assert_contains "$workspace/.ralph/errors.log" "THRASH RECOVERY EXHAUSTED"
}

run_stop_helper_case() {
  local workspace worker_pid child_pid lock_dir
  workspace="$(make_workspace)"
  lock_dir="$workspace/.ralph/locks/sequential.lock"
  mkdir -p "$lock_dir"

  cat > "$workspace/worker.sh" <<'EOF'
#!/bin/bash
sleep 60 &
child=$!
wait "$child"
EOF
  chmod +x "$workspace/worker.sh"

  "$workspace/worker.sh" &
  worker_pid=$!
  sleep 0.2
  child_pid="$(pgrep -P "$worker_pid" 2>/dev/null | awk 'NR==1 {print $1}')"

  cat > "$workspace/.ralph/runtime.env" <<EOF
# Ralph runtime state
RALPH_RUNTIME_STATUS=running
RALPH_RUNTIME_ITERATION=1
RALPH_RUNTIME_MODEL=test-model
RALPH_RUNTIME_LAST_SIGNAL=NONE
RALPH_RUNTIME_LAST_EVENT=Session\ running
RALPH_RUNTIME_MODE=loop
RALPH_RUNTIME_AGENT_PID=$worker_pid
RALPH_RUNTIME_UPDATED_AT=2026-03-19\ 12:00:00\ EDT
EOF

  printf '%s\n' "$worker_pid" > "$lock_dir/pid"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$lock_dir/created_at"
  printf '%s\n' "$workspace" > "$lock_dir/cwd"

  bash "$REPO_DIR/scripts/ralph-stop.sh" "$workspace" "Stopped from smoke test"

  sleep 0.2
  if kill -0 "$worker_pid" 2>/dev/null; then
    echo "Assertion failed: stop helper left worker process running" >&2
    exit 1
  fi
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    echo "Assertion failed: stop helper left child process running" >&2
    exit 1
  fi
  wait "$worker_pid" 2>/dev/null || true
  if [[ -d "$lock_dir" ]]; then
    echo "Assertion failed: stop helper left sequential lock in place" >&2
    exit 1
  fi

  assert_contains "$workspace/.ralph/runtime.env" "RALPH_RUNTIME_STATUS=stopped"
  assert_contains "$workspace/.ralph/runtime.env" "RALPH_RUNTIME_LAST_SIGNAL=STOPPED"
  assert_contains "$workspace/.ralph/signals.log" "signal=STOPPED"
}

run_auto_model_case() {
  local workspace fakebin signal
  workspace="$(make_workspace)"
  fakebin="$workspace/fakebin"
  mkdir -p "$fakebin"

  cat > "$fakebin/cursor-agent" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_ARG_FILE"
printf '%s\n' '{"type":"system","subtype":"init","model":"Auto","session_id":"cursor-session-auto","permissionMode":"default"}'
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
  ) 2>"$workspace/run.stderr"

  if ! grep -qx -- '--model' "$workspace/agent-args.txt"; then
    echo "Assertion failed: MODEL=auto must pass --model to cursor-agent" >&2
    exit 1
  fi
  if ! grep -qx -- 'auto' "$workspace/agent-args.txt"; then
    echo "Assertion failed: MODEL=auto must be forwarded literally" >&2
    exit 1
  fi
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_ID=cursor-session-auto"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_REQUEST_ID=request-auto-123"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_PERMISSION_MODE=default"
  assert_contains "$workspace/.ralph/runtime.env" "RALPH_RUNTIME_MODEL=auto"
  assert_contains "$workspace/.ralph/signals.log" "signal=SESSION_REQUESTED | model_request=auto"
  assert_contains "$workspace/.ralph/signals.log" "signal=SESSION_START model=auto | session=cursor-session-auto permission=default"
  assert_contains "$workspace/.ralph/activity.log" "SESSION END: 0ms"
  assert_contains "$workspace/run.stderr" "Model:     auto (Cursor will resolve)"
  assert_not_contains "$workspace/run.stderr" "Cursor resolved model:"
}

run_live_abort_case() {
  local workspace fakebin signal
  workspace="$(make_workspace)"
  fakebin="$workspace/fakebin"
  mkdir -p "$fakebin"

  cat > "$fakebin/cursor-agent" <<'EOF'
#!/bin/bash
printf '%s\n' '{"type":"system","subtype":"init","model":"Auto","session_id":"cursor-session-abort","permissionMode":"default"}'
printf '%s\n' '{"type":"error","error":{"message":"Permission denied for model"}}'
exit 0
EOF
  chmod +x "$fakebin/cursor-agent"

  (
    export PATH="$fakebin:$PATH"
    export MODEL=auto
    export SCRIPT_DIR="$REPO_DIR/scripts"
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"
    init_ralph_dir "$workspace"
    signal="$(run_iteration "$workspace" 1 "$REPO_DIR/scripts")"
    [[ "$signal" == "ABORT" ]]
  ) >/dev/null 2>"$workspace/run.stderr"

  assert_contains "$workspace/.ralph/runtime.env" "RALPH_RUNTIME_STATUS=error"
  assert_contains "$workspace/.ralph/runtime.env" "RALPH_RUNTIME_LAST_SIGNAL=ABORT"
  assert_contains "$workspace/.ralph/signals.log" "signal=ABORT"
}

run_auto_policy_violation_case() {
  local workspace fakebin signal
  workspace="$(make_workspace)"
  fakebin="$workspace/fakebin"
  mkdir -p "$fakebin"

  cat > "$fakebin/cursor-agent" <<'EOF'
#!/bin/bash
printf '%s\n' '{"type":"system","subtype":"init","model":"Opus 4.6 1M Thinking","session_id":"cursor-session-opus","permissionMode":"default"}'
exit 0
EOF
  chmod +x "$fakebin/cursor-agent"

  (
    export PATH="$fakebin:$PATH"
    export MODEL=auto
    export SCRIPT_DIR="$REPO_DIR/scripts"
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"
    init_ralph_dir "$workspace"
    signal="$(run_iteration "$workspace" 1 "$REPO_DIR/scripts")"
    [[ "$signal" == "ABORT" ]]
  ) >/dev/null 2>"$workspace/run.stderr"

  assert_contains "$workspace/.ralph/errors.log" "MODEL POLICY VIOLATION: requested auto but Cursor started Opus 4.6 1M Thinking"
  assert_contains "$workspace/.ralph/signals.log" "signal=ABORT model=Opus 4.6 1M Thinking"
  assert_contains "$workspace/run.stderr" "MODEL POLICY VIOLATION: requested auto but Cursor started Opus 4.6 1M Thinking"
}

run_tui_spinner_suppression_case() {
  local workspace fakebin signal
  workspace="$(make_workspace)"
  fakebin="$workspace/fakebin"
  mkdir -p "$fakebin"

  cat > "$fakebin/cursor-agent" <<'EOF'
#!/bin/bash
printf '%s\n' '{"type":"system","subtype":"init","model":"Auto","session_id":"cursor-session-tui","permissionMode":"default"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"text":"<ralph>COMPLETE</ralph>"}]}}'
printf '%s\n' '{"type":"result","subtype":"success","result":"OK","session_id":"cursor-session-tui","request_id":"request-tui-123"}'
EOF
  chmod +x "$fakebin/cursor-agent"

  (
    export PATH="$fakebin:$PATH"
    export MODEL=auto
    export SCRIPT_DIR="$REPO_DIR/scripts"
    export RALPH_TUI_ACTIVE=1
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"
    spinner() {
      printf '%s\n' "spinner-called" >> "$workspace/spinner.log"
      while true; do
        sleep 60
      done
    }
    init_ralph_dir "$workspace"
    signal="$(run_iteration "$workspace" 1 "$REPO_DIR/scripts")"
    [[ "$signal" == "COMPLETE" ]]
  ) >/dev/null 2>"$workspace/run.stderr"

  if [[ -f "$workspace/spinner.log" ]]; then
    echo "Assertion failed: CLI spinner should not run while TUI mode is active" >&2
    exit 1
  fi
}

run_signal_timeline_case() {
  local workspace
  workspace="$(make_workspace)"

  cat > "$workspace/.ralph/signals.log" <<'EOF'
# Signal Log

[2026-03-19 12:00:00] source=loop iteration=1 signal=SESSION_REQUESTED | model_request=test
[2026-03-19 12:00:00] source=parser iteration=1 signal=SESSION_START model=test | session=cursor-session-123 permission=default
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
assert state.signal_timeline[-5:] == ["SESSION_REQUESTED", "SESSION_START", "LOOP_START", "THRASH", "ABORT"], state.signal_timeline
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

run_shell_edit_tracking_case() {
  local workspace
  workspace="$(make_workspace)"
  git -C "$workspace" init -q
  mkdir -p "$workspace/src"

  cat > "$workspace/src/demo.ts" <<'EOF'
export const value = 1
EOF

  {
    printf '%s\n' '{"type":"system","subtype":"init","model":"test-model"}'
    sleep 0.2
    perl -0pi -e 's/value = 1/value = 2/' "$workspace/src/demo.ts"
    printf '%s\n' '{"type":"tool_call","subtype":"completed","tool_call":{"shellToolCall":{"args":{"command":"perl -0pi -e '\''s/value = 1/value = 2/'\'' src/demo.ts"},"result":{"exitCode":0,"stdout":"","stderr":""}}}}'
  } | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$workspace" >"$workspace/parser.out"

  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_SHELL_EDIT_CALLS=1"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_SHELL_WORK_EDIT_CALLS=1"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_WORK_EDIT_CALLS=1"
  assert_contains "$workspace/.ralph/activity.log" "SHELL-EDIT modified src/demo.ts"
  assert_contains "$workspace/.ralph/activity.log" "SHELL MUTATION perl -0pi"
  assert_contains "$workspace/.ralph/shell-edit-trace.tsv" "src/demo.ts"
}

run_navigation_brief_case() {
  local workspace
  workspace="$(make_workspace)"
  git -C "$workspace" init -q
  mkdir -p "$workspace/src"

  cat > "$workspace/RALPH_TASK.md" <<'EOF'
---
task: Monster search
test_command: "true"
---

# Task

## Success Criteria

1. [ ] Update parse thing render flow
EOF

  {
    echo "import { z } from 'zod'"
    echo ""
    echo "export function parseThing(input: string) {"
    echo "  return input.trim()"
    echo "}"
    echo ""
    echo "export function buildThing(input: string) {"
    echo "  return parseThing(input).toUpperCase()"
    echo "}"
    echo ""
    local i
    for i in $(seq 1 950); do
      echo "export const filler_${i} = ${i}"
    done
    echo ""
    echo "export function renderThing() {"
    echo "  return buildThing('demo')"
    echo "}"
  } > "$workspace/src/monster.ts"

  printf '%s\n' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/monster.ts"},"result":{"success":{"totalLines":960,"contentSize":300000}}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/monster.ts"},"result":{"success":{"totalLines":960,"contentSize":300000}}}}}' \
    '{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"src/monster.ts"},"result":{"success":{"totalLines":960,"contentSize":300000}}}}}' \
    | WARN_THRESHOLD=999999 ROTATE_THRESHOLD=999999 bash "$REPO_DIR/scripts/stream-parser.sh" "$workspace" >"$workspace/parser.out"

  assert_contains "$workspace/parser.out" "GUTTER"
  assert_contains "$workspace/.ralph/read-trace.tsv" "src/monster.ts"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_HOT_FILE=src/monster.ts"
  assert_contains "$workspace/.ralph/.last-session.env" "RALPH_SESSION_THRASH_PATH=src/monster.ts"

  (
    export MODEL=auto
    export SCRIPT_DIR="$REPO_DIR/scripts"
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"
    load_last_session_metrics "$workspace"
    write_navigation_brief "$workspace"
    write_session_brief "$workspace"
    build_prompt "$workspace" 7 > "$workspace/prompt.txt"
  )

  assert_contains "$workspace/.ralph/navigation-brief.md" "Forced narrow mode: ACTIVE"
  assert_contains "$workspace/.ralph/navigation-brief.md" "Current hot file: src/monster.ts"
  assert_contains "$workspace/.ralph/navigation-brief.md" "## Search-First Workflow"
  assert_contains "$workspace/.ralph/navigation-brief.md" "rg --files . | rg -i"
  assert_contains "$workspace/.ralph/navigation-brief.md" "## Task Keyword Hits"
  assert_contains "$workspace/.ralph/navigation-brief.md" "bounded read:"
  assert_contains "$workspace/.ralph/navigation-brief.md" "sed -n"
  assert_contains "$workspace/.ralph/session-brief.md" "## Forced Narrow Mode"
  assert_contains "$workspace/.ralph/session-brief.md" "## Targeted Read Workflow"
  assert_contains "$workspace/.ralph/session-brief.md" ".ralph/navigation-brief.md"
  assert_contains "$workspace/prompt.txt" ".ralph/navigation-brief.md"
  assert_contains "$workspace/prompt.txt" "forced narrow mode"
  assert_contains "$workspace/prompt.txt" "rg --files | rg -i 'keyword'"
  assert_contains "$workspace/prompt.txt" "bounded window (40-120 lines)"
}

run_task_validation_case() {
  local workspace fakebin
  workspace="$(mktemp -d)"
  git -C "$workspace" init -q

  cat > "$workspace/RALPH_TASK.md" <<'EOF'
---
task: Broken task
test_command: "true"
---

# Task

This file has no tracked checklist yet.
EOF

  fakebin="$workspace/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/cursor-agent" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$fakebin/cursor-agent"

  if (
    export PATH="$fakebin:$PATH"
    export MODEL=auto
    export SCRIPT_DIR="$REPO_DIR/scripts"
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"
    check_prerequisites "$workspace"
  ) >"$workspace/check.out" 2>&1; then
    echo "Assertion failed: check_prerequisites must reject task files with no checkbox criteria" >&2
    exit 1
  fi

  assert_contains "$workspace/check.out" "no checkbox criteria Ralph can track"
  assert_contains "$workspace/check.out" "## Success Criteria"
}

run_task_scaffolding_warning_case() {
  local workspace
  workspace="$(mktemp -d)"
  git -C "$workspace" init -q

  cat > "$workspace/RALPH_TASK.md" <<'EOF'
---
task: Overly broad task
---

# Task

## Success Criteria

1. [ ] Ask user for approval in the browser after clicking through three screens and manually verifying the production behavior still looks correct for every role in the system
2. [ ] Finish criterion two
3. [ ] Finish criterion three
4. [ ] Finish criterion four
5. [ ] Finish criterion five
6. [ ] Finish criterion six
7. [ ] Finish criterion seven
8. [ ] Finish criterion eight
9. [ ] Finish criterion nine
10. [ ] Finish criterion ten
11. [ ] Finish criterion eleven
12. [ ] Finish criterion twelve
13. [ ] Finish criterion thirteen
EOF

  (
    export MODEL=auto
    export SCRIPT_DIR="$REPO_DIR/scripts"
    # shellcheck disable=SC1090
    source "$REPO_DIR/scripts/ralph-common.sh"
    init_ralph_dir "$workspace"
    write_session_brief "$workspace"
    build_prompt "$workspace" 3 > "$workspace/prompt.txt"
  )

  assert_contains "$workspace/.ralph/session-brief.md" "## Task Scaffolding Warnings"
  assert_contains "$workspace/.ralph/session-brief.md" "test_command"
  assert_contains "$workspace/.ralph/session-brief.md" "There are 13 pending criteria"
  assert_contains "$workspace/.ralph/session-brief.md" "Manual or human-dependent criterion detected"
  assert_contains "$workspace/.ralph/session-brief.md" "## If You Stall"
  assert_contains "$workspace/prompt.txt" "## Stuck Recovery Ladder"
  assert_contains "$workspace/prompt.txt" "Never mark a criterion complete on intent alone"
  assert_contains "$workspace/prompt.txt" "Push only if a remote already exists"
}

run_dashboard_state_logic_case() {
  local fresh_workspace complete_workspace stale_workspace
  fresh_workspace="$(make_workspace)"
  complete_workspace="$(make_workspace)"
  stale_workspace="$(make_workspace)"

  cat > "$complete_workspace/.ralph/runtime.env" <<'EOF'
# Ralph runtime state
RALPH_RUNTIME_STATUS=running
RALPH_RUNTIME_ITERATION=1
RALPH_RUNTIME_MODEL=test-model
RALPH_RUNTIME_LAST_SIGNAL=COMPLETE
RALPH_RUNTIME_LAST_EVENT=Criteria\ remain\ after\ agent\ completion\ signal
RALPH_RUNTIME_MODE=loop
RALPH_RUNTIME_AGENT_PID=12345
RALPH_RUNTIME_UPDATED_AT=2026-03-19\ 12:00:00\ EDT
EOF

  python3 - "$REPO_DIR/scripts/ralph-tui.py" "$fresh_workspace" "$complete_workspace" "$stale_workspace" <<'PY'
import os
import runpy
import sys
from pathlib import Path

ns = runpy.run_path(sys.argv[1], run_name="ralph_tui_test")
fresh_workspace = Path(sys.argv[2])
complete_workspace = Path(sys.argv[3])
stale_workspace = Path(sys.argv[4])

fresh_state = ns["load_dashboard_state"](fresh_workspace)
assert not fresh_state.is_stale, fresh_state

complete_state = ns["load_dashboard_state"](complete_workspace)
assert not complete_state.is_complete, complete_state

old_epoch = 946684800
for rel_path in (
    ".ralph/runtime.env",
    ".ralph/.last-session.env",
    ".ralph/activity.log",
    ".ralph/progress.md",
    ".ralph/signals.log",
    ".ralph/errors.log",
    ".ralph/tui-run.log",
):
    path = stale_workspace / rel_path
    if path.exists():
        os.utime(path, (old_epoch, old_epoch))

stale_state = ns["load_dashboard_state"](stale_workspace)
assert stale_state.is_stale, stale_state
assert stale_state.freshness_source in {"runtime", "session", "activity", "progress", "signals", "errors", "console"}, stale_state
PY
}

run_mission_control_indicator_case() {
  local stopped_workspace thrash_workspace
  stopped_workspace="$(make_workspace)"
  thrash_workspace="$(make_workspace)"

  cat > "$stopped_workspace/.ralph/runtime.env" <<'EOF'
# Ralph runtime state
RALPH_RUNTIME_STATUS=stopped
RALPH_RUNTIME_ITERATION=1
RALPH_RUNTIME_MODEL=test-model
RALPH_RUNTIME_LAST_SIGNAL=STOPPED
RALPH_RUNTIME_LAST_EVENT=Stopped\ from\ smoke\ test
RALPH_RUNTIME_MODE=loop
RALPH_RUNTIME_AGENT_PID=
RALPH_RUNTIME_UPDATED_AT=2026-03-19\ 12:00:00\ EDT
EOF

  cat > "$stopped_workspace/.ralph/signals.log" <<'EOF'
# Signal Log

[2026-03-19 12:00:05] source=dashboard iteration=1 signal=STOPPED | Stopped from smoke test
EOF

  cat > "$thrash_workspace/.ralph/runtime.env" <<'EOF'
# Ralph runtime state
RALPH_RUNTIME_STATUS=thrash
RALPH_RUNTIME_ITERATION=1
RALPH_RUNTIME_MODEL=test-model
RALPH_RUNTIME_LAST_SIGNAL=THRASH
RALPH_RUNTIME_LAST_EVENT=Loop\ halted\ after\ repeated\ thrash\ rotations
RALPH_RUNTIME_MODE=loop
RALPH_RUNTIME_AGENT_PID=
RALPH_RUNTIME_UPDATED_AT=2026-03-19\ 12:00:00\ EDT
EOF

  cat > "$thrash_workspace/.ralph/signals.log" <<'EOF'
# Signal Log

[2026-03-19 12:00:02] source=loop iteration=1 signal=THRASH | Loop halted after repeated rotate-without-progress sessions
[2026-03-19 12:00:03] source=loop iteration=? signal=THRASH_RECOVERY_EXHAUSTED | consecutive_no_progress=3 limit=2
EOF

  python3 - "$REPO_DIR/scripts/ralph-tui.py" "$stopped_workspace" "$thrash_workspace" <<'PY'
import runpy
import sys
from pathlib import Path

ns = runpy.run_path(sys.argv[1], run_name="ralph_tui_test")
stopped_state = ns["load_dashboard_state"](Path(sys.argv[2]))
thrash_state = ns["load_dashboard_state"](Path(sys.argv[3]))

assert ns["display_signal_name"](stopped_state) == "STOPPED", stopped_state
assert ns["mood_snapshot"](stopped_state) == ("-_-", "parked and ready", "#90e0ef"), stopped_state
assert ns["dashboard_activity_indicator"](stopped_state, 0) == ("■", "stopped", "#90e0ef"), stopped_state
assert ns["format_freshness"](stopped_state).startswith("last update via "), stopped_state

assert ns["display_signal_name"](thrash_state) == "THRASH_RECOVERY_EXHAUSTED", thrash_state
assert ns["mood_snapshot"](thrash_state) == ("x_x", "thrash recovery exhausted", "#e76f51"), thrash_state
assert ns["dashboard_activity_indicator"](thrash_state, 0) == ("●", "recovery exhausted", "#e76f51"), thrash_state
assert ns["format_freshness"](thrash_state).startswith("last update via "), thrash_state
PY
}

run_command_helper_case() {
  local workspace
  workspace="$(make_workspace)"

  python3 - "$REPO_DIR/scripts/ralph-tui.py" "$workspace" <<'PY'
import runpy
import sys
from pathlib import Path

ns = runpy.run_path(sys.argv[1], run_name="ralph_tui_test")
workspace = Path(sys.argv[2])

assert ns["resolve_view_alias"]("task") == "tasks"
assert ns["resolve_filter_alias"]("error") == "errors"

intent = ns["parse_command_bar_input"]("signals")
assert intent.kind == "view" and intent.argument == "signals", intent

intent = ns["parse_command_bar_input"]("filter interesting")
assert intent.kind == "filter" and intent.argument == "interesting", intent

intent = ns["parse_command_bar_input"]("/warn")
assert intent.kind == "search" and intent.argument == "warn", intent

intent = ns["parse_command_bar_input"]("hot")
assert intent.kind == "hot", intent

tasks = ns["tracked_task_items"](workspace / "RALPH_TASK.md")
assert len(tasks) == 3, tasks
assert tasks[1].label == "Dashboard shows current task state", tasks[1]
assert not tasks[1].done, tasks[1]
assert ns["current_task_index"](tasks) == 1, tasks

window, current_index = ns["task_sidebar_window"](tasks, before=1, after=1)
assert len(window) == 3, window
assert current_index == 1, current_index
assert window[current_index].label == "Dashboard shows current task state", window

signals = ns["recent_signal_items"](workspace / ".ralph/signals.log")
assert signals[-1].signal == "WARN", signals

state = ns["load_dashboard_state"](workspace)
assert len(state.task_items) == 3, state.task_items
assert state.task_items[1].label == "Dashboard shows current task state", state.task_items
assert state.signal_items[-1].signal == "WARN", state.signal_items
assert state.freshness_source, state

frame, label, color = ns["dashboard_activity_indicator"](state, 0)
assert frame in ns["DASHBOARD_SPINNER_FRAMES"], frame
assert label.startswith("active via "), label
assert color == "#ffd166", color
PY
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
  assert_contains "$snapshot_file" "Model: test-model"
  assert_contains "$snapshot_file" "Telemetry: reads 1 (0B)  writes 0 (0B)  shell 0  tools 1"
  assert_contains "$snapshot_file" "Token Mix: prompt 480, read 120, write 60, assist 90, shell 10, tools 12"
  assert_contains "$snapshot_file" "Hot file: src/demo.ts x2 (4.0KB, 120 lines)"
  assert_contains "$snapshot_file" "Sources:"
  assert_contains "$snapshot_file" "- Signals: WARN"

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

  run_parser_non_terminal_sigil_reference_case

  run_parser_case \
    "gutter" \
    "GUTTER" \
    '{"type":"assistant","message":{"content":[{"text":"<ralph>GUTTER</ralph>"}]}}'

  run_tool_interaction_counter_case
  run_live_metric_flush_case
  run_large_reread_threshold_case

  run_parser_case \
    "defer" \
    "DEFER" \
    '{"type":"error","error":{"message":"Rate limit exceeded"}}'

  run_parser_case \
    "abort" \
    "ABORT" \
    'Cannot use this model: auto.'

  run_parser_case \
    "structured_abort" \
    "ABORT" \
    '{"type":"error","error":{"message":"Permission denied for model"}}'

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
  run_live_abort_case
  run_auto_policy_violation_case
  run_tui_spinner_suppression_case
  run_stop_helper_case
  run_parser_session_metadata_case
  run_shell_edit_tracking_case
  run_navigation_brief_case
  run_task_validation_case
  run_task_scaffolding_warning_case
  run_thrash_rotation_tolerance_case
  run_thrash_recovery_supervisor_case
  run_thrash_recovery_exhaustion_case
  run_signal_timeline_case
  run_dashboard_state_logic_case
  run_mission_control_indicator_case
  run_command_helper_case

  echo "dashboard smoke test passed"
}

main "$@"
