#!/bin/bash
# Ralph Wiggum: Single Iteration (Human-in-the-Loop)
#
# Runs exactly ONE iteration of the Ralph loop, then stops.
# Useful for testing your task definition before going AFK.
#
# Usage:
#   ./ralph-once.sh                    # Run single iteration
#   ./ralph-once.sh /path/to/project   # Run in specific project
#   ./ralph-once.sh -m auto            # Explicitly request backend auto mode
#   ./ralph-once.sh --agent-backend qwen
#
# After running:
#   - Review the changes made
#   - Check git log for commits
#   - If satisfied, run ralph-setup.sh or ralph-loop.sh for full loop
#
# Requirements:
#   - RALPH_TASK.md in the project root
#   - Git repository
#   - supported agent CLI installed (`cursor-agent` or `qwen`)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# FLAG PARSING
# =============================================================================

show_help() {
  cat << 'EOF'
Ralph Wiggum: Single Iteration (Human-in-the-Loop)

Runs exactly ONE iteration, then stops for review.
This is the recommended way to test your task definition.

Usage:
  ./ralph-once.sh [options] [workspace]

Options:
  -m, --model MODEL      Model to use (must be: auto)
  --agent-backend NAME   Agent backend to use: cursor or qwen
  -h, --help             Show this help

Examples:
  ./ralph-once.sh                        # Run one iteration
  ./ralph-once.sh -m auto               # Explicitly request backend auto mode
  ./ralph-once.sh --agent-backend qwen  # Run one iteration with Qwen
  
After reviewing the results:
  - If satisfied: run ./ralph-setup.sh for full loop
  - If issues: fix them, update RALPH_TASK.md or guardrails, run again
EOF
}

# Parse command line arguments
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)
      MODEL="$2"
      shift 2
      ;;
    --agent-backend)
      AGENT_BACKEND="$2"
      shift 2
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

  if ! require_supported_backend "${AGENT_BACKEND:-$DEFAULT_AGENT_BACKEND}"; then
    exit 1
  fi

  if ! require_auto_model "$MODEL"; then
    exit 1
  fi
  
  local task_file="$WORKSPACE/RALPH_TASK.md"
  
  # Show banner
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Single Iteration (Human-in-the-Loop)"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  This runs ONE iteration, then stops for your review."
  echo "  Use this to test your task before going AFK."
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  
  # Check prerequisites
  if ! check_prerequisites "$WORKSPACE"; then
    exit 1
  fi
  
  # Initialize .ralph directory
  init_ralph_dir "$WORKSPACE"
  
  echo "Workspace: $WORKSPACE"
  echo "Backend:   $(format_backend_label "$AGENT_BACKEND")"
  echo "Model:     $(format_requested_model_label "$MODEL")"
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
  echo ""
  
  if [[ "$remaining" -eq 0 ]] && [[ "$total_criteria" -gt 0 ]]; then
    echo "🎉 Task already complete! All criteria are checked."
    exit 0
  fi
  
  # Confirm
  read -p "Run single iteration? [Y/n] " -n 1 -r
  echo ""
  
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 0
  fi

  # Prevent overlapping sequential Ralph runs in the same workspace
  if ! acquire_sequential_lock "$WORKSPACE"; then
    exit 1
  fi
  
  # Commit any uncommitted work first
  cd "$WORKSPACE"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: checkpoint before single iteration" || true
  fi
  
  echo ""
  echo "🚀 Running single iteration..."
  echo ""
  
  # Run exactly one iteration
  local signal
  signal=$(run_iteration "$WORKSPACE" "1" "$SCRIPT_DIR")
  
  # Check result
  local task_status
  task_status=$(check_task_complete "$WORKSPACE")
  local final_status="idle"
  local final_signal="${signal:-NONE}"
  local final_event="Single iteration finished"

  case "$signal" in
    "COMPLETE")
      if [[ "$task_status" == "COMPLETE" ]]; then
        final_status="complete"
        final_event="All criteria satisfied in single iteration"
      else
        final_status="idle"
        final_event="Criteria remain after agent completion signal"
      fi
      ;;
    "GUTTER")
      final_status="gutter"
      final_event="Agent got stuck during single iteration"
      ;;
    "ROTATE")
      final_status="idle"
      final_event="Context rotation triggered; review before rerun"
      ;;
    "DEFER")
      final_status="idle"
      final_event="Transient failure deferred; rerun to retry"
      ;;
    "ABORT")
      final_status="error"
      final_event="Agent launch/runtime failure"
      ;;
    *)
      if [[ "$task_status" == "COMPLETE" ]]; then
        final_status="complete"
        final_signal="COMPLETE"
        final_event="All criteria satisfied in single iteration"
      else
        final_status="idle"
        final_signal="NONE"
        final_event="Single iteration finished with criteria remaining"
      fi
      ;;
  esac
  write_runtime_state "$WORKSPACE" "$final_status" "1" "$MODEL" "$final_signal" "$final_event" "once" ""
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "📋 Single Iteration Complete"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  
  case "$signal" in
    "COMPLETE")
      if [[ "$task_status" == "COMPLETE" ]]; then
        echo "🎉 Task completed in single iteration!"
        echo ""
        echo "All criteria are checked. You're done!"
      else
        echo "⚠️  Agent signaled complete but some criteria remain unchecked."
        echo "   Review the results and run again if needed."
      fi
      ;;
    "GUTTER")
      echo "🚨 Gutter detected - agent got stuck."
      echo ""
      echo "Review .ralph/errors.log and consider:"
      echo "  1. Adding a guardrail to .ralph/guardrails.md"
      echo "  2. Simplifying the task"
      echo "  3. Fixing the blocking issue manually"
      ;;
    "ROTATE")
      echo "🔄 Context rotation was triggered."
      echo ""
      echo "The agent used a lot of context. This is normal for complex tasks."
      echo "Review the progress and run again or proceed to full loop."
      ;;
    "DEFER")
      echo "⏸️  A transient error interrupted the iteration."
      echo ""
      echo "Review .ralph/errors.log, then rerun when the dependency or rate limit clears."
      ;;
    "ABORT")
      echo "❌ Ralph hit a non-retryable agent failure."
      echo ""
      echo "Review .ralph/errors.log and .ralph/activity.log before rerunning."
      ;;
    *)
      if [[ "$task_status" == "COMPLETE" ]]; then
        echo "🎉 Task completed in single iteration!"
      else
        local remaining_count=${task_status#INCOMPLETE:}
        echo "Agent finished with $remaining_count criteria remaining."
      fi
      ;;
  esac
  
  echo ""
  echo "Review the changes:"
  echo "  • git log --oneline -5     # See recent commits"
  echo "  • git diff HEAD~1          # See changes"
  echo "  • cat .ralph/progress.md   # See progress log"
  echo ""
  echo "Next steps:"
  echo "  • If satisfied: ./ralph-setup.sh  # Run full loop"
  echo "  • If issues: fix, update task/guardrails, ./ralph-once.sh again"
  echo ""
}

main
