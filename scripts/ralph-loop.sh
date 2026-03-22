#!/bin/bash
# Ralph Wiggum: The Loop (CLI Mode)
#
# Runs cursor-agent locally with stream-json parsing for accurate token tracking.
# Handles context rotation via --resume when thresholds are hit.
#
# This script is for power users and scripting. For interactive use, see ralph-setup.sh.
#
# Usage:
#   ./ralph-loop.sh                              # Start from current directory
#   ./ralph-loop.sh /path/to/project             # Start from specific project
#   ./ralph-loop.sh -n 50 -m auto                # Custom iterations in auto mode
#   ./ralph-loop.sh --branch feature/foo --pr   # Create branch and PR
#   ./ralph-loop.sh -y                           # Skip confirmation (for scripting)
#
# Flags:
#   -n, --iterations N     Max iterations (default: 20)
#   -m, --model MODEL      Model to use (must be: auto)
#   --branch NAME          Sequential: create/work on branch; Parallel: integration branch name
#   --pr                   Sequential: open PR (requires --branch); Parallel: open ONE integration PR (branch optional)
#   --parallel             Run tasks in parallel with worktrees
#   --max-parallel N       Max parallel agents (default: 3)
#   --no-merge             Skip auto-merge in parallel mode
#   --dashboard            Run Ralph inside the fun monitoring dashboard
#   -y, --yes              Skip confirmation prompt
#   -h, --help             Show this help
#
# Requirements:
#   - RALPH_TASK.md in the project root
#   - Git repository
#   - cursor-agent CLI installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/ralph-common.sh"
source "$SCRIPT_DIR/task-parser.sh"

# Source parallel execution (if available)
if [[ -f "$SCRIPT_DIR/ralph-parallel.sh" ]]; then
  source "$SCRIPT_DIR/ralph-parallel.sh"
fi

# =============================================================================
# FLAG PARSING
# =============================================================================

show_help() {
  cat << 'EOF'
Ralph Wiggum: The Loop (CLI Mode)

Usage:
  ./ralph-loop.sh [options] [workspace]

Options:
  -n, --iterations N     Max iterations (default: 20)
  -m, --model MODEL      Model to use (must be: auto)
  --branch NAME          Sequential: create/work on branch; Parallel: integration branch name
  --pr                   Sequential: open PR (requires --branch); Parallel: open ONE integration PR (branch optional)
  --parallel             Run tasks in parallel with worktrees
  --max-parallel N       Max parallel agents (default: 3)
  --no-merge             Skip auto-merge in parallel mode
  --dashboard            Run Ralph inside the fun monitoring dashboard
  -y, --yes              Skip confirmation prompt
  -h, --help             Show this help

Examples:
  ./ralph-loop.sh                                    # Interactive mode
  ./ralph-loop.sh -n 50                              # 50 iterations max
  ./ralph-loop.sh -m auto                            # Explicitly request Cursor Auto
  ./ralph-loop.sh --branch feature/api --pr -y      # Scripted PR workflow
  ./ralph-loop.sh --parallel --max-parallel 4        # Run 4 agents in parallel
  ./ralph-loop.sh --dashboard -y                     # Launch with live dashboard
  
Environment:
  RALPH_MODEL            Override default model (must be: auto)
  MAX_CONSECUTIVE_THRASH_RECOVERIES
                         Auto-restart full loop after THRASH STOP (default: 2)
  THRASH_RECOVERY_DELAY_SECONDS
                         Pause before a fresh-loop restart (default: 3)

For interactive setup with a beautiful UI, use ralph-setup.sh instead.
EOF
}

# Parallel mode settings
PARALLEL_MODE=false
MAX_PARALLEL=3
SKIP_MERGE=false
DASHBOARD_MODE=false

# Parse command line arguments
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    -m|--model)
      MODEL="$2"
      shift 2
      ;;
    --branch)
      USE_BRANCH="$2"
      shift 2
      ;;
    --pr)
      OPEN_PR=true
      shift
      ;;
    --parallel)
      PARALLEL_MODE=true
      shift
      ;;
    --max-parallel)
      MAX_PARALLEL="$2"
      PARALLEL_MODE=true
      shift 2
      ;;
    --no-merge)
      SKIP_MERGE=true
      shift
      ;;
    --dashboard)
      DASHBOARD_MODE=true
      shift
      ;;
    -y|--yes)
      SKIP_CONFIRM=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      echo "Use -h for help."
      exit 1
      ;;
    *)
      # Positional argument = workspace
      WORKSPACE="$1"
      shift
      ;;
  esac
done

# =============================================================================
# MAIN
# =============================================================================

main() {
  # Resolve workspace
  if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE="$(pwd)"
  elif [[ "$WORKSPACE" == "." ]]; then
    WORKSPACE="$(pwd)"
  else
    WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  fi

  if ! require_auto_model "$MODEL"; then
    exit 1
  fi

  if [[ "$DASHBOARD_MODE" == "true" ]] && [[ "${RALPH_TUI_ACTIVE:-0}" != "1" ]]; then
    init_ralph_dir "$WORKSPACE"
    write_runtime_state "$WORKSPACE" "starting" "$(get_iteration "$WORKSPACE")" "$MODEL" "NONE" "Dashboard launching" "loop" ""
    local -a dashboard_args
    dashboard_args=(-n "$MAX_ITERATIONS" -m "$MODEL" -y)
    [[ -n "$USE_BRANCH" ]] && dashboard_args+=(--branch "$USE_BRANCH")
    [[ "$OPEN_PR" == "true" ]] && dashboard_args+=(--pr)
    if [[ "$PARALLEL_MODE" == "true" ]]; then
      dashboard_args+=(--parallel --max-parallel "$MAX_PARALLEL")
    fi
    [[ "$SKIP_MERGE" == "true" ]] && dashboard_args+=(--no-merge)
    dashboard_args+=("$WORKSPACE")
    if ! check_dashboard_prerequisites "$SCRIPT_DIR"; then
      exit 1
    fi
    exec "$SCRIPT_DIR/ralph-tui.py" loop --workspace "$WORKSPACE" -- "${dashboard_args[@]}"
  fi
  
  local task_file="$WORKSPACE/RALPH_TASK.md"
  
  # Show banner
  show_banner
  
  # Check prerequisites
  if ! check_prerequisites "$WORKSPACE"; then
    exit 1
  fi
  
  # Validate: PR requires branch (sequential mode only)
  if [[ "$PARALLEL_MODE" != "true" ]] && [[ "$OPEN_PR" == "true" ]] && [[ -z "$USE_BRANCH" ]]; then
    echo "❌ --pr requires --branch (sequential mode)"
    echo "   Example: ./ralph-loop.sh --branch feature/foo --pr"
    exit 1
  fi
  
  # Initialize .ralph directory
  init_ralph_dir "$WORKSPACE"
  
  echo "Workspace: $WORKSPACE"
  echo "Task:      $task_file"
  echo ""
  
  # Show task summary
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  # Count criteria
  local total_criteria done_criteria remaining
  # Only count actual checkbox list items (- [ ], * [x], 1. [ ], etc.)
  total_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_criteria=0
  done_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_criteria=0
  remaining=$((total_criteria - done_criteria))
  
  echo "Progress: $done_criteria / $total_criteria criteria complete ($remaining remaining)"
  echo "Model:    $(format_requested_model_label "$MODEL")"
  echo "Max iter: $MAX_ITERATIONS"
  [[ -n "$USE_BRANCH" ]] && echo "Branch:   $USE_BRANCH"
  [[ "$OPEN_PR" == "true" ]] && echo "Open PR:  Yes"
  [[ "$PARALLEL_MODE" == "true" ]] && echo "Parallel: Yes ($MAX_PARALLEL agents)"
  [[ "$SKIP_MERGE" == "true" ]] && echo "Merge:    Skipped"
  echo ""
  
  if [[ "$remaining" -eq 0 ]] && [[ "$total_criteria" -gt 0 ]]; then
    echo "🎉 Task already complete! All criteria are checked."
    exit 0
  fi
  
  # Confirm before starting (unless -y flag)
  if [[ "$SKIP_CONFIRM" != "true" ]]; then
    echo "This will run cursor-agent locally to work on this task."
    echo "The agent will be rotated when context fills up (~80k tokens)."
    echo ""
    echo "Tip: Use ralph-setup.sh for interactive model/option selection."
    echo "     Use -y flag to skip this prompt."
    echo ""
    read -p "Start Ralph loop? [y/N] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi
  
  # Run in parallel or sequential mode
  if [[ "$PARALLEL_MODE" == "true" ]]; then
    # Check if parallel functions are available
    if ! type run_parallel_tasks &>/dev/null; then
      echo "❌ Parallel execution not available (ralph-parallel.sh not found)"
      exit 1
    fi
    
    # Export settings for parallel execution
    export MODEL
    export SKIP_MERGE

    # Parallel PR behavior: one integration branch + one PR
    export CREATE_PR="$OPEN_PR"

    local base_branch
    base_branch="$(git -C "$WORKSPACE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

    # Args: workspace, max_parallel, base_branch, integration_branch(optional)
    run_parallel_tasks "$WORKSPACE" "$MAX_PARALLEL" "$base_branch" "$USE_BRANCH"
    exit $?
  else
    # Run the sequential loop
    run_ralph_loop_with_recovery "$WORKSPACE" "$SCRIPT_DIR"
    exit $?
  fi
}

main
