#!/bin/bash
# Ralph Wiggum: Common utilities and loop logic
#
# Shared functions for ralph-loop.sh and ralph-setup.sh
# All state lives in .ralph/ within the project.

# =============================================================================
# SOURCE DEPENDENCIES
# =============================================================================

# Get the directory where this script lives
_RALPH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the task parser for YAML backend support
if [[ -f "$_RALPH_SCRIPT_DIR/task-parser.sh" ]]; then
  source "$_RALPH_SCRIPT_DIR/task-parser.sh"
  _TASK_PARSER_AVAILABLE=1
else
  _TASK_PARSER_AVAILABLE=0
fi

# =============================================================================
# CONFIGURATION (can be overridden before sourcing)
# =============================================================================

# Token thresholds
WARN_THRESHOLD="${WARN_THRESHOLD:-170000}"
ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-200000}"

# Iteration limits
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"

# Long-run log compaction
AUTO_ROTATE_LOGS="${AUTO_ROTATE_LOGS:-true}"
PROGRESS_ROTATE_MAX_BYTES="${PROGRESS_ROTATE_MAX_BYTES:-32768}"
PROGRESS_ROTATE_MAX_LINES="${PROGRESS_ROTATE_MAX_LINES:-400}"
ACTIVITY_ROTATE_MAX_BYTES="${ACTIVITY_ROTATE_MAX_BYTES:-262144}"
ACTIVITY_ROTATE_MAX_LINES="${ACTIVITY_ROTATE_MAX_LINES:-2500}"

# Anti-thrash / self-management
LARGE_READ_THRESHOLD_BYTES="${LARGE_READ_THRESHOLD_BYTES:-81920}"
VERY_LARGE_READ_THRESHOLD_BYTES="${VERY_LARGE_READ_THRESHOLD_BYTES:-262144}"
MAX_VERY_LARGE_REREADS_PER_FILE="${MAX_VERY_LARGE_REREADS_PER_FILE:-3}"
MAX_LARGE_REREADS_PER_FILE="${MAX_LARGE_REREADS_PER_FILE:-3}"
MAX_LARGE_READS_WITHOUT_WRITE="${MAX_LARGE_READS_WITHOUT_WRITE:-5}"
MAX_THRASH_ROTATIONS="${MAX_THRASH_ROTATIONS:-4}"
MAX_CONSECUTIVE_THRASH_RECOVERIES="${MAX_CONSECUTIVE_THRASH_RECOVERIES:-2}"
THRASH_RECOVERY_DELAY_SECONDS="${THRASH_RECOVERY_DELAY_SECONDS:-3}"
SESSION_BRIEF_MAX_DIRTY_FILES="${SESSION_BRIEF_MAX_DIRTY_FILES:-8}"
SESSION_BRIEF_MAX_ERROR_LINES="${SESSION_BRIEF_MAX_ERROR_LINES:-6}"
SESSION_BRIEF_MAX_LARGE_FILES="${SESSION_BRIEF_MAX_LARGE_FILES:-8}"
SESSION_BRIEF_EXCLUDE_REGEX="${SESSION_BRIEF_EXCLUDE_REGEX:-(^|/)(\\.git|node_modules|vendor|vendors|third_party|third-party|dist|build|coverage|\\.next|target|test-results|\\.ralph/archive)(/|$)|\\.min\\.(js|css|mjs)$}"
READ_TRACE_RECENT_LIMIT="${READ_TRACE_RECENT_LIMIT:-200}"
READ_HOTSPOT_LIMIT="${READ_HOTSPOT_LIMIT:-5}"
NAVIGATION_ANCHOR_LIMIT="${NAVIGATION_ANCHOR_LIMIT:-12}"
NAVIGATION_WINDOW_RADIUS="${NAVIGATION_WINDOW_RADIUS:-40}"
TASK_KEYWORD_LIMIT="${TASK_KEYWORD_LIMIT:-6}"
TASK_SEARCH_HIT_LIMIT="${TASK_SEARCH_HIT_LIMIT:-6}"
TARGETED_READ_WINDOW_GUIDE="${TARGETED_READ_WINDOW_GUIDE:-40-120 lines}"
TASK_SCAFFOLD_WARN_PENDING_MAX="${TASK_SCAFFOLD_WARN_PENDING_MAX:-12}"
TASK_SCAFFOLD_WARN_DESC_LENGTH="${TASK_SCAFFOLD_WARN_DESC_LENGTH:-160}"
TASK_SCAFFOLD_WARN_MANUAL_LIMIT="${TASK_SCAFFOLD_WARN_MANUAL_LIMIT:-3}"

# Sequential run locking
SEQUENTIAL_LOCK_DIR="${SEQUENTIAL_LOCK_DIR:-.ralph/locks/sequential.lock}"
LOCK_STALE_MINUTES="${LOCK_STALE_MINUTES:-45}"
SEQUENTIAL_LOCK_HELD="${SEQUENTIAL_LOCK_HELD:-}"

# Model selection
DEFAULT_MODEL="auto"
MODEL="${RALPH_MODEL:-$DEFAULT_MODEL}"

# Feature flags (set by caller)
USE_BRANCH="${USE_BRANCH:-}"
OPEN_PR="${OPEN_PR:-false}"
SKIP_CONFIRM="${SKIP_CONFIRM:-false}"

# =============================================================================
# SOURCE RETRY UTILITIES
# =============================================================================

# Source retry logic utilities
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
if [[ -f "$SCRIPT_DIR/ralph-retry.sh" ]]; then
  source "$SCRIPT_DIR/ralph-retry.sh"
fi

# =============================================================================
# BASIC HELPERS
# =============================================================================

# Cross-platform sed -i
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Get the .ralph directory for a workspace
get_ralph_dir() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph"
}

# Get current iteration from .ralph/.iteration
get_iteration() {
  local workspace="${1:-.}"
  local state_file="$workspace/.ralph/.iteration"
  
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo "0"
  fi
}

# Set iteration number
set_iteration() {
  local workspace="${1:-.}"
  local iteration="$2"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  echo "$iteration" > "$ralph_dir/.iteration"
}

# Increment iteration and return new value
increment_iteration() {
  local workspace="${1:-.}"
  local current=$(get_iteration "$workspace")
  local next=$((current + 1))
  set_iteration "$workspace" "$next"
  echo "$next"
}

# Get context health emoji based on token count
get_health_emoji() {
  local tokens="$1"
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

# Get current git HEAD if available
get_git_head() {
  git rev-parse HEAD 2>/dev/null || echo ""
}

normalize_model_name() {
  local model="${1:-}"
  printf '%s' "$model" | tr '[:upper:]' '[:lower:]'
}

require_auto_model() {
  local requested_model="${1:-${MODEL:-$DEFAULT_MODEL}}"
  local normalized_model
  normalized_model=$(normalize_model_name "$requested_model")

  if [[ "$normalized_model" != "auto" ]]; then
    echo "❌ Ralph is locked to Cursor CLI auto mode only. Refusing model: $requested_model" >&2
    return 1
  fi

  MODEL="auto"
  return 0
}

# Read parser-produced session metrics into namespaced shell variables
load_last_session_metrics() {
  local workspace="${1:-.}"
  local summary_file="$workspace/.ralph/.last-session.env"

  RALPH_SESSION_ITERATION=0
  RALPH_SESSION_ID=""
  RALPH_SESSION_REQUEST_ID=""
  RALPH_SESSION_PERMISSION_MODE=""
  RALPH_SESSION_MODEL=""
  RALPH_SESSION_SIGNAL="NONE"
  RALPH_SESSION_TOKENS=0
  RALPH_SESSION_BYTES_READ=0
  RALPH_SESSION_BYTES_WRITTEN=0
  RALPH_SESSION_ASSISTANT_CHARS=0
  RALPH_SESSION_SHELL_OUTPUT_CHARS=0
  RALPH_SESSION_TOOL_CALLS=0
  RALPH_SESSION_READ_CALLS=0
  RALPH_SESSION_WRITE_CALLS=0
  RALPH_SESSION_WORK_WRITE_CALLS=0
  RALPH_SESSION_SHELL_CALLS=0
  RALPH_SESSION_SHELL_EDIT_CALLS=0
  RALPH_SESSION_SHELL_WORK_EDIT_CALLS=0
  RALPH_SESSION_WORK_EDIT_CALLS=0
  RALPH_SESSION_LARGE_READS=0
  RALPH_SESSION_LARGE_READ_REREADS=0
  RALPH_SESSION_LARGE_READ_THRASH_HIT=0
  RALPH_SESSION_HOT_FILE=""
  RALPH_SESSION_HOT_FILE_READS=0
  RALPH_SESSION_HOT_FILE_BYTES=0
  RALPH_SESSION_HOT_FILE_LINES=0
  RALPH_SESSION_THRASH_PATH=""
  RALPH_SESSION_PROMPT_TOKENS=0
  RALPH_SESSION_READ_TOKENS=0
  RALPH_SESSION_WRITE_TOKENS=0
  RALPH_SESSION_ASSISTANT_TOKENS=0
  RALPH_SESSION_SHELL_TOKENS=0
  RALPH_SESSION_TOOL_OVERHEAD_TOKENS=0

  if [[ -f "$summary_file" ]]; then
    # shellcheck disable=SC1090
    source "$summary_file"
  fi
}

initialize_session_metrics() {
  local workspace="${1:-.}"
  local iteration="${2:-0}"
  local model="${3:-$MODEL}"
  local summary_file="$workspace/.ralph/.last-session.env"
  local tmp_file

  mkdir -p "$workspace/.ralph"
  tmp_file=$(mktemp)

  {
    printf 'RALPH_SESSION_ITERATION=%q\n' "$iteration"
    printf 'RALPH_SESSION_ID=%q\n' ""
    printf 'RALPH_SESSION_REQUEST_ID=%q\n' ""
    printf 'RALPH_SESSION_PERMISSION_MODE=%q\n' ""
    printf 'RALPH_SESSION_MODEL=%q\n' "$model"
    printf 'RALPH_SESSION_SIGNAL=%q\n' "NONE"
    printf 'RALPH_SESSION_TOKENS=%q\n' "0"
    printf 'RALPH_SESSION_BYTES_READ=%q\n' "0"
    printf 'RALPH_SESSION_BYTES_WRITTEN=%q\n' "0"
    printf 'RALPH_SESSION_ASSISTANT_CHARS=%q\n' "0"
    printf 'RALPH_SESSION_SHELL_OUTPUT_CHARS=%q\n' "0"
    printf 'RALPH_SESSION_TOOL_CALLS=%q\n' "0"
    printf 'RALPH_SESSION_READ_CALLS=%q\n' "0"
    printf 'RALPH_SESSION_WRITE_CALLS=%q\n' "0"
    printf 'RALPH_SESSION_WORK_WRITE_CALLS=%q\n' "0"
    printf 'RALPH_SESSION_SHELL_CALLS=%q\n' "0"
    printf 'RALPH_SESSION_SHELL_EDIT_CALLS=%q\n' "0"
    printf 'RALPH_SESSION_SHELL_WORK_EDIT_CALLS=%q\n' "0"
    printf 'RALPH_SESSION_WORK_EDIT_CALLS=%q\n' "0"
    printf 'RALPH_SESSION_LARGE_READS=%q\n' "0"
    printf 'RALPH_SESSION_LARGE_READ_REREADS=%q\n' "0"
    printf 'RALPH_SESSION_LARGE_READ_THRASH_HIT=%q\n' "0"
    printf 'RALPH_SESSION_HOT_FILE=%q\n' ""
    printf 'RALPH_SESSION_HOT_FILE_READS=%q\n' "0"
    printf 'RALPH_SESSION_HOT_FILE_BYTES=%q\n' "0"
    printf 'RALPH_SESSION_HOT_FILE_LINES=%q\n' "0"
    printf 'RALPH_SESSION_THRASH_PATH=%q\n' ""
    printf 'RALPH_SESSION_PROMPT_TOKENS=%q\n' "0"
    printf 'RALPH_SESSION_READ_TOKENS=%q\n' "0"
    printf 'RALPH_SESSION_WRITE_TOKENS=%q\n' "0"
    printf 'RALPH_SESSION_ASSISTANT_TOKENS=%q\n' "0"
    printf 'RALPH_SESSION_SHELL_TOKENS=%q\n' "0"
    printf 'RALPH_SESSION_TOOL_OVERHEAD_TOKENS=%q\n' "0"
  } > "$tmp_file"

  mv "$tmp_file" "$summary_file"
}

resolve_runtime_model() {
  local workspace="${1:-.}"
  local iteration="${2:-}"
  local fallback="${3:-${MODEL:-unknown}}"

  load_last_session_metrics "$workspace"
  if [[ -n "${RALPH_SESSION_MODEL:-}" ]] && [[ -n "$iteration" ]] && [[ "${RALPH_SESSION_ITERATION:-}" == "$iteration" ]]; then
    printf '%s\n' "$RALPH_SESSION_MODEL"
    return
  fi

  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
  else
    printf '%s\n' "unknown"
  fi
}

format_requested_model_label() {
  local model="${1:-${MODEL:-unknown}}"

  if [[ "$model" == "auto" ]]; then
    printf '%s\n' "auto (Cursor will resolve)"
  elif [[ -n "$model" ]]; then
    printf '%s\n' "$model"
  else
    printf '%s\n' "unknown"
  fi
}

# =============================================================================
# LOGGING
# =============================================================================

# Log a message to activity.log
log_activity() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/activity.log"
}

# Log an error to errors.log
log_error() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/errors.log"
}

# Log to progress.md (called by the loop, not the agent)
log_progress() {
  local workspace="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local progress_file="$workspace/.ralph/progress.md"
  
  echo "" >> "$progress_file"
  echo "### $timestamp" >> "$progress_file"
  echo "$message" >> "$progress_file"
}

# Persist lightweight runtime state for the Ralph dashboard/TUI
write_runtime_state() {
  local workspace="$1"
  local status="${2:-idle}"
  local iteration="${3:-0}"
  local model="${4:-$MODEL}"
  local last_signal="${5:-NONE}"
  local last_event="${6:-Waiting for Ralph}"
  local mode="${7:-sequential}"
  local agent_pid="${8:-}"
  local state_file="$workspace/.ralph/runtime.env"
  local resolved_model
  local tmp_file

  mkdir -p "$workspace/.ralph"
  resolved_model=$(resolve_runtime_model "$workspace" "$iteration" "$model")
  tmp_file=$(mktemp)

  {
    echo "# Ralph runtime state"
    printf 'RALPH_RUNTIME_STATUS=%q\n' "$status"
    printf 'RALPH_RUNTIME_ITERATION=%q\n' "$iteration"
    printf 'RALPH_RUNTIME_MODEL=%q\n' "$resolved_model"
    printf 'RALPH_RUNTIME_LAST_SIGNAL=%q\n' "$last_signal"
    printf 'RALPH_RUNTIME_LAST_EVENT=%q\n' "$last_event"
    printf 'RALPH_RUNTIME_MODE=%q\n' "$mode"
    printf 'RALPH_RUNTIME_AGENT_PID=%q\n' "$agent_pid"
    printf 'RALPH_RUNTIME_UPDATED_AT=%q\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  } > "$tmp_file"

  mv "$tmp_file" "$state_file"
}

stop_workspace_runtime() {
  local workspace="${1:-.}"
  local reason="${2:-Stopped Ralph workspace}"
  local source="${3:-dashboard}"
  local runtime_file="$workspace/.ralph/runtime.env"
  local lock_dir="$workspace/$SEQUENTIAL_LOCK_DIR"
  local fifo="$workspace/.ralph/.parser_fifo"
  local runtime_status="idle"
  local runtime_iteration="0"
  local runtime_model="${MODEL:-unknown}"
  local runtime_mode="sequential"
  local runtime_agent_pid=""
  local lock_pid=""
  local acted=1
  local seen_pids=""
  local pid=""

  if [[ -f "$runtime_file" ]]; then
    # shellcheck disable=SC1090
    source "$runtime_file"
    runtime_status="${RALPH_RUNTIME_STATUS:-idle}"
    runtime_iteration="${RALPH_RUNTIME_ITERATION:-0}"
    runtime_model="${RALPH_RUNTIME_MODEL:-${MODEL:-unknown}}"
    runtime_mode="${RALPH_RUNTIME_MODE:-sequential}"
    runtime_agent_pid="${RALPH_RUNTIME_AGENT_PID:-}"
  fi

  if [[ -f "$lock_dir/pid" ]]; then
    lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  fi

  for pid in "$runtime_agent_pid" "$lock_pid"; do
    [[ -n "$pid" ]] || continue
    case " $seen_pids " in
      *" $pid "*) continue ;;
    esac
    seen_pids="$seen_pids $pid"
    if kill -0 "$pid" 2>/dev/null; then
      stop_process_tree "$pid"
      acted=0
    fi
  done

  if [[ -p "$fifo" ]] || [[ -e "$fifo" ]]; then
    rm -f "$fifo" 2>/dev/null || true
    acted=0
  fi

  if [[ -d "$lock_dir" ]]; then
    rm -rf "$lock_dir" 2>/dev/null || true
    acted=0
  fi

  case "$runtime_status" in
    running|starting|rotating|gutter|deferred|loop|looping)
      acted=0
      ;;
  esac

  if [[ $acted -eq 0 ]]; then
    append_signal_event "$workspace" "STOPPED" "$reason" "$source" "$runtime_iteration"
    write_runtime_state "$workspace" "stopped" "$runtime_iteration" "$runtime_model" "STOPPED" "$reason" "$runtime_mode" ""
    return 0
  fi

  return 1
}

# Append a durable signal/event record for the dashboard
append_signal_event() {
  local workspace="$1"
  local signal="$2"
  local detail="${3:-}"
  local source="${4:-loop}"
  local iteration="${5:-}"
  local signals_file="$workspace/.ralph/signals.log"
  local timestamp

  mkdir -p "$workspace/.ralph"
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  if [[ -n "$detail" ]]; then
    printf '[%s] source=%s iteration=%s signal=%s | %s\n' \
      "$timestamp" "$source" "${iteration:-?}" "$signal" "$detail" >> "$signals_file"
  else
    printf '[%s] source=%s iteration=%s signal=%s\n' \
      "$timestamp" "$source" "${iteration:-?}" "$signal" >> "$signals_file"
  fi
}

# =============================================================================
# LOG COMPACTION
# =============================================================================

# Get file size in bytes (cross-platform)
get_file_size_bytes() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "0"
    return
  fi

  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f '%z' "$file" 2>/dev/null || wc -c < "$file"
  else
    stat -c '%s' "$file" 2>/dev/null || wc -c < "$file"
  fi
}

# Get file line count
get_file_line_count() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "0"
    return
  fi

  wc -l < "$file" | tr -d '[:space:]'
}

normalize_workspace_path() {
  local workspace="$1"
  local path="$2"

  [[ -n "$path" ]] || return 0

  if [[ "$path" == "$workspace" ]]; then
    printf '.\n'
    return
  fi

  if [[ "$path" == "$workspace/"* ]]; then
    path="${path#$workspace/}"
  fi

  path="${path#./}"
  printf '%s\n' "$path"
}

workspace_path_to_file() {
  local workspace="$1"
  local path="$2"

  if [[ -z "$path" ]]; then
    printf '%s\n' ""
  elif [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  elif [[ "$path" == "." ]]; then
    printf '%s\n' "$workspace"
  else
    printf '%s/%s\n' "$workspace" "$path"
  fi
}

summarize_recent_read_hotspots() {
  local workspace="$1"
  local limit="${2:-$READ_HOTSPOT_LIMIT}"
  local trace_file="$workspace/.ralph/read-trace.tsv"

  [[ -f "$trace_file" ]] || return 0

  tail -n "$((READ_TRACE_RECENT_LIMIT + 1))" "$trace_file" 2>/dev/null | awk -F '\t' '
    NR == 1 && $1 == "timestamp" { next }
    NF >= 7 {
      path = $3
      count[path]++
      last_iter[path] = $2
      if (($4 + 0) > (max_bytes[path] + 0)) {
        max_bytes[path] = $4 + 0
      }
      if (($5 + 0) > (max_lines[path] + 0)) {
        max_lines[path] = $5 + 0
      }
    }
    END {
      for (path in count) {
        printf "%d\t%s\t%d\t%d\t%s\n", count[path], last_iter[path], max_bytes[path], max_lines[path], path
      }
    }
  ' | sort -nr -k1,1 | sed -n "1,${limit}p"
}

resolve_navigation_target() {
  local workspace="$1"
  local path="${RALPH_SESSION_THRASH_PATH:-}"

  if [[ -z "$path" ]]; then
    path="${RALPH_SESSION_HOT_FILE:-}"
  fi

  if [[ -z "$path" ]]; then
    path=$(summarize_recent_read_hotspots "$workspace" 1 | awk -F '\t' 'NR == 1 { print $5 }')
  fi

  normalize_workspace_path "$workspace" "$path"
}

session_work_edit_calls_total() {
  echo $(( ${RALPH_SESSION_WORK_WRITE_CALLS:-0} + ${RALPH_SESSION_SHELL_WORK_EDIT_CALLS:-0} ))
}

should_force_narrow_mode() {
  local workspace="$1"
  local work_edit_calls

  work_edit_calls=$(session_work_edit_calls_total)

  if [[ "${RALPH_SESSION_LARGE_READ_THRASH_HIT:-0}" -eq 1 ]]; then
    return 0
  fi

  if [[ "${RALPH_SESSION_SIGNAL:-NONE}" == "THRASH" ]]; then
    return 0
  fi

  if [[ "${RALPH_SESSION_LARGE_READ_REREADS:-0}" -ge 2 ]] && [[ "$work_edit_calls" -eq 0 ]]; then
    return 0
  fi

  if tail -n 8 "$workspace/.ralph/errors.log" 2>/dev/null | grep -Eq 'THRASH ROTATION|THRASH STOP'; then
    return 0
  fi

  return 1
}

list_navigation_anchors() {
  local file="$1"
  local limit="${2:-$NAVIGATION_ANCHOR_LIMIT}"
  local pattern='^[[:space:]]*((export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[A-Za-z0-9_$]+|(class|interface|enum|type)[[:space:]]+[A-Za-z0-9_$]+|(const|let|var)[[:space:]]+[A-Za-z0-9_$]+[[:space:]]*=|((pub[[:space:]]+)?fn|def|func)[[:space:]]+[A-Za-z0-9_]+|(describe|it|test)[[:space:]]*\(|#{1,6}[[:space:]])'

  [[ -f "$file" ]] || return 0

  if command -v rg >/dev/null 2>&1; then
    rg -n -m "$limit" -e "$pattern" "$file" 2>/dev/null || true
  else
    grep -nE "$pattern" "$file" 2>/dev/null | sed -n "1,${limit}p"
  fi
}

extract_task_search_keywords() {
  local text="$1"
  local limit="${2:-$TASK_KEYWORD_LIMIT}"

  [[ -n "$text" ]] || return 0

  printf '%s\n' "$text" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^[:alnum:]_[:space:]\/.-]+/ /g; s#[/_.-]# #g' \
    | awk -v limit="$limit" '
      BEGIN {
        split("a an and are around before behind being but by can closer complete completed concrete criteria criterion current do exact file files first focus for from have if immediate immediately in into is it its just keep last make move next of on only or recent relevant same should start stay task tasks test tests that the their then there these they this through to until up use when with without work writes writing after any all already also another as at because been both code describe expand follow give guide more most not once one open pick read reading reads record retry session slice stuck target targets them unknown update using while whole you your", raw_stop, " ")
        for (i in raw_stop) {
          stop[raw_stop[i]] = 1
        }
        allow["api"] = 1
        allow["cpu"] = 1
        allow["fps"] = 1
        allow["gpu"] = 1
        allow["lod"] = 1
        allow["nav"] = 1
        allow["ui"] = 1
        allow["vfx"] = 1
      }
      {
        for (i = 1; i <= NF; i++) {
          word = $i
          gsub(/^_+|_+$/, "", word)
          if (word == "") {
            continue
          }
          if (!(word in allow) && length(word) < 4) {
            continue
          }
          if (word in stop) {
            continue
          }
          if (!seen[word]++) {
            print word
            count++
            if (count >= limit) {
              exit
            }
          }
        }
      }
    '
}

build_task_search_pattern() {
  local keywords="$1"
  local pattern=""
  local keyword

  while IFS= read -r keyword; do
    [[ -n "$keyword" ]] || continue
    if [[ -n "$pattern" ]]; then
      pattern="${pattern}|${keyword}"
    else
      pattern="$keyword"
    fi
  done <<< "$keywords"

  printf '%s\n' "$pattern"
}

search_keyword_hits() {
  local workspace="$1"
  local search_root="$2"
  local pattern="$3"
  local limit="${4:-$TASK_SEARCH_HIT_LIMIT}"

  [[ -n "$pattern" ]] || return 0
  [[ -e "$search_root" ]] || return 0

  if command -v rg >/dev/null 2>&1; then
    rg -n -i \
      --glob '!.git/**' \
      --glob '!.ralph/**' \
      --glob '!node_modules/**' \
      --glob '!vendor/**' \
      --glob '!vendors/**' \
      --glob '!third_party/**' \
      --glob '!third-party/**' \
      --glob '!dist/**' \
      --glob '!build/**' \
      --glob '!coverage/**' \
      --glob '!.next/**' \
      --glob '!target/**' \
      --glob '!test-results/**' \
      --glob '!*.min.js' \
      --glob '!*.min.css' \
      --glob '!*.min.mjs' \
      -e "$pattern" "$search_root" 2>/dev/null
  else
    grep -RniE \
      --exclude-dir=.git \
      --exclude-dir=.ralph \
      --exclude-dir=node_modules \
      --exclude-dir=vendor \
      --exclude-dir=vendors \
      --exclude-dir=third_party \
      --exclude-dir=third-party \
      --exclude-dir=dist \
      --exclude-dir=build \
      --exclude-dir=coverage \
      --exclude-dir=.next \
      --exclude-dir=target \
      --exclude-dir=test-results \
      --exclude='*.min.js' \
      --exclude='*.min.css' \
      --exclude='*.min.mjs' \
      "$pattern" "$search_root" 2>/dev/null
  fi | awk -F ':' -v ws="$workspace/" '
    {
      file = $1
      line = $2
      if (!(line ~ /^[0-9]+$/)) {
        next
      }
      snippet = $0
      sub(/^[^:]+:[0-9]+:/, "", snippet)
      gsub(/[[:space:]]+/, " ", snippet)
      sub(/^ +/, "", snippet)
      sub(/ +$/, "", snippet)
      if (ws != "" && index(file, ws) == 1) {
        file = substr(file, length(ws) + 1)
      }
      key = file ":" line
      if (!seen[key]++) {
        printf "%s\t%s\t%s\n", file, line, substr(snippet, 1, 120)
      }
    }
  ' | sed -n "1,${limit}p"
}

clamp_navigation_window() {
  local total_lines="$1"
  local center_line="$2"
  local radius="${3:-$NAVIGATION_WINDOW_RADIUS}"
  local start_line end_line

  [[ "$total_lines" =~ ^[0-9]+$ ]] || total_lines=0
  [[ "$center_line" =~ ^[0-9]+$ ]] || center_line=1
  [[ "$radius" =~ ^[0-9]+$ ]] || radius=40

  if [[ "$total_lines" -le 0 ]]; then
    printf '1:1\n'
    return
  fi

  start_line=$((center_line - radius))
  end_line=$((center_line + radius))

  if [[ "$start_line" -lt 1 ]]; then
    start_line=1
  fi
  if [[ "$end_line" -gt "$total_lines" ]]; then
    end_line="$total_lines"
  fi
  if [[ "$end_line" -lt "$start_line" ]]; then
    end_line="$start_line"
  fi

  printf '%s:%s\n' "$start_line" "$end_line"
}

recent_file_read_trace() {
  local workspace="$1"
  local relative_path="$2"
  local limit="${3:-6}"
  local trace_file="$workspace/.ralph/read-trace.tsv"
  local absolute_path

  [[ -f "$trace_file" ]] || return 0

  absolute_path=$(workspace_path_to_file "$workspace" "$relative_path")

  awk -F '\t' -v rel="$relative_path" -v abs="$absolute_path" '
    NR == 1 { next }
    $3 == rel || $3 == abs {
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", $2, $4, $5, $6, $7, $8
    }
  ' "$trace_file" | tail -n "$limit"
}

# Return success when a log file should be compacted
should_rotate_log_file() {
  local file="$1"
  local max_bytes="$2"
  local max_lines="$3"

  [[ ! -f "$file" ]] && return 1

  local bytes lines
  bytes=$(get_file_size_bytes "$file")
  lines=$(get_file_line_count "$file")

  [[ "$bytes" -ge "$max_bytes" || "$lines" -ge "$max_lines" ]]
}

# Ensure the archive directory exists
ensure_ralph_archive_dir() {
  local workspace="$1"
  local archive_dir="$workspace/.ralph/archive"
  mkdir -p "$archive_dir"
  echo "$archive_dir"
}

# Timestamp used for archive file names
make_rotation_stamp() {
  date '+%Y%m%d-%H%M%S'
}

# Extract checkbox descriptions from RALPH_TASK.md by status
list_task_descriptions() {
  local workspace="$1"
  local status="$2"
  local task_file="$workspace/RALPH_TASK.md"
  local pattern=""

  [[ ! -f "$task_file" ]] && return

  case "$status" in
    completed)
      pattern='^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[[xX]\][[:space:]]+'
      ;;
    pending)
      pattern='^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \][[:space:]]+'
      ;;
    *)
      return
      ;;
  esac

  { grep -E "$pattern" "$task_file" 2>/dev/null || true; } \
    | sed -E 's/^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[[xX ]\][[:space:]]+//' \
    | sed -E 's/[[:space:]]*<!--[[:space:]]*group:[[:space:]]*[0-9]+[[:space:]]*-->[[:space:]]*$//'
}

# Return a bounded sample without tripping pipefail via head(1)
sample_task_descriptions() {
  local workspace="$1"
  local status="$2"
  local limit="${3:-5}"

  [[ "$limit" =~ ^[0-9]+$ ]] || limit=5
  list_task_descriptions "$workspace" "$status" 2>/dev/null | sed -n "1,${limit}p"
}

# Write a compact task snapshot to a file
write_task_snapshot_section() {
  local output_file="$1"
  local workspace="$2"
  local heading="${3:-## Task Snapshot}"
  local counts done_count total_count remaining_count
  local completed_sample pending_sample

  counts=$(count_criteria "$workspace")
  done_count="${counts%%:*}"
  total_count="${counts##*:}"

  [[ "$done_count" =~ ^[0-9]+$ ]] || done_count=0
  [[ "$total_count" =~ ^[0-9]+$ ]] || total_count=0
  remaining_count=$((total_count - done_count))
  if [[ "$remaining_count" -lt 0 ]]; then
    remaining_count=0
  fi

  completed_sample=$(list_task_descriptions "$workspace" completed 2>/dev/null | tail -n 6)
  pending_sample=$(sample_task_descriptions "$workspace" pending 6)

  {
    echo "$heading"
    echo ""
    echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- Criteria: $done_count / $total_count complete ($remaining_count remaining)"
  } >> "$output_file"

  if [[ -n "$completed_sample" ]]; then
    {
      echo ""
      echo "### Already Completed (sample)"
      while IFS= read -r item; do
        [[ -n "$item" ]] && echo "- $item"
      done <<< "$completed_sample"
    } >> "$output_file"
  fi

  if [[ -n "$pending_sample" ]]; then
    {
      echo ""
      echo "### Next Unchecked Criteria"
      while IFS= read -r item; do
        [[ -n "$item" ]] && echo "- $item"
      done <<< "$pending_sample"
    } >> "$output_file"
  fi
}

# Return success if a file is likely text and worth surfacing in the brief
is_probably_text_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  LC_ALL=C grep -Iq . "$file" 2>/dev/null
}

should_exclude_brief_candidate() {
  local relative_path="$1"
  [[ "$relative_path" =~ $SESSION_BRIEF_EXCLUDE_REGEX ]]
}

# Enumerate repo files in a repo-agnostic way, preferring git when available
list_repo_candidate_files() {
  local workspace="$1"

  if git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    (
      cd "$workspace" || exit 1
      git ls-files
      git ls-files --others --exclude-standard
    ) | awk '!seen[$0]++'
    return
  fi

  if command -v rg >/dev/null 2>&1; then
    (
      cd "$workspace" || exit 1
      rg --files -g '!node_modules' -g '!.git' -g '!dist' -g '!build' -g '!coverage' \
        -g '!.next' -g '!target' -g '!vendor' -g '!test-results' -g '!.ralph/archive'
    ) | awk '!seen[$0]++'
    return
  fi

  find "$workspace" \
    \( -path "$workspace/.git" -o -path "$workspace/node_modules" -o -path "$workspace/dist" \
       -o -path "$workspace/build" -o -path "$workspace/coverage" -o -path "$workspace/.next" \
       -o -path "$workspace/target" -o -path "$workspace/vendor" -o -path "$workspace/test-results" \
       -o -path "$workspace/.ralph/archive" \) -prune \
    -o -type f -print 2>/dev/null | awk '!seen[$0]++'
}

# List the largest text/context files that should be sliced before full reads
list_large_context_files() {
  local workspace="$1"
  local threshold="${2:-$LARGE_READ_THRESHOLD_BYTES}"
  local max_files="${3:-$SESSION_BRIEF_MAX_LARGE_FILES}"

  {
    [[ -f "$workspace/RALPH_TASK.md" ]] && printf '%s\n' "RALPH_TASK.md"
    [[ -f "$workspace/.ralph/session-brief.md" ]] && printf '%s\n' ".ralph/session-brief.md"
    [[ -f "$workspace/.ralph/guardrails.md" ]] && printf '%s\n' ".ralph/guardrails.md"
    list_repo_candidate_files "$workspace"
  } | awk '!seen[$0]++' | while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue

    local file="$entry"
    if [[ "$entry" != "$workspace/"* ]] && [[ "$entry" != /* ]]; then
      file="$workspace/$entry"
    fi

    [[ -f "$file" ]] || continue
    local relative="${file#$workspace/}"
    [[ "$relative" != "$file" ]] || relative="$file"
    should_exclude_brief_candidate "$relative" && continue
    is_probably_text_file "$file" || continue

    local size lines
    size=$(get_file_size_bytes "$file")
    [[ "$size" -ge "$threshold" ]] || continue
    lines=$(get_file_line_count "$file")
    printf '%s\t%s\t%s\n' "$size" "$lines" "$relative"
  done | sort -nr -k1,1 | head -n "$max_files"
}

write_navigation_brief() {
  local workspace="$1"
  local brief_file="$workspace/.ralph/navigation-brief.md"
  local tmp_file hotspot_summary target_path target_file quoted_target
  local recent_target_reads anchors
  local next_task next_id next_status next_desc=""
  local task_keywords task_pattern repo_keyword_hits target_keyword_hits
  local forced_narrow=0
  local target_exists=0
  local target_lines=0
  local target_bytes=0

  hotspot_summary=$(summarize_recent_read_hotspots "$workspace" "$READ_HOTSPOT_LIMIT")
  target_path=$(resolve_navigation_target "$workspace")
  next_task=$(get_next_task_info "$workspace")
  if [[ -n "$next_task" ]]; then
    IFS='|' read -r next_id next_status next_desc <<< "$next_task"
  fi
  task_keywords=$(extract_task_search_keywords "$next_desc" "$TASK_KEYWORD_LIMIT")
  task_pattern=$(build_task_search_pattern "$task_keywords")

  if should_force_narrow_mode "$workspace"; then
    forced_narrow=1
  fi

  if [[ -n "$target_path" ]]; then
    target_file=$(workspace_path_to_file "$workspace" "$target_path")
    quoted_target=$(printf '%q' "$target_path")
  else
    target_file=""
    quoted_target=""
  fi

  if [[ -n "$target_file" ]] && [[ -f "$target_file" ]]; then
    target_exists=1
    target_lines=$(get_file_line_count "$target_file")
    target_bytes=$(get_file_size_bytes "$target_file")
    anchors=$(list_navigation_anchors "$target_file" "$NAVIGATION_ANCHOR_LIMIT")
    recent_target_reads=$(recent_file_read_trace "$workspace" "$target_path" 6)
    if [[ -n "$task_pattern" ]]; then
      target_keyword_hits=$(search_keyword_hits "$workspace" "$target_file" "$task_pattern" 4)
    else
      target_keyword_hits=""
    fi
  else
    anchors=""
    recent_target_reads=""
    target_keyword_hits=""
  fi

  if [[ -n "$task_pattern" ]]; then
    repo_keyword_hits=$(search_keyword_hits "$workspace" "$workspace" "$task_pattern" "$TASK_SEARCH_HIT_LIMIT")
  else
    repo_keyword_hits=""
  fi

  tmp_file=$(mktemp)

  {
    echo "# Ralph Navigation Brief"
    echo ""
    echo "> Auto-generated before each iteration when Ralph needs a tighter map through a large file."
    echo ""
    echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- Last session signal: ${RALPH_SESSION_SIGNAL:-NONE}"
    if [[ "$forced_narrow" -eq 1 ]]; then
      echo "- Forced narrow mode: ACTIVE"
    else
      echo "- Forced narrow mode: standby"
    fi
    if [[ -n "$target_path" ]]; then
      echo "- Current hot file: $target_path"
    else
      echo "- Current hot file: not yet identified"
    fi
    echo ""
    echo "## Operating Mode"
    echo ""
    if [[ "$forced_narrow" -eq 1 ]]; then
      echo "- Large-file reread thrash was detected recently. Stay narrow and deliberate."
      if [[ -n "$target_path" ]]; then
        echo "- Do not full-read \`$target_path\` unless you are editing it immediately."
      else
        echo "- Do not full-read any hotspot file until you have narrowed to a symbol or line window."
      fi
      echo "- Shortlist candidate files with \`rg --files | rg -i 'keyword'\` or \`find . -path '*keyword*'\` before opening unfamiliar code."
      echo "- Search inside shortlisted files with \`rg -n\`, then read a bounded window (${TARGETED_READ_WINDOW_GUIDE}) with \`sed -n 'start,endp'\`."
      echo "- Start with one command from the recommended list below."
      echo "- After one or two narrow reads, either make a concrete edit/test change or record the next exact slice in \`.ralph/progress.md\`."
    else
      echo "- Use this brief before reopening any hotspot file."
      echo "- Favor symbol search and line windows over full-file rereads."
    fi
    echo ""
  } > "$tmp_file"

  if [[ -n "$hotspot_summary" ]]; then
    {
      echo "## Recent Large-Read Hotspots"
      echo ""
      while IFS=$'\t' read -r count last_iter max_bytes max_lines path; do
        local display_path marker kb
        [[ -n "$path" ]] || continue
        display_path=$(normalize_workspace_path "$workspace" "$path")
        kb=$((max_bytes / 1024))
        marker=""
        if [[ -n "$target_path" ]] && [[ "$display_path" == "$target_path" ]]; then
          marker=" <- current hot file"
        fi
        echo "- $display_path (${count} large reads in recent trace, last iteration ${last_iter}, ~${kb}KB, ${max_lines} lines)$marker"
      done <<< "$hotspot_summary"
      echo ""
    } >> "$tmp_file"
  fi

  if [[ -n "$task_pattern" ]]; then
    {
      echo "## Search-First Workflow"
      echo ""
      if [[ -n "$next_desc" ]]; then
        echo "- Next criterion: $next_desc"
      fi
      echo "- Search pattern: \`$task_pattern\`"
      echo "- Shortlist candidates: \`rg --files . | rg -i '$task_pattern'\`"
      echo "- Search inside candidates: \`rg -n -i '$task_pattern' .\`"
      echo "- After a hit, read one bounded window (${TARGETED_READ_WINDOW_GUIDE}) with \`sed -n 'start,endp' path\`."
      echo ""
    } >> "$tmp_file"
  fi

  if [[ -n "$target_path" ]]; then
    {
      echo "## Target Snapshot"
      echo ""
      echo "- File: $target_path"
      if [[ "$target_exists" -eq 1 ]]; then
        echo "- Size: ~$((target_bytes / 1024))KB, ${target_lines} lines"
        if [[ "${RALPH_SESSION_HOT_FILE_READS:-0}" -gt 0 ]]; then
          echo "- Last session large-read count for this file: ${RALPH_SESSION_HOT_FILE_READS}"
        fi
      else
        echo "- Status: file not present in the current working tree. Use the hotspot list and task brief to pick a different narrow read."
      fi
      echo ""
    } >> "$tmp_file"
  fi

  if [[ -n "$repo_keyword_hits" ]]; then
    {
      echo "## Task Keyword Hits"
      echo ""
      while IFS=$'\t' read -r hit_path hit_line hit_snippet; do
        local hit_file hit_lines hit_window start_line end_line quoted_hit_path
        [[ -n "$hit_path" ]] || continue
        hit_file=$(workspace_path_to_file "$workspace" "$hit_path")
        [[ -f "$hit_file" ]] || continue
        hit_lines=$(get_file_line_count "$hit_file")
        hit_window=$(clamp_navigation_window "$hit_lines" "$hit_line" "$NAVIGATION_WINDOW_RADIUS")
        start_line="${hit_window%%:*}"
        end_line="${hit_window##*:}"
        quoted_hit_path=$(printf '%q' "$hit_path")
        echo "- $hit_path:$hit_line -> $hit_snippet | bounded read: \`sed -n '${start_line},${end_line}p' $quoted_hit_path\`"
      done <<< "$repo_keyword_hits"
      echo ""
    } >> "$tmp_file"
  fi

  if [[ -n "$anchors" ]]; then
    {
      local anchor_count=0
      echo "## Candidate Anchors"
      echo ""
      while IFS= read -r anchor; do
        local line snippet
        [[ -n "$anchor" ]] || continue
        line="${anchor%%:*}"
        snippet=$(printf '%s' "$anchor" | sed -E 's/^[0-9]+:[[:space:]]*//; s/[[:space:]]+/ /g' | cut -c1-96)
        echo "- line $line: $snippet"
        anchor_count=$((anchor_count + 1))
        if [[ "$anchor_count" -ge 8 ]]; then
          break
        fi
      done <<< "$anchors"
      echo ""
    } >> "$tmp_file"
  fi

  {
    echo "## Recommended Commands"
    echo ""
    if [[ -n "$task_pattern" ]]; then
      echo "- \`rg --files . | rg -i '$task_pattern'\`"
      if [[ -n "$target_path" ]]; then
        echo "- \`rg -n -i '$task_pattern' $quoted_target\`"
      else
        echo "- \`rg -n -i '$task_pattern' .\`"
      fi
    fi
    if [[ -n "$target_path" ]]; then
      echo "- \`wc -l $quoted_target\`"
      echo "- \`rg -n 'function|class|interface|type|def|fn|describe\\(|test\\(' $quoted_target\`"
    else
      echo "- Start from \`.ralph/session-brief.md\` and keep discovery narrow."
    fi
  } >> "$tmp_file"

  if [[ "$target_exists" -eq 1 ]]; then
    local shown_windows=0
    local used_windows=""

    if [[ -n "$target_keyword_hits" ]]; then
      while IFS=$'\t' read -r hit_path hit_line hit_snippet; do
        local window start_line end_line
        [[ "$hit_line" =~ ^[0-9]+$ ]] || continue
        window=$(clamp_navigation_window "$target_lines" "$hit_line" "$NAVIGATION_WINDOW_RADIUS")
        case " $used_windows " in
          *" $window "*) continue ;;
        esac
        used_windows="$used_windows $window"
        start_line="${window%%:*}"
        end_line="${window##*:}"
        echo "- lines ${start_line}-${end_line}: \`sed -n '${start_line},${end_line}p' $quoted_target\` # keyword hit near line ${hit_line}" >> "$tmp_file"
        shown_windows=$((shown_windows + 1))
        if [[ "$shown_windows" -ge 3 ]]; then
          break
        fi
      done <<< "$target_keyword_hits"
    fi

    if [[ -n "$anchors" ]]; then
      while IFS= read -r anchor; do
        local line window start_line end_line
        [[ -n "$anchor" ]] || continue
        line="${anchor%%:*}"
        [[ "$line" =~ ^[0-9]+$ ]] || continue
        window=$(clamp_navigation_window "$target_lines" "$line" "$NAVIGATION_WINDOW_RADIUS")
        case " $used_windows " in
          *" $window "*) continue ;;
        esac
        used_windows="$used_windows $window"
        start_line="${window%%:*}"
        end_line="${window##*:}"
        echo "- lines ${start_line}-${end_line}: \`sed -n '${start_line},${end_line}p' $quoted_target\`" >> "$tmp_file"
        shown_windows=$((shown_windows + 1))
        if [[ "$shown_windows" -ge 3 ]]; then
          break
        fi
      done <<< "$anchors"
    fi

    if [[ "$shown_windows" -lt 3 ]]; then
      local center window start_line end_line
      for center in 1 $(((target_lines + 1) / 2)) "$target_lines"; do
        window=$(clamp_navigation_window "$target_lines" "$center" "$NAVIGATION_WINDOW_RADIUS")
        case " $used_windows " in
          *" $window "*) continue ;;
        esac
        used_windows="$used_windows $window"
        start_line="${window%%:*}"
        end_line="${window##*:}"
        echo "- lines ${start_line}-${end_line}: \`sed -n '${start_line},${end_line}p' $quoted_target\`" >> "$tmp_file"
        shown_windows=$((shown_windows + 1))
        if [[ "$shown_windows" -ge 3 ]]; then
          break
        fi
      done
    fi

    echo "" >> "$tmp_file"
  fi

  if [[ -n "$recent_target_reads" ]]; then
    {
      echo "## Recent Large Reads For Target"
      echo ""
      while IFS=$'\t' read -r iteration bytes lines per_file_reads write_calls thrash_hit; do
        local kb read_note thrash_note
        kb=$((bytes / 1024))
        if [[ "$write_calls" -eq 0 ]]; then
          read_note="before any write"
        else
          read_note="after ${write_calls} write(s)"
        fi
        if [[ "$thrash_hit" -eq 1 ]]; then
          thrash_note=", triggered thrash"
        else
          thrash_note=""
        fi
        echo "- Iteration ${iteration}: ~${kb}KB, ${lines} lines, file read #${per_file_reads} ${read_note}${thrash_note}"
      done <<< "$recent_target_reads"
      echo ""
    } >> "$tmp_file"
  fi

  mv "$tmp_file" "$brief_file"
}

append_task_slice_section() {
  local output_file="$1"
  local workspace="$2"
  local line_number="$3"
  local task_file="$workspace/RALPH_TASK.md"
  local start_line end_line

  [[ -f "$task_file" ]] || return
  [[ "$line_number" =~ ^[0-9]+$ ]] || return

  start_line=$((line_number - 3))
  end_line=$((line_number + 6))
  if [[ "$start_line" -lt 1 ]]; then
    start_line=1
  fi

  {
    echo "## Task Slice"
    echo ""
    echo '```md'
    sed -n "${start_line},${end_line}p" "$task_file"
    echo '```'
    echo ""
  } >> "$output_file"
}

# Generate a concise, structured restart brief for weaker/cheaper models
write_session_brief() {
  local workspace="$1"
  local brief_file="$workspace/.ralph/session-brief.md"
  local counts done_count total_count remaining_count
  local next_task next_id next_status next_desc next_line=""
  local pending_sample completed_sample dirty_files recent_errors large_files carried_notes
  local hotspot_summary navigation_target forced_narrow=0 scaffolding_warnings

  counts=$(count_criteria "$workspace")
  done_count="${counts%%:*}"
  total_count="${counts##*:}"

  [[ "$done_count" =~ ^[0-9]+$ ]] || done_count=0
  [[ "$total_count" =~ ^[0-9]+$ ]] || total_count=0
  remaining_count=$((total_count - done_count))
  if [[ "$remaining_count" -lt 0 ]]; then
    remaining_count=0
  fi

  next_task=$(get_next_task_info "$workspace")
  if [[ -n "$next_task" ]]; then
    IFS='|' read -r next_id next_status next_desc <<< "$next_task"
    if [[ "$next_id" =~ ^line_([0-9]+)$ ]]; then
      next_line="${BASH_REMATCH[1]}"
    fi
  fi

  pending_sample=$(sample_task_descriptions "$workspace" pending 5)
  completed_sample=$(list_task_descriptions "$workspace" completed 2>/dev/null | tail -n 4)
  dirty_files=$(git -C "$workspace" status --short --untracked-files=all 2>/dev/null | sed -n "1,${SESSION_BRIEF_MAX_DIRTY_FILES}p")
  recent_errors=$({ grep -vE '^(#|>|$)' "$workspace/.ralph/errors.log" 2>/dev/null || true; } | tail -n "$SESSION_BRIEF_MAX_ERROR_LINES")
  large_files=$(list_large_context_files "$workspace")
  hotspot_summary=$(summarize_recent_read_hotspots "$workspace" "$READ_HOTSPOT_LIMIT")
  navigation_target=$(resolve_navigation_target "$workspace")
  scaffolding_warnings=$(collect_task_scaffolding_warnings "$workspace")

  if should_force_narrow_mode "$workspace"; then
    forced_narrow=1
  fi

  if [[ -f "$workspace/.ralph/progress.md" ]]; then
    carried_notes=$(extract_progress_keep_block "$workspace/.ralph/progress.md" \
      | grep -E '^[[:space:]]*-' \
      | sed -E 's/^[[:space:]]*-[[:space:]]+//' \
      | sed -n '1,8p')
  else
    carried_notes=""
  fi

  {
    echo "# Ralph Session Brief"
    echo ""
    echo "> Auto-generated before each iteration. Read this first."
    echo ""
    echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- Criteria: $done_count / $total_count complete ($remaining_count remaining)"
    if [[ -n "$next_desc" ]]; then
      echo "- Next unchecked criterion: $next_desc"
    fi
    if [[ -n "$next_line" ]]; then
      echo "- RALPH_TASK target line: $next_line"
      echo "- Read strategy: open \`RALPH_TASK.md\` around line $next_line first instead of reading the whole file."
    else
      echo "- Read strategy: use the next unchecked checkbox in \`RALPH_TASK.md\` as the starting point."
    fi
    echo ""

    if [[ -n "$carried_notes" ]]; then
      echo "## Carried Forward Notes"
      echo ""
      while IFS= read -r item; do
        [[ -n "$item" ]] && echo "- $item"
      done <<< "$carried_notes"
      echo ""
    fi

    echo "## Hard Rules"
    echo ""
    echo "- Do not full-read \`.ralph/progress.md\` if the carried-forward notes here already answer your question."
    echo "- Start discovery with \`rg --files | rg\`, \`find . -path\`, or another shortlist command before opening unfamiliar code."
    echo "- Search inside shortlisted files with \`rg -n\`, then read one bounded window (${TARGETED_READ_WINDOW_GUIDE}) with \`sed -n 'start,endp'\`."
    echo "- If keyword search is noisy, tighten the regex or directory before opening more files."
    echo "- If \`.ralph/navigation-brief.md\` names a hot file, follow its recommended commands before any direct reread."
    echo "- Do not full-read files listed under \"Large Files To Slice First\" until you have narrowed to a symbol or line range."
    echo "- If you reread the same huge file twice before writing code, you are stuck: switch to \`rg -n\` / \`sed -n\` or move on."
    echo ""

    if [[ -n "$scaffolding_warnings" ]]; then
      echo "## Task Scaffolding Warnings"
      echo ""
      while IFS= read -r item; do
        [[ -n "$item" ]] && echo "$item"
      done <<< "$scaffolding_warnings"
      echo ""
    fi

    if [[ "$forced_narrow" -eq 1 ]]; then
      echo "## Forced Narrow Mode"
      echo ""
      echo "- Active because the last session reread large files without meaningful progress."
      if [[ -n "$navigation_target" ]]; then
        echo "- Read \`.ralph/navigation-brief.md\` before reopening \`$navigation_target\`."
        echo "- Do not full-read \`$navigation_target\` in this session unless you are editing it immediately."
      else
        echo "- Read \`.ralph/navigation-brief.md\` before opening any hotspot file."
      fi
      echo "- Keep exploration to one or two searches plus one bounded read window before you either edit, test, or record the next slice."
      echo "- After one or two narrow reads, either make a concrete edit/test change or record the next exact slice in \`.ralph/progress.md\`."
      echo ""
    fi

    echo "## Targeted Read Workflow"
    echo ""
    echo "- Derive search words from the next criterion, a failing test name, an error string, or the symbol you need to change."
    echo "- Shortlist candidate files first with \`rg --files | rg -i 'keyword'\` or \`find . -path '*keyword*'\`."
    echo "- Search inside those files with \`rg -n -i 'keyword' path...\` before reading anything large."
    echo "- Read one bounded window at a time (${TARGETED_READ_WINDOW_GUIDE}) with \`sed -n 'start,endp' path\`."
    echo "- If the hit set is still broad, tighten the search instead of opening another large file."
    echo ""

    echo "## If You Stall"
    echo ""
    echo "- After two searches and one bounded read, either make the smallest useful edit/test change or record the next exact command/path in \`.ralph/progress.md\`."
    echo "- Never check off a criterion on intent alone. Verify it with a command or concrete observable result first."
    echo "- If the blocker is manual or external, record it precisely in \`.ralph/progress.md\` and prefer \`<ralph>GUTTER</ralph>\` over more blind retries."
    echo ""

    echo "## Immediate Focus"
    echo ""
    if [[ -n "$next_desc" ]]; then
      echo "- Start with: $next_desc"
    else
      echo "- Start with the next unchecked criterion in \`RALPH_TASK.md\`."
    fi
    if [[ -n "$navigation_target" ]]; then
      echo "- Use \`.ralph/navigation-brief.md\` before touching \`$navigation_target\`."
    fi
    echo "- Prefer narrow reads (\`rg -n\`, \`wc -l\`, \`sed -n\`) before full-reading large files."
    echo "- If you have not written code yet, do not reread the same large file repeatedly."
    echo "- Keep the first concrete code/test change closer than the third large-file read."
    echo ""

    if [[ -n "$pending_sample" ]]; then
      echo "## Next Up"
      echo ""
      while IFS= read -r item; do
        [[ -n "$item" ]] && echo "- $item"
      done <<< "$pending_sample"
      echo ""
    fi

    if [[ -n "$completed_sample" ]]; then
      echo "## Recently Completed"
      echo ""
      while IFS= read -r item; do
        [[ -n "$item" ]] && echo "- $item"
      done <<< "$completed_sample"
      echo ""
    fi

    echo "## Working Tree"
    echo ""
    if [[ -n "$dirty_files" ]]; then
      while IFS= read -r item; do
        [[ -n "$item" ]] && echo "- $item"
      done <<< "$dirty_files"
    else
      echo "- Working tree currently clean."
    fi
    echo ""

    if [[ -n "$recent_errors" ]]; then
      echo "## Recent Failures / Warnings"
      echo ""
      while IFS= read -r item; do
        [[ -n "$item" ]] && echo "- $item"
      done <<< "$recent_errors"
      echo ""
    fi

    if [[ -n "$hotspot_summary" ]]; then
      echo "## Recent Large-Read Hotspots"
      echo ""
      while IFS=$'\t' read -r count last_iter max_bytes max_lines path; do
        local display_path marker kb
        [[ -n "$path" ]] || continue
        display_path=$(normalize_workspace_path "$workspace" "$path")
        kb=$((max_bytes / 1024))
        marker=""
        if [[ -n "$navigation_target" ]] && [[ "$display_path" == "$navigation_target" ]]; then
          marker=" <- hot file"
        fi
        echo "- $display_path (${count} reads, last iteration ${last_iter}, ~${kb}KB, ${max_lines} lines)$marker"
      done <<< "$hotspot_summary"
      echo ""
    fi

    if [[ -n "$large_files" ]]; then
      echo "## Large Files To Slice First"
      echo ""
      while IFS=$'\t' read -r bytes lines path; do
        [[ -n "$path" ]] || continue
        echo "- $path (~$((bytes / 1024))KB, $lines lines)"
      done <<< "$large_files"
      echo ""
    fi
  } > "$brief_file"

  if [[ -n "$next_line" ]]; then
    append_task_slice_section "$brief_file" "$workspace" "$next_line"
  fi
}

# Extract the preserved top block from progress.md
extract_progress_keep_block() {
  local progress_file="$1"

  if grep -q '^<!-- RALPH_COMPACT_KEEP_START -->$' "$progress_file" 2>/dev/null && \
     grep -q '^<!-- RALPH_COMPACT_KEEP_END -->$' "$progress_file" 2>/dev/null; then
    awk '
      /^<!-- RALPH_COMPACT_KEEP_START -->$/ { keep=1; next }
      /^<!-- RALPH_COMPACT_KEEP_END -->$/ { exit }
      keep { print }
    ' "$progress_file"
    return
  fi

  awk '
    /^## (Live Mission Log|Mission Log|Session History|History|Iteration History)$/ { exit }
    /^### (Iteration|Session|[0-9][0-9][0-9][0-9]-)/ { exit }
    { print }
  ' "$progress_file"
}

# Default preserved block for progress.md when none exists yet
write_default_progress_keep_block() {
  cat << 'EOF'
# Progress Log

> Updated by the agent after significant work.

- Historical detail is auto-rotated to `.ralph/archive/` during long runs.
- Keep the live file concise and authoritative.
EOF
}

# Rotate progress.md into an archive and keep a compact live summary
rotate_progress_log() {
  local workspace="$1"
  local stamp="$2"
  local archive_dir archive_file progress_file keep_tmp output_tmp

  progress_file="$workspace/.ralph/progress.md"
  archive_dir=$(ensure_ralph_archive_dir "$workspace")
  archive_file="$archive_dir/progress-$stamp.md"
  keep_tmp=$(mktemp)
  output_tmp=$(mktemp)

  cp "$progress_file" "$archive_file"
  extract_progress_keep_block "$progress_file" > "$keep_tmp"

  if [[ ! -s "$keep_tmp" ]]; then
    write_default_progress_keep_block > "$keep_tmp"
  fi

  {
    echo "<!-- RALPH_COMPACT_KEEP_START -->"
    cat "$keep_tmp"
    echo "<!-- RALPH_COMPACT_KEEP_END -->"
    echo ""
    echo "## Auto Rotation Snapshot"
    echo ""
    echo "- Rotated at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- Archived full progress log: \`.ralph/archive/$(basename "$archive_file")\`"
    echo "- Read the preserved block above first on every new iteration."
    echo "- Only open archived history if the current summary is insufficient to resolve a blocker."
    echo ""
  } > "$output_tmp"

  write_task_snapshot_section "$output_tmp" "$workspace" "## Task Snapshot"

  {
    echo ""
    echo "## Live Mission Log"
    echo ""
    echo "- $(date '+%Y-%m-%d %H:%M:%S %Z'): Progress log auto-rotated. Continue appending new iteration notes below this line."
  } >> "$output_tmp"

  mv "$output_tmp" "$progress_file"
  rm -f "$keep_tmp"
}

# Rotate activity.log into an archive and replace it with a lightweight restart log
rotate_activity_log() {
  local workspace="$1"
  local stamp="$2"
  local archive_dir archive_file activity_file output_tmp

  activity_file="$workspace/.ralph/activity.log"
  archive_dir=$(ensure_ralph_archive_dir "$workspace")
  archive_file="$archive_dir/activity-$stamp.log"
  output_tmp=$(mktemp)

  cp "$activity_file" "$archive_file"

  {
    echo "# Activity Log"
    echo ""
    echo "> Auto-rotated during a long Ralph run to keep restart context lightweight."
    echo ""
    echo "## Rotation"
    echo ""
    echo "- Rotated at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- Archived raw activity: \`.ralph/archive/$(basename "$archive_file")\`"
    echo ""
    echo "## Startup Hints"
    echo ""
    echo "- Read \`.ralph/session-brief.md\` first for the current focus, carried-forward notes, and large-file cautions."
    echo "- Read \`RALPH_TASK.md\`, \`.ralph/guardrails.md\`, and the preserved top block of \`.ralph/progress.md\` first."
    echo "- Trust the current live summary before reopening rotated archives."
    echo "- Keep new live activity high-signal; the parser will continue appending below."
    echo ""
  } > "$output_tmp"

  write_task_snapshot_section "$output_tmp" "$workspace" "## Task Snapshot"

  {
    echo ""
    echo "## Live Append Area"
    echo ""
    echo "- $(date '+%Y-%m-%d %H:%M:%S %Z'): Activity log auto-rotated. Continue appending fresh activity below this line."
  } >> "$output_tmp"

  mv "$output_tmp" "$activity_file"
}

# Compact long-lived logs between Ralph iterations
auto_rotate_ralph_logs_if_needed() {
  local workspace="$1"
  local progress_file="$workspace/.ralph/progress.md"
  local activity_file="$workspace/.ralph/activity.log"
  local stamp=""

  [[ "$AUTO_ROTATE_LOGS" == "true" ]] || return 0

  if should_rotate_log_file "$progress_file" "$PROGRESS_ROTATE_MAX_BYTES" "$PROGRESS_ROTATE_MAX_LINES"; then
    stamp=$(make_rotation_stamp)
    echo "🧹 Compacting .ralph/progress.md for the next Ralph iteration..." >&2
    rotate_progress_log "$workspace" "$stamp"
  fi

  if should_rotate_log_file "$activity_file" "$ACTIVITY_ROTATE_MAX_BYTES" "$ACTIVITY_ROTATE_MAX_LINES"; then
    [[ -n "$stamp" ]] || stamp=$(make_rotation_stamp)
    echo "🧹 Compacting .ralph/activity.log for the next Ralph iteration..." >&2
    rotate_activity_log "$workspace" "$stamp"
  fi
}

# =============================================================================
# LOCKING AND PROCESS CLEANUP
# =============================================================================

# Convert ISO-8601 UTC timestamp to epoch seconds (cross-platform)
iso_utc_to_epoch() {
  local iso_ts="$1"

  if [[ -z "$iso_ts" ]]; then
    echo "0"
    return
  fi

  if [[ "$OSTYPE" == "darwin"* ]]; then
    date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso_ts" '+%s' 2>/dev/null || echo "0"
  else
    date -d "$iso_ts" '+%s' 2>/dev/null || echo "0"
  fi
}

# Release the sequential lock if this shell owns it
release_sequential_lock() {
  local lock_dir="${1:-${SEQUENTIAL_LOCK_HELD:-}}"
  local owner_pid=""

  [[ -n "$lock_dir" ]] || return 0
  [[ -d "$lock_dir" ]] || return 0

  owner_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  if [[ -n "$owner_pid" ]] && [[ "$owner_pid" != "$$" ]]; then
    return 0
  fi

  rm -rf "$lock_dir" 2>/dev/null || true

  if [[ "${SEQUENTIAL_LOCK_HELD:-}" == "$lock_dir" ]]; then
    SEQUENTIAL_LOCK_HELD=""
  fi
}

# Acquire a workspace-level lock so sequential Ralph runs do not overlap
acquire_sequential_lock() {
  local workspace="${1:-.}"
  local lock_dir="$workspace/$SEQUENTIAL_LOCK_DIR"
  local lock_parent
  lock_parent="$(dirname "$lock_dir")"

  if [[ "${SEQUENTIAL_LOCK_HELD:-}" == "$lock_dir" ]]; then
    return 0
  fi

  mkdir -p "$lock_parent"

  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" > "$lock_dir/pid" 2>/dev/null || true
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$lock_dir/created_at" 2>/dev/null || true
    pwd > "$lock_dir/cwd" 2>/dev/null || true
    SEQUENTIAL_LOCK_HELD="$lock_dir"
    trap 'release_sequential_lock >/dev/null 2>&1 || true' EXIT INT TERM
    return 0
  fi

  local lock_pid lock_created_at now_epoch lock_epoch age_minutes
  local is_stale=false
  lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  lock_created_at=$(cat "$lock_dir/created_at" 2>/dev/null || echo "")
  now_epoch=$(date '+%s')
  lock_epoch=$(iso_utc_to_epoch "$lock_created_at")
  age_minutes=$(( (now_epoch - lock_epoch) / 60 ))

  if [[ -n "$lock_pid" ]]; then
    if ! kill -0 "$lock_pid" 2>/dev/null; then
      is_stale=true
    fi
  elif [[ "$age_minutes" -ge "$LOCK_STALE_MINUTES" ]]; then
    is_stale=true
  fi

  if [[ "$is_stale" == "true" ]]; then
    echo "🔓 Stale sequential Ralph lock detected (pid: ${lock_pid:-missing}, age ${age_minutes}m). Recovering..." >&2
    rm -rf "$lock_dir" 2>/dev/null || true
    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$$" > "$lock_dir/pid" 2>/dev/null || true
      date -u '+%Y-%m-%dT%H:%M:%SZ' > "$lock_dir/created_at" 2>/dev/null || true
      pwd > "$lock_dir/cwd" 2>/dev/null || true
      SEQUENTIAL_LOCK_HELD="$lock_dir"
      trap 'release_sequential_lock >/dev/null 2>&1 || true' EXIT INT TERM
      return 0
    fi
  fi

  echo "❌ Ralph loop already running for this workspace: $lock_dir" >&2
  if [[ -n "$lock_pid" ]]; then
    echo "   pid: $lock_pid" >&2
  fi
  if [[ -n "$lock_created_at" ]]; then
    echo "   created_at: $lock_created_at" >&2
  fi
  echo "   Stop the other Ralph run before starting another one." >&2
  echo "   If that PID is gone and the lock is stale, delete: rm -rf \"$lock_dir\"" >&2
  return 1
}

# List direct child PIDs for a process (cross-platform fallback)
list_child_pids() {
  local parent_pid="$1"

  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$parent_pid" 2>/dev/null || true
  else
    ps -o pid= --ppid "$parent_pid" 2>/dev/null | awk '{print $1}' || true
  fi
}

# Send a signal to a process tree, deepest children first
signal_process_tree() {
  local pid="$1"
  local signal_name="${2:-TERM}"
  local child_pid=""

  [[ -n "$pid" ]] || return 0

  for child_pid in $(list_child_pids "$pid"); do
    signal_process_tree "$child_pid" "$signal_name"
  done

  kill "-$signal_name" "$pid" 2>/dev/null || true
}

# Stop a background pipeline and all of its descendants
stop_process_tree() {
  local pid="$1"

  [[ -n "$pid" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  signal_process_tree "$pid" TERM
  sleep 1

  if kill -0 "$pid" 2>/dev/null; then
    signal_process_tree "$pid" KILL
  fi
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize .ralph directory with default files
init_ralph_dir() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  
  # Initialize progress.md if it doesn't exist
  if [[ ! -f "$ralph_dir/progress.md" ]]; then
    cat > "$ralph_dir/progress.md" << 'EOF'
<!-- RALPH_COMPACT_KEEP_START -->
# Progress Log

> Updated by the agent after significant work.

- Keep the live summary concise and authoritative.
- Historical detail may be auto-rotated to `.ralph/archive/` during long runs.
<!-- RALPH_COMPACT_KEEP_END -->

---

## Session History

EOF
  fi
  
  # Initialize guardrails.md if it doesn't exist
  if [[ ! -f "$ralph_dir/guardrails.md" ]]; then
    cat > "$ralph_dir/guardrails.md" << 'EOF'
# Ralph Guardrails (Signs)

> Lessons learned from past failures. READ THESE BEFORE ACTING.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Always read the existing file first
- **Added after**: Core principle

### Sign: Search Before Large Read
- **Trigger**: Before opening a large or unfamiliar file
- **Instruction**: Shortlist files with `rg --files | rg` or `find`, search inside them with `rg -n`, then read one bounded window with `sed -n`
- **Added after**: Core principle

### Sign: Test After Changes
- **Trigger**: After any code change
- **Instruction**: Run tests to verify nothing broke
- **Added after**: Core principle

### Sign: Verify Before Checkoff
- **Trigger**: Before marking any criterion complete
- **Instruction**: Run the verification command or confirm the concrete observable result first
- **Added after**: Core principle

### Sign: Commit Checkpoints
- **Trigger**: Before risky changes
- **Instruction**: Commit current working state first
- **Added after**: Core principle

### Sign: Leave a Precise Handoff
- **Trigger**: Before rotation or when blocked
- **Instruction**: Record the exact next command, file, symbol, or line window in `.ralph/progress.md`
- **Added after**: Core principle

---

## Learned Signs

EOF
  fi
  
  # Initialize errors.log if it doesn't exist
  if [[ ! -f "$ralph_dir/errors.log" ]]; then
    cat > "$ralph_dir/errors.log" << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi
  
  # Initialize activity.log if it doesn't exist
  if [[ ! -f "$ralph_dir/activity.log" ]]; then
    cat > "$ralph_dir/activity.log" << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi

  # Initialize signals.log if it doesn't exist
  if [[ ! -f "$ralph_dir/signals.log" ]]; then
    cat > "$ralph_dir/signals.log" << 'EOF'
# Signal Log

> Durable signal/event history for the Ralph dashboard.

EOF
  fi

  # Initialize session-brief.md if it doesn't exist
  if [[ ! -f "$ralph_dir/session-brief.md" ]]; then
    cat > "$ralph_dir/session-brief.md" << 'EOF'
# Ralph Session Brief

> Auto-generated before each iteration. Read this first.

- Generated: not yet
- Criteria: 0 / 0 complete
- Next unchecked criterion: unknown
- Read strategy: open the relevant slice of `RALPH_TASK.md`, not the whole repo.
- Discovery strategy: shortlist files with `rg --files | rg` or `find`, then `rg -n`, then bounded `sed -n` windows.

EOF
  fi

  if [[ ! -f "$ralph_dir/navigation-brief.md" ]]; then
    cat > "$ralph_dir/navigation-brief.md" << 'EOF'
# Ralph Navigation Brief

> Auto-generated before each iteration when Ralph needs a tighter map through a large file.

- Generated: not yet
- Last session signal: NONE
- Forced narrow mode: standby
- Current hot file: not yet identified
- Search-first workflow: shortlist files, grep for task words, then read one bounded slice at a time.

EOF
  fi

  if [[ ! -f "$ralph_dir/read-trace.tsv" ]]; then
    printf 'timestamp\titeration\tpath\tbytes\tlines\tper_file_reads\twrite_calls_before_read\tthrash_hit\n' > "$ralph_dir/read-trace.tsv"
  fi

  if [[ ! -f "$ralph_dir/shell-edit-trace.tsv" ]]; then
    printf 'timestamp\titeration\texit_code\tstatus\tpath\tbefore_bytes\tafter_bytes\twork_path\tcommand\n' > "$ralph_dir/shell-edit-trace.tsv"
  fi

  if [[ ! -f "$ralph_dir/runtime.env" ]]; then
    write_runtime_state "$workspace" "idle" "$(get_iteration "$workspace")" "$MODEL" "NONE" "Waiting for Ralph"
  fi
}

# =============================================================================
# TASK MANAGEMENT
# =============================================================================

# Check if task is complete
# Uses task-parser.sh when available for cached/YAML support
check_task_complete() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "NO_TASK_FILE"
    return
  fi
  
  # Use task parser if available (provides caching)
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    local remaining
    remaining=$(count_remaining "$workspace" 2>/dev/null) || remaining=-1
    
    if [[ "$remaining" -eq 0 ]]; then
      echo "COMPLETE"
    elif [[ "$remaining" -gt 0 ]]; then
      echo "INCOMPLETE:$remaining"
    else
      # Fallback to direct grep if parser fails
      _check_task_complete_direct "$workspace"
    fi
  else
    _check_task_complete_direct "$workspace"
  fi
}

# Direct task completion check (fallback)
_check_task_complete_direct() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Only count actual checkbox list items, not [ ] in prose/examples
  # Matches: "- [ ]", "* [ ]", "1. [ ]", etc.
  local unchecked
  unchecked=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null) || unchecked=0
  
  if [[ "$unchecked" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$unchecked"
  fi
}

# Count task criteria (returns done:total)
# Uses task-parser.sh when available for cached/YAML support
count_criteria() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "0:0"
    return
  fi
  
  # Use task parser if available (provides caching)
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    local progress
    progress=$(get_progress "$workspace" 2>/dev/null) || progress=""
    
    if [[ -n "$progress" ]] && [[ "$progress" =~ ^[0-9]+:[0-9]+$ ]]; then
      echo "$progress"
    else
      # Fallback to direct grep if parser fails
      _count_criteria_direct "$workspace"
    fi
  else
    _count_criteria_direct "$workspace"
  fi
}

# Direct criteria counting (fallback)
_count_criteria_direct() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Only count actual checkbox list items, not [x] or [ ] in prose/examples
  # Matches: "- [ ]", "* [x]", "1. [ ]", etc.
  local total done_count
  total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
  
  echo "$done_count:$total"
}

# =============================================================================
# TASK PARSER CONVENIENCE WRAPPERS
# =============================================================================

# Get the next task to work on (wrapper for task-parser.sh)
# Returns: task_id|status|description or empty
get_next_task_info() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    get_next_task "$workspace" 2>/dev/null || true
  else
    echo ""
  fi
}

# Mark a specific task complete by line-based ID
# Usage: complete_task "$workspace" "line_15"
complete_task() {
  local workspace="${1:-.}"
  local task_id="$2"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    mark_task_complete "$workspace" "$task_id"
  else
    echo "ERROR: Task parser not available" >&2
    return 1
  fi
}

# List all tasks with their status
# Usage: list_all_tasks "$workspace"
list_all_tasks() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    get_all_tasks "$workspace"
  else
    echo "ERROR: Task parser not available" >&2
    return 1
  fi
}

# Refresh task cache (useful after external edits)
refresh_task_cache() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    # Invalidate and re-parse
    rm -f "$workspace/.ralph/$TASK_MTIME_FILE" 2>/dev/null
    parse_tasks "$workspace"
  fi
}

# =============================================================================
# TASK SCAFFOLDING VALIDATION
# =============================================================================

count_total_criteria() {
  local workspace="${1:-.}"
  local counts total

  counts=$(count_criteria "$workspace" 2>/dev/null || echo "0:0")
  total="${counts##*:}"
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  printf '%s\n' "$total"
}

count_pending_criteria() {
  local workspace="${1:-.}"
  local counts done_count total_count pending_count

  counts=$(count_criteria "$workspace" 2>/dev/null || echo "0:0")
  done_count="${counts%%:*}"
  total_count="${counts##*:}"

  [[ "$done_count" =~ ^[0-9]+$ ]] || done_count=0
  [[ "$total_count" =~ ^[0-9]+$ ]] || total_count=0

  pending_count=$((total_count - done_count))
  if [[ "$pending_count" -lt 0 ]]; then
    pending_count=0
  fi

  printf '%s\n' "$pending_count"
}

task_file_has_success_criteria_heading() {
  local task_file="$1"
  grep -qiE '^#{1,6}[[:space:]]+Success Criteria([[:space:]]|$)' "$task_file" 2>/dev/null
}

task_file_has_test_command() {
  local task_file="$1"

  awk '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit found ? 0 : 1 }
    in_frontmatter && $0 ~ /^[[:space:]]*test_command[[:space:]]*:/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$task_file" >/dev/null 2>&1
}

list_manual_pending_task_hits() {
  local workspace="${1:-.}"
  local limit="${2:-$TASK_SCAFFOLD_WARN_MANUAL_LIMIT}"

  list_task_descriptions "$workspace" pending 2>/dev/null \
    | grep -Ei '(manual|approval|approve|ask[[:space:]]+user|wait[[:space:]]+for|human|browser|click|log[[:space:]]*in|login|sign[[:space:]]*in|deploy[[:space:]]+to[[:space:]]+production|production[[:space:]]+deploy)' \
    | sed -n "1,${limit}p"
}

collect_task_scaffolding_warnings() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  local pending_count next_desc manual_hits next_task next_id next_status

  [[ -f "$task_file" ]] || return 0

  if grep -Eq '^[[:space:]]*completion_criteria[[:space:]]*:' "$task_file" 2>/dev/null; then
    echo "- Remove or ignore frontmatter \`completion_criteria\`. Ralph only tracks the checkbox list under \`## Success Criteria\`."
  fi

  if ! task_file_has_success_criteria_heading "$task_file"; then
    echo "- Add a \`## Success Criteria\` heading so the tracked checklist is easy for cheaper models to find."
  fi

  if ! task_file_has_test_command "$task_file"; then
    echo "- Add a frontmatter \`test_command\` or name another repeatable verification command in a checkbox so Ralph can verify progress instead of guessing."
  fi

  pending_count=$(count_pending_criteria "$workspace")
  if [[ "$pending_count" -gt "$TASK_SCAFFOLD_WARN_PENDING_MAX" ]]; then
    echo "- There are $pending_count pending criteria. Smaller models do better when only the next 3-8 checkboxes are actively in play."
  fi

  next_task=$(get_next_task_info "$workspace")
  if [[ -n "$next_task" ]]; then
    IFS='|' read -r next_id next_status next_desc <<< "$next_task"
  else
    next_desc=$(sample_task_descriptions "$workspace" pending 1)
  fi

  if [[ -n "$next_desc" ]] && [[ ${#next_desc} -gt "$TASK_SCAFFOLD_WARN_DESC_LENGTH" ]]; then
    echo "- The next unchecked criterion is ${#next_desc} characters long. Split it into one concrete, verifiable outcome."
  fi

  manual_hits=$(list_manual_pending_task_hits "$workspace")
  if [[ -n "$manual_hits" ]]; then
    while IFS= read -r item; do
      [[ -n "$item" ]] && echo "- Manual or human-dependent criterion detected: $item"
    done <<< "$manual_hits"
    echo "- Move manual/browser/approval work into notes or out-of-scope; keep the success checklist automatable."
  fi
}

print_task_scaffolding_warnings() {
  local workspace="${1:-.}"
  local warnings

  warnings=$(collect_task_scaffolding_warnings "$workspace")
  [[ -n "$warnings" ]] || return 0

  echo "⚠️  Task scaffolding warnings:"
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "$line"
  done <<< "$warnings"
  echo ""
}

validate_task_scaffolding() {
  local workspace="${1:-.}"
  local total_count

  total_count=$(count_total_criteria "$workspace")
  if [[ "$total_count" -le 0 ]]; then
    echo "❌ RALPH_TASK.md has no checkbox criteria Ralph can track."
    echo ""
    echo "Add a checklist under a \`## Success Criteria\` heading, for example:"
    echo "  ## Success Criteria"
    echo "  1. [ ] Implement the smallest verifiable behavior"
    echo "  2. [ ] Run the verification command and confirm the expected output"
    echo ""
    echo "Ralph only tracks actual checkbox list items like \`- [ ]\` or \`1. [ ]\`."
    return 1
  fi

  return 0
}

# =============================================================================
# PROMPT BUILDING
# =============================================================================

# Build the Ralph prompt for an iteration
build_prompt() {
  local workspace="$1"
  local iteration="$2"

  cat <<'EOF' | sed \
    -e "s/__RALPH_ITERATION__/$iteration/g" \
    -e "s/__TARGETED_READ_WINDOW_GUIDE__/$TARGETED_READ_WINDOW_GUIDE/g"
# Ralph Iteration __RALPH_ITERATION__

You are an autonomous development agent using the Ralph methodology.

## FIRST: Read State Files

Before doing anything:
1. Read \`.ralph/session-brief.md\` - your curated working set for this iteration
2. Read \`.ralph/navigation-brief.md\` if it exists - especially before reopening any large/hot file
3. Read \`.ralph/guardrails.md\` - lessons from past failures (FOLLOW THESE)
4. Do NOT read \`.ralph/progress.md\` unless the brief's carried-forward notes are insufficient
   - If logs were rotated, trust the live summary first and only read archives if blocked
5. Prefer the Task Slice already included in the brief; only open \`RALPH_TASK.md\` directly if you need more nearby context
6. Read \`.ralph/errors.log\` only when the brief points to a recent failure you need more detail on

## Working Directory (Critical)

You are already in a git repository. Work HERE, not in a subdirectory:

- Do NOT run \`git init\` - the repo already exists
- Do NOT run scaffolding commands that create nested directories (\`npx create-*\`, \`pnpm init\`, etc.)
- If you need to scaffold, use flags like \`--no-git\` or scaffold into the current directory (\`.\`)
- All code should live at the repo root or in subdirectories you create manually

## Git Protocol (Critical)

Ralph's strength is state-in-git, not LLM memory. Commit early and often:

1. After completing each criterion, commit your changes:
   \`git add -A && git commit -m 'ralph: implement state tracker'\`
   \`git add -A && git commit -m 'ralph: fix async race condition'\`
   \`git add -A && git commit -m 'ralph: add CLI adapter with commander'\`
   Always describe what you actually did - never use placeholders like '<description>'
2. After any significant code change (even partial): commit with descriptive message
3. Before any risky refactor: commit current state as checkpoint
4. Push only if a remote already exists and pushing is already part of the repo workflow
   - Check with \`git remote -v\`
   - If there is no remote or auth is missing, skip pushing instead of burning iterations on setup

If you get rotated, the next agent picks up from your last commit. Your commits ARE your memory.

## Task Execution

1. Treat the next unchecked criterion named in \`.ralph/session-brief.md\` as the primary objective for this iteration
   - Do not widen scope unless adjacent work is directly required to satisfy that checkbox
2. Run the explicit \`test_command\` when present; otherwise use the most direct repeatable verification command from the criterion itself
3. **Mark completed criteria**: Edit RALPH_TASK.md and change \`[ ]\` to \`[x]\`
   - Example: \`- [ ] Implement parser\` becomes \`- [x] Implement parser\`
   - This is how progress is tracked - YOU MUST update the file
   - Never mark a criterion complete on intent alone; verify it first with a command or concrete observable result
4. Update \`.ralph/progress.md\` with what you accomplished
   - Keep it concise and high-signal
   - Do not paste long command output or rebuild giant historical logs
   - Preserve the authoritative top summary block when editing
   - If blocked, leave the exact blocker plus the next command, file, or line window the next agent should try
5. When ALL criteria show \`[x]\`: output \`<ralph>COMPLETE</ralph>\`
6. If stuck 3+ times on same issue: output \`<ralph>GUTTER</ralph>\`

## Context Discipline (Critical)

- Start discovery by shortlisting candidate files with \`rg --files | rg -i 'keyword'\`, \`find . -path '*keyword*'\`, or a similarly narrow file search
- Derive those keywords from the next criterion, a failing test name, the nearest error string, or the symbol you need to change
- Search inside shortlisted files with \`rg -n -i 'keyword' path...\` before opening them
- After a search hit, read only one bounded window (__TARGETED_READ_WINDOW_GUIDE__) with \`sed -n 'start,endp' path\`
- If a search is noisy, tighten the regex or directory scope instead of opening more files
- Before full-reading any file larger than roughly 80KB or 800 lines, narrow first with \`rg -n\`, \`git diff --name-only\`, \`wc -l\`, or \`sed -n 'start,endp'\`
- If \`.ralph/navigation-brief.md\` names a hot file, use its recommended commands before any direct reread
- If a file is listed under "Large Files To Slice First" in the brief, treat full reads as a last resort
- Do not full-read the same large file more than twice in one session unless you are editing it immediately
- Avoid chaining together multiple giant file reads before making a concrete code/test change
- In forced narrow mode, do not full-read the hot file at all unless you are editing it immediately
- In forced narrow mode, after one or two narrow reads you must either edit code/tests or update \`.ralph/progress.md\` with the next exact slice
- If context is getting tight and you have not written meaningful code yet, stop discovery, update \`.ralph/progress.md\` with the next concrete target, and let rotation happen

## Stuck Recovery Ladder

If progress stalls, do these in order instead of looping:
1. Tighten the search term, regex, directory, or symbol target instead of opening more large files
2. After one or two narrow reads, make the smallest useful edit or run the smallest useful verification command
3. If blocked by a missing dependency, manual step, missing credential, or external system, record the exact blocker and next command/path in \`.ralph/progress.md\`
4. If you still cannot advance after that, output \`<ralph>GUTTER</ralph>\` instead of spinning

## Learning from Failures

When something fails:
1. Check \`.ralph/errors.log\` for failure history
2. Figure out the root cause
3. Add a Sign to \`.ralph/guardrails.md\` using this format:

\`\`\`
### Sign: [Descriptive Name]
- **Trigger**: When this situation occurs
- **Instruction**: What to do instead
- **Added after**: Iteration __RALPH_ITERATION__ - what happened
\`\`\`

## Context Rotation Warning

You may receive a warning that context is running low. When you see it:
1. Finish your current file edit
2. Commit and push your changes
3. Update .ralph/progress.md with what you accomplished and what's next
   - Keep the live summary concise so the next agent can restart cheaply
   - Leave an exact next command, path, or line range when the task is mid-flight
4. You will be rotated to a fresh agent that continues your work

Begin by reading the state files.
EOF
}

# =============================================================================
# SPINNER
# =============================================================================

# Spinner to show the loop is alive (not frozen)
# Outputs to stderr so it's not captured by $()
spinner() {
  local workspace="$1"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while true; do
    printf "\r  🐛 Agent working... %s  (watch: tail -f %s/.ralph/activity.log)" "${spin:i++%${#spin}:1}" "$workspace" >&2
    sleep 0.1
  done
}

# =============================================================================
# ITERATION RUNNER
# =============================================================================

# Run a single agent iteration
# Returns: signal (ROTATE, GUTTER, COMPLETE, DEFER, or empty)
run_iteration() {
  local workspace="$1"
  local iteration="$2"
  local script_dir="${3:-$(dirname "${BASH_SOURCE[0]}")}"

  require_auto_model "$MODEL" || return 1
  auto_rotate_ralph_logs_if_needed "$workspace"
  load_last_session_metrics "$workspace"
  write_navigation_brief "$workspace"
  write_session_brief "$workspace"
  initialize_session_metrics "$workspace" "$iteration" "$MODEL"
  
  local prompt=$(build_prompt "$workspace" "$iteration")
  local fifo="$workspace/.ralph/.parser_fifo"
  
  write_runtime_state "$workspace" "running" "$iteration" "$MODEL" "NONE" "Session $iteration starting" "sequential" ""
  append_signal_event "$workspace" "SESSION_REQUESTED" "model_request=$MODEL" "loop" "$iteration"
  
  # Create named pipe for parser signals
  rm -f "$fifo"
  mkfifo "$fifo"
  
  # Use stderr for display (stdout is captured for signal)
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "🐛 Ralph Iteration $iteration" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "Model:     $(format_requested_model_label "$MODEL")" >&2
  echo "Monitor:   tail -f $workspace/.ralph/activity.log" >&2
  echo "" >&2
  
  # Log session start to progress.md
  log_progress "$workspace" "**Session $iteration started** (model request: $(format_requested_model_label "$MODEL"))"
  
  # Build cursor-agent command
  local -a agent_cmd
  agent_cmd=(cursor-agent -p --force --output-format stream-json)
  if [[ -n "${MODEL:-}" ]]; then
    agent_cmd+=(--model "$MODEL")
  fi

  # Change to workspace
  cd "$workspace"
  
  # Start the CLI spinner only for an actual terminal session.
  # The Textual dashboard renders its own liveness indicator and should not
  # capture a redraw loop into tui-run.log.
  local spinner_pid=""
  if [[ "${RALPH_TUI_ACTIVE:-0}" != "1" ]] && [[ -t 2 ]]; then
    spinner "$workspace" &
    spinner_pid=$!
  fi
  
  # Start parser in background, reading from cursor-agent
  # Parser outputs to fifo, we read signals from fifo
  (
    export LARGE_READ_THRESHOLD_BYTES="$LARGE_READ_THRESHOLD_BYTES"
    export VERY_LARGE_READ_THRESHOLD_BYTES="$VERY_LARGE_READ_THRESHOLD_BYTES"
    export MAX_VERY_LARGE_REREADS_PER_FILE="$MAX_VERY_LARGE_REREADS_PER_FILE"
    export MAX_LARGE_REREADS_PER_FILE="$MAX_LARGE_REREADS_PER_FILE"
    export MAX_LARGE_READS_WITHOUT_WRITE="$MAX_LARGE_READS_WITHOUT_WRITE"
    export RALPH_ITERATION="$iteration"
    export RALPH_MODEL_RUNTIME="$MODEL"
    "${agent_cmd[@]}" "$prompt" 2>&1 | "$script_dir/stream-parser.sh" "$workspace" > "$fifo"
  ) &
  local agent_pid=$!
  write_runtime_state "$workspace" "running" "$iteration" "$MODEL" "NONE" "Session $iteration running" "sequential" "$agent_pid"
  
  # Read signals from parser
  local signal=""
  local gutter_seen=0
  while IFS= read -r line; do
    case "$line" in
      "ROTATE")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "🔄 Context rotation triggered - stopping agent..." >&2
        write_runtime_state "$workspace" "rotating" "$iteration" "$MODEL" "ROTATE" "Context rotation requested" "sequential" "$agent_pid"
        stop_process_tree "$agent_pid"
        signal="ROTATE"
        break
        ;;
      "WARN")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "⚠️  Context warning - agent should wrap up soon..." >&2
        write_runtime_state "$workspace" "running" "$iteration" "$MODEL" "WARN" "Context warning issued" "sequential" "$agent_pid"
        # Send interrupt to encourage wrap-up (agent continues but is notified)
        ;;
      "GUTTER")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "🚨 Gutter detected - agent may be stuck..." >&2
        write_runtime_state "$workspace" "gutter" "$iteration" "$MODEL" "GUTTER" "Gutter detected" "sequential" "$agent_pid"
        gutter_seen=1
        # Keep reading. A terminal signal like ROTATE/DEFER/COMPLETE may still follow.
        ;;
      "COMPLETE")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "✅ Agent signaled completion!" >&2
        write_runtime_state "$workspace" "complete" "$iteration" "$MODEL" "COMPLETE" "Agent signaled completion" "sequential" "$agent_pid"
        signal="COMPLETE"
        # Let agent finish gracefully
        ;;
      "DEFER")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "⏸️  Rate limit or transient error - deferring for retry..." >&2
        write_runtime_state "$workspace" "deferred" "$iteration" "$MODEL" "DEFER" "Transient error deferred" "sequential" "$agent_pid"
        signal="DEFER"
        # Stop the agent, will retry with backoff
        stop_process_tree "$agent_pid"
        break
        ;;
      "ABORT")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "❌ Non-retryable agent failure detected - stopping this iteration..." >&2
        write_runtime_state "$workspace" "error" "$iteration" "$MODEL" "ABORT" "Non-retryable agent failure" "sequential" "$agent_pid"
        signal="ABORT"
        stop_process_tree "$agent_pid"
        break
        ;;
    esac
  done < "$fifo"
  
  # Wait for agent to finish
  local agent_exit=0
  wait $agent_pid 2>/dev/null || agent_exit=$?
  
  # Stop spinner and clear line
  if [[ -n "$spinner_pid" ]]; then
    kill "$spinner_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true
    printf "\r\033[K" >&2  # Clear spinner line
  fi
  
  # Cleanup
  rm -f "$fifo"

  if [[ -z "$signal" ]] && [[ $agent_exit -ne 0 ]]; then
    signal="ABORT"
    log_error "$workspace" "Agent process exited with code $agent_exit before producing a Ralph signal"
    write_runtime_state "$workspace" "error" "$iteration" "$MODEL" "ABORT" "Agent exited with code $agent_exit" "sequential" ""
  fi

  if [[ $gutter_seen -eq 1 ]] && [[ -z "$signal" ]]; then
    signal="ROTATE"
  fi
  
  case "$signal" in
    "ROTATE")
      if [[ $gutter_seen -eq 1 ]]; then
        write_runtime_state "$workspace" "rotating" "$iteration" "$MODEL" "$signal" "Fresh context requested after gutter" "sequential" ""
      else
        write_runtime_state "$workspace" "rotating" "$iteration" "$MODEL" "$signal" "Waiting for fresh context" "sequential" ""
      fi
      ;;
    "GUTTER")
      write_runtime_state "$workspace" "gutter" "$iteration" "$MODEL" "$signal" "Agent got stuck" "sequential" ""
      ;;
    "COMPLETE")
      write_runtime_state "$workspace" "complete" "$iteration" "$MODEL" "$signal" "Agent finished the task" "sequential" ""
      ;;
    "DEFER")
      write_runtime_state "$workspace" "deferred" "$iteration" "$MODEL" "$signal" "Retrying after transient issue" "sequential" ""
      ;;
    "ABORT")
      write_runtime_state "$workspace" "error" "$iteration" "$MODEL" "$signal" "Agent launch/runtime failure" "sequential" ""
      ;;
    *)
      write_runtime_state "$workspace" "idle" "$iteration" "$MODEL" "NONE" "Session $iteration finished" "sequential" ""
      ;;
  esac
  
  echo "$signal"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

# Run the main Ralph loop
# Args: workspace
# Uses global: MAX_ITERATIONS, MODEL, USE_BRANCH, OPEN_PR
run_ralph_loop() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"

  RALPH_LOOP_FINAL_SIGNAL="NONE"
  require_auto_model "$MODEL" || {
    RALPH_LOOP_FINAL_SIGNAL="ABORT"
    return 1
  }
  acquire_sequential_lock "$workspace" || {
    RALPH_LOOP_FINAL_SIGNAL="ABORT"
    return 1
  }
  write_runtime_state "$workspace" "starting" "$(get_iteration "$workspace")" "$MODEL" "NONE" "Loop starting" "loop" ""
  append_signal_event "$workspace" "LOOP_START" "max_iterations=$MAX_ITERATIONS model=$MODEL" "loop" "$(get_iteration "$workspace")"
  
  # Commit any uncommitted work first
  cd "$workspace"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: initial commit before loop" || true
  fi
  
  # Create branch if requested
  if [[ -n "$USE_BRANCH" ]]; then
    echo "🌿 Creating branch: $USE_BRANCH"
    git checkout -b "$USE_BRANCH" 2>/dev/null || git checkout "$USE_BRANCH"
  fi
  
  echo ""
  echo "🚀 Starting Ralph loop..."
  echo ""
  
  # Main loop
  local iteration=1
  local thrash_rotation_streak=0
  
  while [[ $iteration -le $MAX_ITERATIONS ]]; do
    local head_before criteria_before done_before
    local work_edit_calls
    head_before=$(get_git_head)
    criteria_before=$(count_criteria "$workspace")
    done_before="${criteria_before%%:*}"

    # Run iteration
    local signal
    signal=$(run_iteration "$workspace" "$iteration" "$script_dir")

    local head_after criteria_after done_after
    head_after=$(get_git_head)
    criteria_after=$(count_criteria "$workspace")
    done_after="${criteria_after%%:*}"

    load_last_session_metrics "$workspace"
    work_edit_calls=$(session_work_edit_calls_total)

    local progress_made=0
    if [[ "$head_before" != "$head_after" ]] || [[ "$done_after" -gt "$done_before" ]] || [[ "$work_edit_calls" -gt 0 ]]; then
      progress_made=1
    fi

    if [[ "$signal" == "ROTATE" ]] && [[ $progress_made -eq 0 ]] && \
       ([[ "${RALPH_SESSION_LARGE_READ_THRASH_HIT:-0}" -eq 1 ]] || [[ "${RALPH_SESSION_LARGE_READ_REREADS:-0}" -ge 2 ]]); then
      thrash_rotation_streak=$((thrash_rotation_streak + 1))
      log_error "$workspace" "THRASH ROTATION: iteration $iteration rotated without progress (streak $thrash_rotation_streak, large_reads=${RALPH_SESSION_LARGE_READS:-0}, rereads=${RALPH_SESSION_LARGE_READ_REREADS:-0})"

      if [[ $thrash_rotation_streak -ge $MAX_THRASH_ROTATIONS ]]; then
        signal="THRASH"
      fi
    else
      thrash_rotation_streak=0
    fi
    
    # Check task completion
    local task_status
    task_status=$(check_task_complete "$workspace")
    
    if [[ "$task_status" == "COMPLETE" ]]; then
      log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE"
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "🎉 RALPH COMPLETE! All criteria satisfied."
      echo "═══════════════════════════════════════════════════════════════════"
      echo ""
      echo "Completed in $iteration iteration(s)."
      echo "Check git log for detailed history."
      append_signal_event "$workspace" "LOOP_COMPLETE" "All criteria satisfied" "loop" "$iteration"
      write_runtime_state "$workspace" "complete" "$iteration" "$MODEL" "COMPLETE" "All criteria satisfied" "loop" ""
      RALPH_LOOP_FINAL_SIGNAL="COMPLETE"
      
      # Open PR if requested
      if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
        echo ""
        echo "📝 Opening pull request..."
        git push -u origin "$USE_BRANCH" 2>/dev/null || git push
        if command -v gh &> /dev/null; then
          gh pr create --fill || echo "⚠️  Could not create PR automatically. Create manually."
        else
          echo "⚠️  gh CLI not found. Push complete, create PR manually."
        fi
      fi
      
      return 0
    fi
    
    # Handle signals
    case "$signal" in
      "COMPLETE")
        # Agent signaled completion - verify with checkbox check
        if [[ "$task_status" == "COMPLETE" ]]; then
          log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE (agent signaled)"
          echo ""
          echo "═══════════════════════════════════════════════════════════════════"
          echo "🎉 RALPH COMPLETE! Agent signaled completion and all criteria verified."
          echo "═══════════════════════════════════════════════════════════════════"
          echo ""
          echo "Completed in $iteration iteration(s)."
          echo "Check git log for detailed history."
          append_signal_event "$workspace" "LOOP_COMPLETE" "Agent signaled completion and criteria verified" "loop" "$iteration"
          write_runtime_state "$workspace" "complete" "$iteration" "$MODEL" "COMPLETE" "Agent signaled completion and criteria verified" "loop" ""
          RALPH_LOOP_FINAL_SIGNAL="COMPLETE"
          
          # Open PR if requested
          if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
            echo ""
            echo "📝 Opening pull request..."
            git push -u origin "$USE_BRANCH" 2>/dev/null || git push
            if command -v gh &> /dev/null; then
              gh pr create --fill || echo "⚠️  Could not create PR automatically. Create manually."
            else
              echo "⚠️  gh CLI not found. Push complete, create PR manually."
            fi
          fi
          
          return 0
        else
          # Agent said complete but checkboxes say otherwise - continue
          log_progress "$workspace" "**Session $iteration ended** - Agent signaled complete but criteria remain"
          write_runtime_state "$workspace" "running" "$iteration" "$MODEL" "COMPLETE" "Criteria remain after agent completion signal" "loop" ""
          echo ""
          echo "⚠️  Agent signaled completion but unchecked criteria remain."
          echo "   Continuing with next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
      "ROTATE")
        if [[ "${RALPH_SESSION_SIGNAL:-NONE}" == "GUTTER" ]]; then
          log_progress "$workspace" "**Session $iteration ended** - 🔄 Fresh context after GUTTER"
          write_runtime_state "$workspace" "rotating" "$iteration" "$MODEL" "ROTATE" "Rotating after gutter" "loop" ""
          echo ""
          echo "🔄 Gutter detected. Rotating to fresh context..."
        else
          log_progress "$workspace" "**Session $iteration ended** - 🔄 Context rotation (token limit reached)"
          write_runtime_state "$workspace" "rotating" "$iteration" "$MODEL" "ROTATE" "Rotating to fresh context" "loop" ""
          echo ""
          echo "🔄 Rotating to fresh context..."
        fi
        iteration=$((iteration + 1))
        ;;
      "GUTTER")
        log_progress "$workspace" "**Session $iteration ended** - 🔄 Fresh context after GUTTER"
        append_signal_event "$workspace" "GUTTER" "Loop rotating after gutter detection" "loop" "$iteration"
        write_runtime_state "$workspace" "rotating" "$iteration" "$MODEL" "GUTTER" "Loop rotating after gutter detection" "loop" ""
        echo ""
        echo "🔄 Gutter detected. Rotating to fresh context..."
        echo "   Check .ralph/errors.log and .ralph/guardrails.md if the same issue repeats."
        iteration=$((iteration + 1))
        ;;
      "THRASH")
        log_progress "$workspace" "**Session $iteration ended** - 🚨 THRASH STOP (repeated rotate-without-progress)"
        log_error "$workspace" "🚨 THRASH STOP: Ralph halted after $thrash_rotation_streak rotate-without-progress iterations"
        append_signal_event "$workspace" "THRASH" "Loop halted after repeated rotate-without-progress sessions" "loop" "$iteration"
        write_runtime_state "$workspace" "thrash" "$iteration" "$MODEL" "THRASH" "Loop halted after repeated thrash rotations" "loop" ""
        RALPH_LOOP_FINAL_SIGNAL="THRASH"
        echo ""
        echo "🚨 Ralph detected repeated large-file reread thrash without meaningful progress."
        echo "   Check .ralph/errors.log for the rotate streak details, tighten the task scope,"
        echo "   and restart once the next concrete file/test target is clear."
        return 1
        ;;
      "DEFER")
        # Rate limit or transient error - wait with exponential backoff then retry
        log_progress "$workspace" "**Session $iteration ended** - ⏸️ DEFERRED (rate limit/transient error)"
        write_runtime_state "$workspace" "deferred" "$iteration" "$MODEL" "DEFER" "Waiting before retry" "loop" ""
        
        # Calculate backoff delay (uses ralph-retry.sh functions if available)
        local defer_delay=30
        if type calculate_backoff_delay &>/dev/null; then
          local defer_attempt=${DEFER_COUNT:-1}
          DEFER_COUNT=$((defer_attempt + 1))
          defer_delay=$(($(calculate_backoff_delay "$defer_attempt" 15 120 true) / 1000))
        fi
        
        echo ""
        echo "⏸️  Rate limit or transient error detected."
        echo "   Waiting ${defer_delay}s before retrying (attempt ${DEFER_COUNT:-1})..."
        sleep "$defer_delay"
        
        # Don't increment iteration - retry the same task
        echo "   Resuming..."
        ;;
      "ABORT")
        log_progress "$workspace" "**Session $iteration ended** - ❌ Agent launch/runtime failure"
        append_signal_event "$workspace" "ABORT" "Agent launch/runtime failure" "loop" "$iteration"
        write_runtime_state "$workspace" "error" "$iteration" "$MODEL" "ABORT" "Agent launch/runtime failure" "loop" ""
        RALPH_LOOP_FINAL_SIGNAL="ABORT"
        echo ""
        echo "❌ Ralph could not start or keep the agent running."
        echo "   Check .ralph/errors.log and .ralph/activity.log for the raw failure."
        return 1
        ;;
      *)
        # Agent finished naturally, check if more work needed
        if [[ "$task_status" == INCOMPLETE:* ]]; then
          local remaining_count=${task_status#INCOMPLETE:}
          log_progress "$workspace" "**Session $iteration ended** - Agent finished naturally ($remaining_count criteria remaining)"
          echo ""
          echo "📋 Agent finished but $remaining_count criteria remaining."
          echo "   Starting next iteration..."
          write_runtime_state "$workspace" "running" "$iteration" "$MODEL" "NONE" "Preparing next iteration" "loop" ""
          iteration=$((iteration + 1))
        fi
        ;;
    esac
    
    # Brief pause between iterations
    sleep 2
  done
  
  log_progress "$workspace" "**Loop ended** - ⚠️ Max iterations ($MAX_ITERATIONS) reached"
  append_signal_event "$workspace" "MAX_ITERATIONS" "Loop ended after $MAX_ITERATIONS iterations" "loop" "$MAX_ITERATIONS"
  write_runtime_state "$workspace" "idle" "$MAX_ITERATIONS" "$MODEL" "MAX_ITERATIONS" "Max iterations reached" "loop" ""
  RALPH_LOOP_FINAL_SIGNAL="MAX_ITERATIONS"
  echo ""
  echo "⚠️  Max iterations ($MAX_ITERATIONS) reached."
  echo "   Task may not be complete. Check progress manually."
  return 1
}

run_ralph_loop_with_recovery() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"
  local thrash_recovery_streak=0
  local total_restarts=0

  while true; do
    local head_before criteria_before done_before
    head_before=$(get_git_head)
    criteria_before=$(count_criteria "$workspace")
    done_before="${criteria_before%%:*}"
    DEFER_COUNT=0

    local loop_rc=0
    if run_ralph_loop "$workspace" "$script_dir"; then
      return 0
    else
      loop_rc=$?
    fi

    local final_signal="${RALPH_LOOP_FINAL_SIGNAL:-NONE}"
    local head_after criteria_after done_after
    head_after=$(get_git_head)
    criteria_after=$(count_criteria "$workspace")
    done_after="${criteria_after%%:*}"

    local progress_made=0
    if [[ "$head_before" != "$head_after" ]] || [[ "$done_after" -gt "$done_before" ]]; then
      progress_made=1
    fi

    if [[ "$final_signal" != "THRASH" ]] || [[ "${MAX_CONSECUTIVE_THRASH_RECOVERIES:-0}" -le 0 ]]; then
      return "$loop_rc"
    fi

    if [[ $progress_made -eq 1 ]]; then
      thrash_recovery_streak=0
    else
      thrash_recovery_streak=$((thrash_recovery_streak + 1))
    fi

    if [[ $thrash_recovery_streak -gt $MAX_CONSECUTIVE_THRASH_RECOVERIES ]]; then
      log_error "$workspace" "🚫 THRASH RECOVERY EXHAUSTED: ${thrash_recovery_streak} consecutive no-progress loop batches hit the limit (${MAX_CONSECUTIVE_THRASH_RECOVERIES})"
      append_signal_event "$workspace" "THRASH_RECOVERY_EXHAUSTED" "consecutive_no_progress=$thrash_recovery_streak limit=$MAX_CONSECUTIVE_THRASH_RECOVERIES" "loop" ""
      return "$loop_rc"
    fi

    total_restarts=$((total_restarts + 1))
    log_progress "$workspace" "**Loop restart** - 🔁 THRASH recovery ($total_restarts total restarts)"
    log_error "$workspace" "🔁 THRASH RECOVERY: restarting full loop after THRASH STOP (restart $total_restarts, progress_made=$progress_made, consecutive_no_progress=$thrash_recovery_streak/$MAX_CONSECUTIVE_THRASH_RECOVERIES)"
    append_signal_event "$workspace" "THRASH_RECOVERY" "restart=$total_restarts progress_made=$progress_made consecutive_no_progress=$thrash_recovery_streak limit=$MAX_CONSECUTIVE_THRASH_RECOVERIES" "loop" ""
    write_runtime_state "$workspace" "starting" "$(get_iteration "$workspace")" "$MODEL" "THRASH_RECOVERY" "Restarting loop after thrash stop" "loop" ""
    echo ""
    echo "🔁 Restarting Ralph with a fresh top-level loop after THRASH STOP."
    if [[ $progress_made -eq 1 ]]; then
      echo "   The previous loop batch still made progress, so the no-progress recovery streak has been reset."
    else
      echo "   Consecutive no-progress thrash batches: $thrash_recovery_streak / $MAX_CONSECUTIVE_THRASH_RECOVERIES"
    fi
    if [[ "${THRASH_RECOVERY_DELAY_SECONDS:-0}" -gt 0 ]]; then
      echo "   Waiting ${THRASH_RECOVERY_DELAY_SECONDS}s before restarting..."
      sleep "$THRASH_RECOVERY_DELAY_SECONDS"
    fi
  done
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# Check all prerequisites, exit with error message if any fail
check_prerequisites() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Check for task file
  if [[ ! -f "$task_file" ]]; then
    echo "❌ No RALPH_TASK.md found in $workspace"
    echo ""
    echo "Create a task file first:"
    echo "  cat > RALPH_TASK.md << 'EOF'"
    echo "  ---"
    echo "  task: Your task description"
    echo "  test_command: \"pnpm test\""
    echo "  ---"
    echo "  # Task"
    echo "  ## Success Criteria"
    echo "  1. [ ] First thing to do"
    echo "  2. [ ] Second thing to do"
    echo "  EOF"
    return 1
  fi
  
  # Check for git repo
  if ! git -C "$workspace" rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not a git repository"
    echo "   Ralph requires git for state persistence."
    return 1
  fi

  if ! validate_task_scaffolding "$workspace"; then
    return 1
  fi

  print_task_scaffolding_warnings "$workspace"

  # Check for cursor-agent CLI
  if ! command -v cursor-agent &> /dev/null; then
    echo "❌ cursor-agent CLI not found"
    echo ""
    echo "Install via:"
    echo "  curl https://cursor.com/install -fsS | bash"
    return 1
  fi
  
  return 0
}

# Check dashboard-specific prerequisites
check_dashboard_prerequisites() {
  local script_dir="${1:-$(dirname "${BASH_SOURCE[0]}")}"
  local python_bin="${PYTHON_BIN:-python3}"

  if ! command -v "$python_bin" &> /dev/null; then
    echo "❌ --dashboard requires $python_bin"
    return 1
  fi

  if ! "$python_bin" - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("textual") else 1)
PY
  then
    echo "❌ --dashboard requires the Python 'textual' package"
    echo "   Interpreter: $("$python_bin" - <<'PY'
import sys
print(sys.executable)
PY
)"
    echo "   Install via: $python_bin -m pip install textual"
    return 1
  fi

  if [[ ! -f "$script_dir/ralph-tui.py" ]]; then
    echo "❌ Dashboard launcher not found: $script_dir/ralph-tui.py"
    return 1
  fi

  return 0
}

# =============================================================================
# DISPLAY HELPERS
# =============================================================================

# Show task summary
show_task_summary() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  # Count criteria - only actual checkbox list items (- [ ], * [x], 1. [ ], etc.)
  local total_criteria done_criteria remaining
  total_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_criteria=0
  done_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_criteria=0
  remaining=$((total_criteria - done_criteria))
  
  echo "Progress: $done_criteria / $total_criteria criteria complete ($remaining remaining)"
  echo "Model:    $(format_requested_model_label "$MODEL")"
  echo ""
  
  # Return remaining count for caller to check
  echo "$remaining"
}

# Show Ralph banner
show_banner() {
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Autonomous Development Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  \"That's the beauty of Ralph - the technique is deterministically"
  echo "   bad in an undeterministic world.\""
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
}
