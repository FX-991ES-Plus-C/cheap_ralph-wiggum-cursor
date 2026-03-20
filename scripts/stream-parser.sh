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

# Ensure .ralph directory exists
mkdir -p "$RALPH_DIR"

# Thresholds
WARN_THRESHOLD="${WARN_THRESHOLD:-170000}"
ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-200000}"
LARGE_READ_THRESHOLD_BYTES="${LARGE_READ_THRESHOLD_BYTES:-81920}"
VERY_LARGE_READ_THRESHOLD_BYTES="${VERY_LARGE_READ_THRESHOLD_BYTES:-262144}"
MAX_LARGE_REREADS_PER_FILE="${MAX_LARGE_REREADS_PER_FILE:-3}"
MAX_LARGE_READS_WITHOUT_WRITE="${MAX_LARGE_READS_WITHOUT_WRITE:-5}"

# Tracking state
BYTES_READ=0
BYTES_WRITTEN=0
ASSISTANT_CHARS=0
SHELL_OUTPUT_CHARS=0
PROMPT_CHARS=0
TOOL_CALLS=0
WARN_SENT=0
READ_CALLS=0
WRITE_CALLS=0
WORK_WRITE_CALLS=0
SHELL_CALLS=0
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

# Estimate initial prompt size (Ralph prompt is ~2KB + file references)
PROMPT_CHARS=3000

# Gutter detection - use temp files instead of associative arrays (macOS bash 3.x compat)
FAILURES_FILE=$(mktemp)
WRITES_FILE=$(mktemp)
READS_FILE=$(mktemp)
trap "rm -f $FAILURES_FILE $WRITES_FILE $READS_FILE" EXIT

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

track_file_read() {
  local path="$1"
  local bytes="$2"
  local lines="$3"
  local now=$(date +%s)

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

  if [[ $per_file_count -ge 2 ]]; then
    LARGE_READ_REREADS=$((LARGE_READ_REREADS + 1))
  fi

  if [[ $WRITE_CALLS -eq 0 && $bytes -ge $VERY_LARGE_READ_THRESHOLD_BYTES && $per_file_count -ge 2 ]]; then
    LARGE_READ_THRASH_HIT=1
    emit_signal_once \
      "GUTTER" \
      "🚨 THRASH: very large file reread of $path (${per_file_count}x before any write)" \
      "⚠️ THRASH: very large file $path reread ${per_file_count}x before any write"
    return
  fi

  if [[ $WRITE_CALLS -eq 0 && $per_file_count -ge $MAX_LARGE_REREADS_PER_FILE ]]; then
    LARGE_READ_THRASH_HIT=1
    emit_signal_once \
      "GUTTER" \
      "🚨 THRASH: repeated large reread of $path (${per_file_count}x before any write)" \
      "⚠️ THRASH: $path reread ${per_file_count}x in one session before any write"
    return
  fi

  if [[ $WRITE_CALLS -eq 0 && $LARGE_READS -ge $MAX_LARGE_READS_WITHOUT_WRITE ]]; then
    LARGE_READ_THRASH_HIT=1
    emit_signal_once \
      "GUTTER" \
      "🚨 THRASH: ${LARGE_READS} large reads without any write this session" \
      "⚠️ THRASH: ${LARGE_READS} large reads occurred before any write"
  fi
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
    printf 'RALPH_SESSION_LARGE_READS=%q\n' "$LARGE_READS"
    printf 'RALPH_SESSION_LARGE_READ_REREADS=%q\n' "$LARGE_READ_REREADS"
    printf 'RALPH_SESSION_LARGE_READ_THRASH_HIT=%q\n' "$LARGE_READ_THRASH_HIT"
    printf 'RALPH_SESSION_PROMPT_TOKENS=%q\n' "$TOKEN_EST_PROMPT"
    printf 'RALPH_SESSION_READ_TOKENS=%q\n' "$TOKEN_EST_READ"
    printf 'RALPH_SESSION_WRITE_TOKENS=%q\n' "$TOKEN_EST_WRITE"
    printf 'RALPH_SESSION_ASSISTANT_TOKENS=%q\n' "$TOKEN_EST_ASSISTANT"
    printf 'RALPH_SESSION_SHELL_TOKENS=%q\n' "$TOKEN_EST_SHELL"
    printf 'RALPH_SESSION_TOOL_OVERHEAD_TOKENS=%q\n' "$((TOOL_CALLS * 12))"
  } > "$tmp_file"

  mv "$tmp_file" "$summary_file"
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
        local model=$(echo "$line" | jq -r '.model // "unknown"' 2>/dev/null) || model="unknown"
        local session_id=$(echo "$line" | jq -r '.session_id // .sessionId // .chatId // empty' 2>/dev/null) || session_id=""
        local permission_mode=$(echo "$line" | jq -r '.permissionMode // .permission_mode // empty' 2>/dev/null) || permission_mode=""
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
        emit_signal_once "GUTTER" "❌ API ERROR: non-retryable failure" "🚨 NON-RETRYABLE: Error requires attention"
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
        if [[ "$text" == *"<ralph>COMPLETE</ralph>"* ]]; then
          emit_signal_once "COMPLETE" "✅ Agent signaled COMPLETE"
        fi
        
        # Check for gutter sigil
        if [[ "$text" == *"<ralph>GUTTER</ralph>"* ]]; then
          emit_signal_once "GUTTER" "🚨 Agent signaled GUTTER (stuck)"
        fi
      fi
      ;;

    "result")
      local session_id=$(echo "$line" | jq -r '.session_id // .sessionId // .chatId // empty' 2>/dev/null) || session_id=""
      local request_id=$(echo "$line" | jq -r '.request_id // .requestId // empty' 2>/dev/null) || request_id=""
      if [[ -n "$session_id" ]]; then
        CURSOR_SESSION_ID="$session_id"
      fi
      if [[ -n "$request_id" ]]; then
        CURSOR_REQUEST_ID="$request_id"
      fi
      write_session_metrics
      ;;
      
    "tool_call")
      if [[ "$subtype" == "started" ]]; then
        TOOL_CALLS=$((TOOL_CALLS + 1))
        
      elif [[ "$subtype" == "completed" ]]; then
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
        fi
        
        # Check thresholds after each tool call
        check_gutter
      fi
      ;;
      
    "result")
      local duration=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null) || duration=0
      local tokens=$(calc_tokens)
      log_activity "SESSION END: ${duration}ms, ~$tokens tokens used"
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
  
  # Track last token log time
  local last_token_log=$(date +%s)
  
  while IFS= read -r line; do
    process_line "$line"
    
    # Log token status every 30 seconds
    local now=$(date +%s)
    if [[ $((now - last_token_log)) -ge 30 ]]; then
      log_token_status
      last_token_log=$now
    fi
  done
  
  log_activity "SESSION SUMMARY: reads=$READ_CALLS writes=$WRITE_CALLS work_writes=$WORK_WRITE_CALLS shell=$SHELL_CALLS large_reads=$LARGE_READS large_rereads=$LARGE_READ_REREADS signal=${LAST_SIGNAL:-NONE}"
  write_session_metrics
  # Final token status
  log_token_status
}

main
