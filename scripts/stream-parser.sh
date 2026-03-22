#!/bin/bash
# Ralph Wiggum: Stream Parser
#
# Parses cursor-agent stream-json output in real-time.
# Tracks token usage, detects failures/gutter, writes to .ralph/ logs.
#
# Usage:
#   cursor-agent -p --force --output-format stream-json "..." | ./stream-parser.sh /path/to/workspace
#
# Outputs to stdout:
#   - ROTATE when threshold hit (200k tokens)
#   - WARN when approaching limit (170k tokens)
#   - GUTTER when stuck pattern detected
#   - COMPLETE when agent outputs <ralph>COMPLETE</ralph>
#
# Writes to .ralph/:
#   - activity.log: all operations with context health
#   - errors.log: failures and gutter detection

set -euo pipefail

WORKSPACE="${1:-.}"
RALPH_DIR="$WORKSPACE/.ralph"
SIGNALS_LOG="$RALPH_DIR/signals.log"
READ_TRACE_FILE="$RALPH_DIR/read-trace.tsv"
SHELL_EDIT_TRACE_FILE="$RALPH_DIR/shell-edit-trace.tsv"

# Ensure .ralph directory exists
mkdir -p "$RALPH_DIR"
if [[ ! -f "$READ_TRACE_FILE" ]]; then
  printf 'timestamp\titeration\tpath\tbytes\tlines\tper_file_reads\twrite_calls_before_read\tthrash_hit\n' > "$READ_TRACE_FILE"
fi
if [[ ! -f "$SHELL_EDIT_TRACE_FILE" ]]; then
  printf 'timestamp\titeration\texit_code\tstatus\tpath\tbefore_bytes\tafter_bytes\twork_path\tcommand\n' > "$SHELL_EDIT_TRACE_FILE"
fi

# Thresholds
WARN_THRESHOLD="${WARN_THRESHOLD:-170000}"
ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-200000}"
LARGE_READ_THRESHOLD_BYTES="${LARGE_READ_THRESHOLD_BYTES:-81920}"
VERY_LARGE_READ_THRESHOLD_BYTES="${VERY_LARGE_READ_THRESHOLD_BYTES:-262144}"
MAX_VERY_LARGE_REREADS_PER_FILE="${MAX_VERY_LARGE_REREADS_PER_FILE:-3}"
MAX_LARGE_REREADS_PER_FILE="${MAX_LARGE_REREADS_PER_FILE:-3}"
MAX_LARGE_READS_WITHOUT_WRITE="${MAX_LARGE_READS_WITHOUT_WRITE:-5}"
SNAPSHOT_CHECKSUM_MAX_BYTES="${SNAPSHOT_CHECKSUM_MAX_BYTES:-1048576}"

# Tracking state
BYTES_READ=0
BYTES_WRITTEN=0
ASSISTANT_CHARS=0
SHELL_OUTPUT_CHARS=0
PROMPT_CHARS=0
TOOL_CALLS=0
WARN_SENT=0
SESSION_START_SENT=0
READ_CALLS=0
WRITE_CALLS=0
WORK_WRITE_CALLS=0
SHELL_CALLS=0
SHELL_EDIT_CALLS=0
SHELL_WORK_EDIT_CALLS=0
LAST_SHELL_EDIT_COUNT=0
LAST_SHELL_WORK_EDIT_SEEN=0
LAST_SHELL_EDIT_BYTES=0
LAST_SHELL_EDIT_TOKENS=0
LARGE_READS=0
LARGE_READ_REREADS=0
TERMINAL_SIGNAL_SENT=0
ROTATE_SENT=0
GUTTER_SENT=0
COMPLETE_SENT=0
DEFER_SENT=0
ABORT_SENT=0
LAST_SIGNAL="NONE"
LARGE_READ_THRASH_HIT=0
TOKEN_EST_PROMPT=0
TOKEN_EST_READ=0
TOKEN_EST_WRITE=0
TOKEN_EST_ASSISTANT=0
TOKEN_EST_SHELL=0
CURSOR_SESSION_ID=""
CURSOR_REQUEST_ID=""
CURSOR_PERMISSION_MODE=""
CURSOR_MODEL="${RALPH_MODEL_RUNTIME:-unknown}"
HOT_LARGE_READ_PATH=""
HOT_LARGE_READ_COUNT=0
HOT_LARGE_READ_BYTES=0
HOT_LARGE_READ_LINES=0
THRASH_PATH=""

# Estimate initial prompt size (Ralph prompt is ~2KB + file references)
PROMPT_CHARS=3000

# Gutter detection - use temp files instead of associative arrays (macOS bash 3.x compat)
FAILURES_FILE=$(mktemp)
WRITES_FILE=$(mktemp)
READS_FILE=$(mktemp)
TOOL_INTERACTIONS_FILE=$(mktemp)
WORKSPACE_SNAPSHOT_FILE=$(mktemp)
WORKSPACE_SNAPSHOT_READY=0
trap "rm -f $FAILURES_FILE $WRITES_FILE $READS_FILE $TOOL_INTERACTIONS_FILE $WORKSPACE_SNAPSHOT_FILE" EXIT

# Get context health emoji
get_health_emoji() {
  local tokens=$1
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

calc_tokens() {
  echo $((TOKEN_EST_PROMPT + TOKEN_EST_READ + TOKEN_EST_WRITE + TOKEN_EST_ASSISTANT + TOKEN_EST_SHELL + (TOOL_CALLS * 12)))
}

estimate_tokens_by_ratio10() {
  local chars=$1
  local ratio10=${2:-40}

  if [[ $chars -le 0 ]]; then
    echo 0
    return
  fi

  echo $(((chars * 10 + ratio10 - 1) / ratio10))
}

estimate_density_ratio10() {
  local bytes=$1
  local lines=$2

  if [[ $bytes -le 0 ]]; then
    echo 34
    return
  fi

  if [[ $lines -le 0 ]]; then
    echo 34
    return
  fi

  local avg=$((bytes / lines))
  if [[ $avg -le 24 ]]; then
    echo 28
  elif [[ $avg -le 48 ]]; then
    echo 30
  elif [[ $avg -le 96 ]]; then
    echo 34
  elif [[ $avg -le 160 ]]; then
    echo 38
  else
    echo 42
  fi
}

estimate_prompt_tokens() {
  local chars=$1
  local payload
  payload=$(estimate_tokens_by_ratio10 "$chars" 34)
  echo $((payload + 120))
}

estimate_read_tokens() {
  local bytes=$1
  local lines=$2

  if [[ $bytes -le 0 ]]; then
    bytes=$((lines * 90))
  fi

  local ratio10
  ratio10=$(estimate_density_ratio10 "$bytes" "$lines")
  local payload
  payload=$(estimate_tokens_by_ratio10 "$bytes" "$ratio10")
  local structural=$((lines / 40 + 14))
  echo $((payload + structural))
}

estimate_write_tokens() {
  local bytes=$1
  local lines=$2

  if [[ $bytes -le 0 ]]; then
    bytes=$((lines * 90))
  fi

  local ratio10
  ratio10=$(estimate_density_ratio10 "$bytes" "$lines")
  if [[ $ratio10 -gt 30 ]]; then
    ratio10=$((ratio10 - 2))
  fi
  local payload
  payload=$(estimate_tokens_by_ratio10 "$bytes" "$ratio10")
  local structural=$((lines / 30 + 18))
  echo $((payload + structural))
}

estimate_assistant_tokens() {
  local chars=$1
  local text="$2"
  local ratio10=36

  if [[ "$text" == *'```'* ]]; then
    ratio10=30
  elif [[ "$text" == *$'\n'* ]]; then
    ratio10=34
  fi

  local payload
  payload=$(estimate_tokens_by_ratio10 "$chars" "$ratio10")
  echo $((payload + 12))
}

estimate_shell_tokens() {
  local chars=$1
  local lines=$2

  if [[ $chars -le 0 ]]; then
    echo 0
    return
  fi

  local ratio10=42
  if [[ $lines -ge 20 ]]; then
    ratio10=38
  fi

  local payload
  payload=$(estimate_tokens_by_ratio10 "$chars" "$ratio10")
  echo $((payload + lines / 25 + 8))
}

TOKEN_EST_PROMPT=$(estimate_prompt_tokens "$PROMPT_CHARS")

log_signal_event() {
  local signal="$1"
  local detail="${2:-}"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  if [[ -n "$detail" ]]; then
    printf '[%s] source=parser iteration=%s signal=%s model=%s | %s\n' \
      "$timestamp" "${RALPH_ITERATION:-?}" "$signal" "${RALPH_MODEL_RUNTIME:-unknown}" "$detail" >> "$SIGNALS_LOG"
  else
    printf '[%s] source=parser iteration=%s signal=%s model=%s\n' \
      "$timestamp" "${RALPH_ITERATION:-?}" "$signal" "${RALPH_MODEL_RUNTIME:-unknown}" >> "$SIGNALS_LOG"
  fi
}

emit_signal_once() {
  local signal="$1"
  local activity_message="${2:-}"
  local error_message="${3:-}"

  # ROTATE / COMPLETE / DEFER are terminal for the current parser session.
  # GUTTER is sticky, but non-terminal, so a later ROTATE can still happen.
  if [[ $TERMINAL_SIGNAL_SENT -eq 1 ]] && [[ "$LAST_SIGNAL" != "$signal" ]]; then
    return
  fi

  case "$signal" in
    "ROTATE")
      [[ $ROTATE_SENT -eq 1 ]] && return
      ROTATE_SENT=1
      TERMINAL_SIGNAL_SENT=1
      ;;
    "GUTTER")
      [[ $GUTTER_SENT -eq 1 ]] && return
      GUTTER_SENT=1
      ;;
    "COMPLETE")
      [[ $COMPLETE_SENT -eq 1 ]] && return
      COMPLETE_SENT=1
      TERMINAL_SIGNAL_SENT=1
      ;;
    "DEFER")
      [[ $DEFER_SENT -eq 1 ]] && return
      DEFER_SENT=1
      TERMINAL_SIGNAL_SENT=1
      ;;
    "ABORT")
      [[ $ABORT_SENT -eq 1 ]] && return
      ABORT_SENT=1
      TERMINAL_SIGNAL_SENT=1
      ;;
    *)
      ;;
  esac

  if [[ -n "$activity_message" ]]; then
    log_activity "$activity_message"
  fi

  if [[ -n "$error_message" ]]; then
    log_error "$error_message"
  fi

  LAST_SIGNAL="$signal"
  log_signal_event "$signal" "${activity_message:-$error_message}"
  write_session_metrics
  echo "$signal" 2>/dev/null || true
}

# Log to activity.log
log_activity() {
  local message="$1"
  local timestamp=$(date '+%H:%M:%S')
  local tokens=$(calc_tokens)
  local emoji=$(get_health_emoji $tokens)
  
  echo "[$timestamp] $emoji $message" >> "$RALPH_DIR/activity.log"
}

# Log to errors.log
log_error() {
  local message="$1"
  local timestamp=$(date '+%H:%M:%S')
  
  echo "[$timestamp] $message" >> "$RALPH_DIR/errors.log"
}

# Check and log token status
log_token_status() {
  local tokens=$(calc_tokens)
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  local emoji=$(get_health_emoji $tokens)
  local timestamp=$(date '+%H:%M:%S')
  
  local status_msg="TOKENS: $tokens / $ROTATE_THRESHOLD ($pct%)"
  
  if [[ $pct -ge 90 ]]; then
    status_msg="$status_msg - rotation imminent"
  elif [[ $pct -ge 72 ]]; then
    status_msg="$status_msg - approaching limit"
  fi
  
  local breakdown="[read:$((BYTES_READ/1024))KB write:$((BYTES_WRITTEN/1024))KB assist:$((ASSISTANT_CHARS/1024))KB shell:$((SHELL_OUTPUT_CHARS/1024))KB]"
  echo "[$timestamp] $emoji $status_msg $breakdown" >> "$RALPH_DIR/activity.log"
}

# Check if an error message indicates a retryable API error
# Returns: 0 if retryable (should defer), 1 if not retryable
is_retryable_api_error() {
  local error_msg="$1"
  local lower_msg
  lower_msg=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')
  
  # Rate limit patterns
  if [[ "$lower_msg" =~ (rate[[:space:]]*limit|rate_limit|rate-limit) ]] || \
     [[ "$lower_msg" =~ (quota[[:space:]]*exceeded|quota[[:space:]]*limit|hit[[:space:]]*your[[:space:]]*limit) ]] || \
     [[ "$lower_msg" =~ (too[[:space:]]*many[[:space:]]*requests|429|http[[:space:]]*429) ]]; then
    return 0
  fi
  
  # Network/connection patterns
  if [[ "$lower_msg" =~ (timeout|timed[[:space:]]*out|connection[[:space:]]*timeout) ]] || \
     [[ "$lower_msg" =~ (network[[:space:]]*error|network[[:space:]]*unavailable) ]] || \
     [[ "$lower_msg" =~ (connection[[:space:]]*refused|connection[[:space:]]*reset|econnreset) ]] || \
     [[ "$lower_msg" =~ (connection[[:space:]]*closed|connection[[:space:]]*failed|etimedout|enotfound) ]]; then
    return 0
  fi
  
  # Server error patterns
  if [[ "$lower_msg" =~ (service[[:space:]]*unavailable|503) ]] || \
     [[ "$lower_msg" =~ (bad[[:space:]]*gateway|502) ]] || \
     [[ "$lower_msg" =~ (gateway[[:space:]]*timeout|504) ]] || \
     [[ "$lower_msg" =~ (overloaded|server[[:space:]]*busy|try[[:space:]]*again) ]]; then
    return 0
  fi
  
  return 1  # Not retryable
}

# Check for gutter conditions
check_gutter() {
  local tokens=$(calc_tokens)

  if [[ $TERMINAL_SIGNAL_SENT -eq 1 ]]; then
    return
  fi
  
  # Check rotation threshold
  if [[ $tokens -ge $ROTATE_THRESHOLD ]]; then
    emit_signal_once "ROTATE" "ROTATE: Token threshold reached ($tokens >= $ROTATE_THRESHOLD)"
    return
  fi
  
  # Check warning threshold (only emit once per session)
  if [[ $tokens -ge $WARN_THRESHOLD ]] && [[ $WARN_SENT -eq 0 ]]; then
    log_activity "WARN: Approaching token limit ($tokens >= $WARN_THRESHOLD)"
    log_signal_event "WARN" "Approaching token limit ($tokens >= $WARN_THRESHOLD)"
    WARN_SENT=1
    echo "WARN" 2>/dev/null || true
  fi
}

# Track shell command failure
track_shell_failure() {
  local cmd="$1"
  local exit_code="$2"
  
  if [[ $exit_code -ne 0 ]]; then
    # Count failures for this command
    local count
    count=$(grep -Fxc -- "$cmd" "$FAILURES_FILE" 2>/dev/null) || count=0
    count=$((count + 1))
    echo "$cmd" >> "$FAILURES_FILE"
    
    log_error "SHELL FAIL: $cmd → exit $exit_code (attempt $count)"
    
    if [[ $count -ge 3 ]]; then
      emit_signal_once "GUTTER" "" "⚠️ GUTTER: same command failed ${count}x"
    fi
  fi
}

# Track file writes for thrashing detection
track_file_write() {
  local path="$1"
  local now=$(date +%s)
  
  # Log write with timestamp
  echo "$now:$path" >> "$WRITES_FILE"
  
  # Count writes to this file in last 10 minutes
  local cutoff=$((now - 600))
  local count=$(awk -F: -v cutoff="$cutoff" -v path="$path" '
    $1 >= cutoff && $2 == path { count++ }
    END { print count+0 }
  ' "$WRITES_FILE")
  
  # Check for thrashing (5+ writes in 10 minutes)
  if [[ $count -ge 5 ]]; then
    emit_signal_once "GUTTER" "" "⚠️ THRASHING: $path written ${count}x in 10 min"
  fi
}

total_mutation_calls() {
  echo $((WRITE_CALLS + SHELL_EDIT_CALLS))
}

normalize_workspace_path() {
  local path="$1"

  if [[ -z "$path" ]]; then
    return 1
  fi

  if [[ "$path" == "$WORKSPACE" ]]; then
    echo "."
    return 0
  fi

  if [[ "$path" == "$WORKSPACE/"* ]]; then
    path="${path#$WORKSPACE/}"
  elif [[ "$path" == ./* ]]; then
    path="${path#./}"
  fi

  if [[ "$path" == /* ]]; then
    return 1
  fi

  echo "$path"
}

should_track_snapshot_path() {
  local path="$1"

  case "$path" in
    ""|"."|".git"|".git/"* )
      return 1
      ;;
    ".ralph/activity.log"|".ralph/errors.log"|".ralph/signals.log"|".ralph/.last-session.env"|".ralph/read-trace.tsv"|".ralph/shell-edit-trace.tsv" )
      return 1
      ;;
  esac

  return 0
}

is_snapshot_extra_path() {
  local path="$1"

  case "$path" in
    "RALPH_TASK.md"|".ralph/progress.md"|".ralph/guardrails.md"|".ralph/session-brief.md"|".ralph/navigation-brief.md")
      return 0
      ;;
  esac

  return 1
}

is_work_path() {
  local path="$1"

  case "$path" in
    .ralph/*)
      return 1
      ;;
  esac

  return 0
}

path_is_snapshot_candidate() {
  local path="$1"

  should_track_snapshot_path "$path" || return 1

  if is_snapshot_extra_path "$path"; then
    return 0
  fi

  (
    cd "$WORKSPACE" || exit 1
    git ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || \
      git ls-files --others --exclude-standard -- "$path" 2>/dev/null | grep -Fxq -- "$path"
  )
}

file_stat_signature() {
  local path="$1"

  if stat -f $'%m\t%z' "$path" >/dev/null 2>&1; then
    stat -f $'%m\t%z' "$path"
  else
    stat -c $'%Y\t%s' "$path"
  fi
}

file_snapshot_signature() {
  local path="$1"
  local meta mtime size checksum="-"

  meta=$(file_stat_signature "$path" 2>/dev/null) || return 1
  mtime="${meta%%$'\t'*}"
  size="${meta##*$'\t'}"

  if [[ "$size" =~ ^[0-9]+$ ]] && [[ "$size" -le "$SNAPSHOT_CHECKSUM_MAX_BYTES" ]]; then
    checksum=$(cksum < "$path" 2>/dev/null | awk '{print $1 ":" $2}')
  fi

  printf '%s\t%s\t%s\n' "$mtime" "$size" "$checksum"
}

list_snapshot_candidates() {
  (
    cd "$WORKSPACE" || exit 0
    git ls-files -z --cached --others --exclude-standard 2>/dev/null || true

    local extra
    for extra in "RALPH_TASK.md" ".ralph/progress.md" ".ralph/guardrails.md" ".ralph/session-brief.md" ".ralph/navigation-brief.md"; do
      if [[ -f "$extra" ]]; then
        printf '%s\0' "$extra"
      fi
    done
  ) | tr '\0' '\n' | awk 'NF && !seen[$0]++ { print $0 }'
}

snapshot_workspace_state() {
  local out_file="$1"
  local tmp_file
  tmp_file=$(mktemp)
  : > "$tmp_file"

  while IFS= read -r rel_path; do
    local abs_path signature

    [[ -n "$rel_path" ]] || continue
    should_track_snapshot_path "$rel_path" || continue

    abs_path="$WORKSPACE/$rel_path"
    [[ -f "$abs_path" ]] || continue

    signature=$(file_snapshot_signature "$abs_path") || continue
    printf '%s\t%s\n' "$rel_path" "$signature" >> "$tmp_file"
  done < <(list_snapshot_candidates)

  LC_ALL=C sort "$tmp_file" > "$out_file"
  rm -f "$tmp_file"
}

ensure_workspace_snapshot() {
  if [[ "$WORKSPACE_SNAPSHOT_READY" -eq 0 ]]; then
    snapshot_workspace_state "$WORKSPACE_SNAPSHOT_FILE"
    WORKSPACE_SNAPSHOT_READY=1
  fi
}

update_workspace_snapshot_entry() {
  local raw_path="$1"
  local path tmp_file abs_path signature

  path=$(normalize_workspace_path "$raw_path") || return 0
  path_is_snapshot_candidate "$path" || return 0

  ensure_workspace_snapshot

  tmp_file=$(mktemp)
  awk -F '\t' -v target="$path" '$1 != target { print }' "$WORKSPACE_SNAPSHOT_FILE" > "$tmp_file"

  abs_path="$WORKSPACE/$path"
  if [[ -f "$abs_path" ]]; then
    signature=$(file_snapshot_signature "$abs_path") || signature=""
    if [[ -n "$signature" ]]; then
      printf '%s\t%s\n' "$path" "$signature" >> "$tmp_file"
    fi
  fi

  LC_ALL=C sort "$tmp_file" -o "$tmp_file"
  mv "$tmp_file" "$WORKSPACE_SNAPSHOT_FILE"
}

snapshot_diff_rows() {
  local before_file="$1"
  local after_file="$2"

  awk -F '\t' '
    NR == FNR {
      before[$1] = $0
      before_size[$1] = $3
      next
    }
    {
      after[$1] = $0
      if (!($1 in before)) {
        print "created\t" $1 "\t0\t" $3
      } else if (before[$1] != $0) {
        print "modified\t" $1 "\t" before_size[$1] "\t" $3
      }
      delete before[$1]
      delete before_size[$1]
    }
    END {
      for (path in before) {
        print "deleted\t" path "\t" before_size[path] "\t0"
      }
    }
  ' "$before_file" "$after_file" | LC_ALL=C sort
}

sanitize_trace_field() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

append_shell_edit_trace() {
  local cmd="$1"
  local exit_code="$2"
  local status="$3"
  local path="$4"
  local before_bytes="$5"
  local after_bytes="$6"
  local work_path_flag="$7"
  local safe_cmd

  safe_cmd=$(sanitize_trace_field "$cmd")

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${RALPH_ITERATION:-0}" \
    "$exit_code" \
    "$status" \
    "$path" \
    "$before_bytes" \
    "$after_bytes" \
    "$work_path_flag" \
    "$safe_cmd" >> "$SHELL_EDIT_TRACE_FILE"
}

track_shell_edits() {
  local cmd="$1"
  local exit_code="$2"
  local after_snapshot tmp_diff
  local edit_count=0
  local work_edit_seen=0
  local bytes_changed=0
  local write_tokens=0

  ensure_workspace_snapshot
  LAST_SHELL_EDIT_COUNT=0
  LAST_SHELL_WORK_EDIT_SEEN=0
  LAST_SHELL_EDIT_BYTES=0
  LAST_SHELL_EDIT_TOKENS=0

  after_snapshot=$(mktemp)
  tmp_diff=$(mktemp)
  snapshot_workspace_state "$after_snapshot"
  snapshot_diff_rows "$WORKSPACE_SNAPSHOT_FILE" "$after_snapshot" > "$tmp_diff"

  while IFS=$'\t' read -r status path before_bytes after_bytes; do
    local bytes_for_tokens=0
    local work_flag=0

    [[ -n "$status" ]] || continue
    edit_count=$((edit_count + 1))

    if is_work_path "$path"; then
      work_flag=1
      work_edit_seen=1
    fi

    if [[ "$status" == "deleted" ]]; then
      bytes_for_tokens="$before_bytes"
    else
      bytes_for_tokens="$after_bytes"
    fi
    [[ "$bytes_for_tokens" =~ ^[0-9]+$ ]] || bytes_for_tokens=0
    bytes_changed=$((bytes_changed + bytes_for_tokens))

    track_file_write "$path"
    append_shell_edit_trace "$cmd" "$exit_code" "$status" "$path" "$before_bytes" "$after_bytes" "$work_flag"
    log_activity "SHELL-EDIT $status $path (${before_bytes}B -> ${after_bytes}B)"
  done < "$tmp_diff"

  if [[ "$edit_count" -gt 0 ]]; then
    local estimated_lines=$((bytes_changed / 90))
    if [[ "$estimated_lines" -lt 1 ]]; then
      estimated_lines=1
    fi

    write_tokens=$(estimate_write_tokens "$bytes_changed" "$estimated_lines")
    BYTES_WRITTEN=$((BYTES_WRITTEN + bytes_changed))
    TOKEN_EST_WRITE=$((TOKEN_EST_WRITE + write_tokens))
    SHELL_EDIT_CALLS=$((SHELL_EDIT_CALLS + 1))
    if [[ "$work_edit_seen" -eq 1 ]]; then
      SHELL_WORK_EDIT_CALLS=$((SHELL_WORK_EDIT_CALLS + 1))
    fi
  fi

  LAST_SHELL_EDIT_COUNT="$edit_count"
  LAST_SHELL_WORK_EDIT_SEEN="$work_edit_seen"
  LAST_SHELL_EDIT_BYTES="$bytes_changed"
  LAST_SHELL_EDIT_TOKENS="$write_tokens"

  mv "$after_snapshot" "$WORKSPACE_SNAPSHOT_FILE"
  rm -f "$tmp_diff"
}

track_file_read() {
  local path="$1"
  local bytes="$2"
  local lines="$3"
  local now=$(date +%s)
  local mutation_calls

  mutation_calls=$(total_mutation_calls)

  READ_CALLS=$((READ_CALLS + 1))
  printf '%s\t%s\t%s\t%s\n' "$now" "$path" "$bytes" "$lines" >> "$READS_FILE"

  if [[ $bytes -lt $LARGE_READ_THRESHOLD_BYTES ]]; then
    return
  fi

  LARGE_READS=$((LARGE_READS + 1))

  local per_file_count
  per_file_count=$(awk -F '\t' -v path="$path" '
    $2 == path { count++ }
    END { print count+0 }
  ' "$READS_FILE")

  if [[ $per_file_count -gt $HOT_LARGE_READ_COUNT ]]; then
    HOT_LARGE_READ_PATH="$path"
    HOT_LARGE_READ_COUNT=$per_file_count
    HOT_LARGE_READ_BYTES=$bytes
    HOT_LARGE_READ_LINES=$lines
  fi

  if [[ $per_file_count -ge 2 ]]; then
    LARGE_READ_REREADS=$((LARGE_READ_REREADS + 1))
  fi

  local read_triggered_thrash=0

  if [[ $mutation_calls -eq 0 && $bytes -ge $VERY_LARGE_READ_THRESHOLD_BYTES && $per_file_count -ge $MAX_VERY_LARGE_REREADS_PER_FILE ]]; then
    LARGE_READ_THRASH_HIT=1
    THRASH_PATH="$path"
    read_triggered_thrash=1
    emit_signal_once \
      "GUTTER" \
      "🚨 THRASH: very large file reread of $path (${per_file_count}x before any write)" \
      "⚠️ THRASH: very large file $path reread ${per_file_count}x before any write"
  elif [[ $mutation_calls -eq 0 && $per_file_count -ge $MAX_LARGE_REREADS_PER_FILE ]]; then
    LARGE_READ_THRASH_HIT=1
    THRASH_PATH="$path"
    read_triggered_thrash=1
    emit_signal_once \
      "GUTTER" \
      "🚨 THRASH: repeated large reread of $path (${per_file_count}x before any write)" \
      "⚠️ THRASH: $path reread ${per_file_count}x in one session before any write"
  elif [[ $mutation_calls -eq 0 && $LARGE_READS -ge $MAX_LARGE_READS_WITHOUT_WRITE ]]; then
    LARGE_READ_THRASH_HIT=1
    THRASH_PATH="$path"
    read_triggered_thrash=1
    emit_signal_once \
      "GUTTER" \
      "🚨 THRASH: ${LARGE_READS} large reads without any write this session" \
      "⚠️ THRASH: ${LARGE_READS} large reads occurred before any write"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${RALPH_ITERATION:-0}" \
    "$path" \
    "$bytes" \
    "$lines" \
    "$per_file_count" \
    "$mutation_calls" \
    "$read_triggered_thrash" >> "$READ_TRACE_FILE"
}

write_session_metrics() {
  local summary_file="$RALPH_DIR/.last-session.env"
  local tmp_file
  local tokens
  tokens=$(calc_tokens)
  tmp_file=$(mktemp)

  {
    printf 'RALPH_SESSION_ITERATION=%q\n' "${RALPH_ITERATION:-0}"
    printf 'RALPH_SESSION_ID=%q\n' "$CURSOR_SESSION_ID"
    printf 'RALPH_SESSION_REQUEST_ID=%q\n' "$CURSOR_REQUEST_ID"
    printf 'RALPH_SESSION_PERMISSION_MODE=%q\n' "$CURSOR_PERMISSION_MODE"
    printf 'RALPH_SESSION_MODEL=%q\n' "$CURSOR_MODEL"
    printf 'RALPH_SESSION_SIGNAL=%q\n' "${LAST_SIGNAL:-NONE}"
    printf 'RALPH_SESSION_TOKENS=%q\n' "$tokens"
    printf 'RALPH_SESSION_BYTES_READ=%q\n' "$BYTES_READ"
    printf 'RALPH_SESSION_BYTES_WRITTEN=%q\n' "$BYTES_WRITTEN"
    printf 'RALPH_SESSION_ASSISTANT_CHARS=%q\n' "$ASSISTANT_CHARS"
    printf 'RALPH_SESSION_SHELL_OUTPUT_CHARS=%q\n' "$SHELL_OUTPUT_CHARS"
    printf 'RALPH_SESSION_TOOL_CALLS=%q\n' "$TOOL_CALLS"
    printf 'RALPH_SESSION_READ_CALLS=%q\n' "$READ_CALLS"
    printf 'RALPH_SESSION_WRITE_CALLS=%q\n' "$WRITE_CALLS"
    printf 'RALPH_SESSION_WORK_WRITE_CALLS=%q\n' "$WORK_WRITE_CALLS"
    printf 'RALPH_SESSION_SHELL_CALLS=%q\n' "$SHELL_CALLS"
    printf 'RALPH_SESSION_SHELL_EDIT_CALLS=%q\n' "$SHELL_EDIT_CALLS"
    printf 'RALPH_SESSION_SHELL_WORK_EDIT_CALLS=%q\n' "$SHELL_WORK_EDIT_CALLS"
    printf 'RALPH_SESSION_WORK_EDIT_CALLS=%q\n' "$((WORK_WRITE_CALLS + SHELL_WORK_EDIT_CALLS))"
    printf 'RALPH_SESSION_LARGE_READS=%q\n' "$LARGE_READS"
    printf 'RALPH_SESSION_LARGE_READ_REREADS=%q\n' "$LARGE_READ_REREADS"
    printf 'RALPH_SESSION_LARGE_READ_THRASH_HIT=%q\n' "$LARGE_READ_THRASH_HIT"
    printf 'RALPH_SESSION_HOT_FILE=%q\n' "$HOT_LARGE_READ_PATH"
    printf 'RALPH_SESSION_HOT_FILE_READS=%q\n' "$HOT_LARGE_READ_COUNT"
    printf 'RALPH_SESSION_HOT_FILE_BYTES=%q\n' "$HOT_LARGE_READ_BYTES"
    printf 'RALPH_SESSION_HOT_FILE_LINES=%q\n' "$HOT_LARGE_READ_LINES"
    printf 'RALPH_SESSION_THRASH_PATH=%q\n' "$THRASH_PATH"
    printf 'RALPH_SESSION_PROMPT_TOKENS=%q\n' "$TOKEN_EST_PROMPT"
    printf 'RALPH_SESSION_READ_TOKENS=%q\n' "$TOKEN_EST_READ"
    printf 'RALPH_SESSION_WRITE_TOKENS=%q\n' "$TOKEN_EST_WRITE"
    printf 'RALPH_SESSION_ASSISTANT_TOKENS=%q\n' "$TOKEN_EST_ASSISTANT"
    printf 'RALPH_SESSION_SHELL_TOKENS=%q\n' "$TOKEN_EST_SHELL"
    printf 'RALPH_SESSION_TOOL_OVERHEAD_TOKENS=%q\n' "$((TOOL_CALLS * 12))"
  } > "$tmp_file"

  if [[ -f "$summary_file" ]] && cmp -s "$tmp_file" "$summary_file"; then
    rm -f "$tmp_file"
    return
  fi

  mv "$tmp_file" "$summary_file"
}

log_session_result() {
  local duration_ms="${1:-0}"
  local tokens
  tokens=$(calc_tokens)
  log_activity "SESSION END: ${duration_ms}ms, ~$tokens tokens used"
}

process_raw_line() {
  local line="$1"
  local trimmed="${line//$'\r'/}"

  [[ -n "$trimmed" ]] || return 0

  log_activity "AGENT RAW: $trimmed"

  if [[ "$trimmed" == "Cannot use this model:"* ]]; then
    emit_signal_once "ABORT" "AGENT RAW: $trimmed" "AGENT CONFIG: $trimmed"
  else
    emit_signal_once "ABORT" "AGENT RAW: $trimmed" "AGENT RAW: $trimmed"
  fi
}

assistant_has_standalone_sigil() {
  local text="$1"
  local sigil="$2"

  printf '%s\n' "$text" | grep -Eq "^[[:space:]]*${sigil}[[:space:]]*$"
}

tool_call_id() {
  local line="$1"
  local call_id

  call_id=$(echo "$line" | jq -r '.call_id // .callId // .tool_call.call_id // .tool_call.callId // empty' 2>/dev/null) || call_id=""
  if [[ -n "$call_id" ]] && [[ "$call_id" != "null" ]]; then
    printf '%s\n' "$call_id"
  fi
}

record_tool_interaction() {
  local subtype="$1"
  local call_id="$2"

  if [[ -n "$call_id" ]]; then
    local key="id:$call_id"
    if grep -Fxq -- "$key" "$TOOL_INTERACTIONS_FILE" 2>/dev/null; then
      return 1
    fi

    printf '%s\n' "$key" >> "$TOOL_INTERACTIONS_FILE"
    TOOL_CALLS=$((TOOL_CALLS + 1))
    return 0
  fi

  # Anonymous tool calls often repeat the same args across legitimate rereads.
  # Count each completed event rather than deduping by args, or the dashboard
  # under-reports tool usage whenever the agent retries an identical action.
  if [[ "$subtype" == "completed" ]]; then
    TOOL_CALLS=$((TOOL_CALLS + 1))
    return 0
  fi

  return 1
}

# Process a single JSON line from stream
process_line() {
  local line="$1"
  
  # Skip empty lines
  [[ -z "$line" ]] && return
  
  # Parse JSON type
  local type
  if ! type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null); then
    process_raw_line "$line"
    return
  fi
  local subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null) || true
  
  case "$type" in
    "system")
      if [[ "$subtype" == "init" ]]; then
        local requested_model="${RALPH_MODEL_RUNTIME:-unknown}"
        local requested_model_normalized
        requested_model_normalized=$(printf '%s' "$requested_model" | tr '[:upper:]' '[:lower:]')
        local model=$(echo "$line" | jq -r '.model // "unknown"' 2>/dev/null) || model="unknown"
        local model_normalized
        model_normalized=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
        local session_id=$(echo "$line" | jq -r '.session_id // .sessionId // .chatId // empty' 2>/dev/null) || session_id=""
        local permission_mode=$(echo "$line" | jq -r '.permissionMode // .permission_mode // empty' 2>/dev/null) || permission_mode=""
        if [[ "$requested_model_normalized" == "auto" ]]; then
          if [[ "$model_normalized" == *"auto"* ]]; then
            model="auto"
            model_normalized="auto"
          else
            CURSOR_MODEL="$model"
            RALPH_MODEL_RUNTIME="$model"
            if [[ -n "$session_id" ]]; then
              CURSOR_SESSION_ID="$session_id"
            fi
            if [[ -n "$permission_mode" ]]; then
              CURSOR_PERMISSION_MODE="$permission_mode"
            fi
            local violation_msg="MODEL POLICY VIOLATION: requested auto but Cursor started $model"
            log_error "$violation_msg"
            log_activity "$violation_msg"
            echo "$violation_msg" >&2
            emit_signal_once "ABORT" "$violation_msg" "$violation_msg"
            write_session_metrics
            return
          fi
        fi
        CURSOR_MODEL="$model"
        RALPH_MODEL_RUNTIME="$model"
        if [[ -n "$session_id" ]]; then
          CURSOR_SESSION_ID="$session_id"
        fi
        if [[ -n "$permission_mode" ]]; then
          CURSOR_PERMISSION_MODE="$permission_mode"
        fi
        local session_msg="SESSION START: model=$model"
        if [[ -n "$CURSOR_SESSION_ID" ]]; then
          session_msg="$session_msg session=$CURSOR_SESSION_ID"
        fi
        if [[ -n "$CURSOR_PERMISSION_MODE" ]]; then
          session_msg="$session_msg permission=$CURSOR_PERMISSION_MODE"
        fi
        log_activity "$session_msg"
        if [[ $SESSION_START_SENT -eq 0 ]]; then
          local signal_detail=""
          if [[ -n "$CURSOR_SESSION_ID" ]]; then
            signal_detail="session=$CURSOR_SESSION_ID"
          fi
          if [[ -n "$CURSOR_PERMISSION_MODE" ]]; then
            if [[ -n "$signal_detail" ]]; then
              signal_detail="$signal_detail permission=$CURSOR_PERMISSION_MODE"
            else
              signal_detail="permission=$CURSOR_PERMISSION_MODE"
            fi
          fi
          if [[ -n "$requested_model" ]] && [[ "$requested_model" != "unknown" ]] && [[ "$requested_model" != "$model" ]]; then
            if [[ -n "$signal_detail" ]]; then
              signal_detail="$signal_detail requested_model=$requested_model"
            else
              signal_detail="requested_model=$requested_model"
            fi
          fi
          log_signal_event "SESSION_START" "$signal_detail"
          SESSION_START_SENT=1
        fi
        if [[ -n "$model" ]] && [[ "$model" != "unknown" ]] && [[ "$model" != "$requested_model" ]]; then
          echo "Cursor resolved model: $model" >&2
        fi
        write_session_metrics
      fi
      ;;
    
    "error")
      # Handle API/engine errors
      local error_msg
      error_msg=$(echo "$line" | jq -r '.error.data.message // .error.message // .message // "Unknown error"' 2>/dev/null) || error_msg="Unknown error"
      
      log_error "API ERROR: $error_msg"
      log_activity "❌ API ERROR: $error_msg"
      
      # Check if this is a retryable error (rate limit, network, etc.)
      if is_retryable_api_error "$error_msg"; then
        log_error "⚠️ RETRYABLE: Error may be transient (rate limit/network)"
        emit_signal_once "DEFER"
      else
        emit_signal_once "ABORT" "❌ API ERROR: non-retryable failure" "🚨 NON-RETRYABLE: Error requires attention"
      fi
      ;;
      
    "assistant")
      # Track assistant message characters
      local text=$(echo "$line" | jq -r '.message.content[0].text // empty' 2>/dev/null) || text=""
      if [[ -n "$text" ]]; then
        local chars=${#text}
        ASSISTANT_CHARS=$((ASSISTANT_CHARS + chars))
        local assistant_tokens
        assistant_tokens=$(estimate_assistant_tokens "$chars" "$text")
        TOKEN_EST_ASSISTANT=$((TOKEN_EST_ASSISTANT + assistant_tokens))
        
        # Check for completion sigil
        if assistant_has_standalone_sigil "$text" "<ralph>COMPLETE</ralph>"; then
          emit_signal_once "COMPLETE" "✅ Agent signaled COMPLETE"
        fi
        
        # Check for gutter sigil
        if assistant_has_standalone_sigil "$text" "<ralph>GUTTER</ralph>"; then
          emit_signal_once "GUTTER" "🚨 Agent signaled GUTTER (stuck)"
        fi
      fi
      ;;

    "result")
      local session_id=$(echo "$line" | jq -r '.session_id // .sessionId // .chatId // empty' 2>/dev/null) || session_id=""
      local request_id=$(echo "$line" | jq -r '.request_id // .requestId // empty' 2>/dev/null) || request_id=""
      local duration=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null) || duration=0
      if [[ -n "$session_id" ]]; then
        CURSOR_SESSION_ID="$session_id"
      fi
      if [[ -n "$request_id" ]]; then
        CURSOR_REQUEST_ID="$request_id"
      fi
      write_session_metrics
      log_session_result "$duration"
      ;;
      
    "tool_call")
      if [[ "$subtype" == "started" ]] || [[ "$subtype" == "completed" ]]; then
        local tool_call_id_value=""
        tool_call_id_value=$(tool_call_id "$line") || tool_call_id_value=""
        record_tool_interaction "$subtype" "$tool_call_id_value" || true
      fi

      if [[ "$subtype" == "completed" ]]; then
        # Handle read tool completion
        if echo "$line" | jq -e '.tool_call.readToolCall.result.success' > /dev/null 2>&1; then
          local path=$(echo "$line" | jq -r '.tool_call.readToolCall.args.path // "unknown"' 2>/dev/null) || path="unknown"
          local lines=$(echo "$line" | jq -r '.tool_call.readToolCall.result.success.totalLines // 0' 2>/dev/null) || lines=0
          
          local content_size=$(echo "$line" | jq -r '.tool_call.readToolCall.result.success.contentSize // 0' 2>/dev/null) || content_size=0
          local bytes
          if [[ $content_size -gt 0 ]]; then
            bytes=$content_size
          else
            bytes=$((lines * 100))  # ~100 chars/line for code
          fi
          BYTES_READ=$((BYTES_READ + bytes))
          local read_tokens
          read_tokens=$(estimate_read_tokens "$bytes" "$lines")
          TOKEN_EST_READ=$((TOKEN_EST_READ + read_tokens))
          
          local kb=$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo "$((bytes / 1024))")
          log_activity "READ $path ($lines lines, ~${kb}KB, ~${read_tokens} tok)"
          track_file_read "$path" "$bytes" "$lines"
          
        # Handle write tool completion
        elif echo "$line" | jq -e '.tool_call.writeToolCall.result.success' > /dev/null 2>&1; then
          local path=$(echo "$line" | jq -r '.tool_call.writeToolCall.args.path // "unknown"' 2>/dev/null) || path="unknown"
          local lines=$(echo "$line" | jq -r '.tool_call.writeToolCall.result.success.linesCreated // 0' 2>/dev/null) || lines=0
          local bytes=$(echo "$line" | jq -r '.tool_call.writeToolCall.result.success.fileSize // 0' 2>/dev/null) || bytes=0
          BYTES_WRITTEN=$((BYTES_WRITTEN + bytes))
          WRITE_CALLS=$((WRITE_CALLS + 1))
          local write_tokens
          write_tokens=$(estimate_write_tokens "$bytes" "$lines")
          TOKEN_EST_WRITE=$((TOKEN_EST_WRITE + write_tokens))
          if [[ "$path" != "$RALPH_DIR/"* ]] && [[ "$path" != ".ralph/"* ]]; then
            WORK_WRITE_CALLS=$((WORK_WRITE_CALLS + 1))
          fi
          
          local kb=$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo "$((bytes / 1024))")
          log_activity "WRITE $path ($lines lines, ${kb}KB, ~${write_tokens} tok)"
          
          # Track for thrashing detection
          track_file_write "$path"
          update_workspace_snapshot_entry "$path"
          
        # Handle shell tool completion
        elif echo "$line" | jq -e '.tool_call.shellToolCall.result' > /dev/null 2>&1; then
          local cmd=$(echo "$line" | jq -r '.tool_call.shellToolCall.args.command // "unknown"' 2>/dev/null) || cmd="unknown"
          local exit_code=$(echo "$line" | jq -r '.tool_call.shellToolCall.result.exitCode // 0' 2>/dev/null) || exit_code=0
          SHELL_CALLS=$((SHELL_CALLS + 1))
          
          local stdout=$(echo "$line" | jq -r '.tool_call.shellToolCall.result.stdout // ""' 2>/dev/null) || stdout=""
          local stderr=$(echo "$line" | jq -r '.tool_call.shellToolCall.result.stderr // ""' 2>/dev/null) || stderr=""
          local output_chars=$((${#stdout} + ${#stderr}))
          SHELL_OUTPUT_CHARS=$((SHELL_OUTPUT_CHARS + output_chars))
          local output_lines=0
          if [[ -n "$stdout$stderr" ]]; then
            output_lines=$(printf '%s' "$stdout$stderr" | awk 'END { print NR+0 }')
          fi
          local shell_tokens
          shell_tokens=$(estimate_shell_tokens "$output_chars" "$output_lines")
          TOKEN_EST_SHELL=$((TOKEN_EST_SHELL + shell_tokens))
          track_shell_edits "$cmd" "$exit_code"
          local shell_edit_count="$LAST_SHELL_EDIT_COUNT"
          local shell_work_edit_seen="$LAST_SHELL_WORK_EDIT_SEEN"
          local shell_edit_bytes="$LAST_SHELL_EDIT_BYTES"
          local shell_edit_tokens="$LAST_SHELL_EDIT_TOKENS"
          
          if [[ $exit_code -eq 0 ]]; then
            if [[ $output_chars -gt 1024 ]]; then
              log_activity "SHELL $cmd → exit 0 (${output_chars} chars, ~${shell_tokens} tok)"
            else
              log_activity "SHELL $cmd → exit 0 (~${shell_tokens} tok)"
            fi
          else
            log_activity "SHELL $cmd → exit $exit_code (~${shell_tokens} tok)"
            track_shell_failure "$cmd" "$exit_code"
          fi

          if [[ "${shell_edit_count:-0}" -gt 0 ]]; then
            local edit_summary="${shell_edit_count} file"
            if [[ "${shell_edit_count:-0}" -ne 1 ]]; then
              edit_summary="${shell_edit_count} files"
            fi
            if [[ "${shell_work_edit_seen:-0}" -eq 1 ]]; then
              log_activity "SHELL MUTATION $cmd → $edit_summary (${shell_edit_bytes}B, ~${shell_edit_tokens} write tok, includes worktree edits)"
            else
              log_activity "SHELL MUTATION $cmd → $edit_summary (${shell_edit_bytes}B, ~${shell_edit_tokens} write tok)"
            fi
          fi
        fi
        
        # Check thresholds after each tool call
        check_gutter
      fi
      ;;
      
  esac
}

# Main loop: read JSON lines from stdin
main() {
  # Initialize activity log for this session
  echo "" >> "$RALPH_DIR/activity.log"
  echo "═══════════════════════════════════════════════════════════════" >> "$RALPH_DIR/activity.log"
  echo "Ralph Session Started: $(date)" >> "$RALPH_DIR/activity.log"
  echo "═══════════════════════════════════════════════════════════════" >> "$RALPH_DIR/activity.log"

  ensure_workspace_snapshot
  
  # Track last token log time
  local last_token_log=$(date +%s)
  
  while IFS= read -r line; do
    process_line "$line"
    write_session_metrics
    
    # Log token status every 30 seconds
    local now=$(date +%s)
    if [[ $((now - last_token_log)) -ge 30 ]]; then
      log_token_status
      last_token_log=$now
    fi
  done
  
  log_activity "SESSION SUMMARY: reads=$READ_CALLS writes=$WRITE_CALLS work_writes=$WORK_WRITE_CALLS shell=$SHELL_CALLS shell_edits=$SHELL_EDIT_CALLS shell_work_edits=$SHELL_WORK_EDIT_CALLS large_reads=$LARGE_READS large_rereads=$LARGE_READ_REREADS signal=${LAST_SIGNAL:-NONE}"
  write_session_metrics
  # Final token status
  log_token_status
}

main
