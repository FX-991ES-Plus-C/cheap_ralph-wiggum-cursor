#!/bin/bash
# Ralph Wiggum: Initialize Ralph in a project
# Sets up Ralph tracking for CLI mode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

echo "═══════════════════════════════════════════════════════════════════"
echo "🐛 Ralph Wiggum Initialization"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for state persistence."
  echo ""
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Check for supported agent CLIs
if ! command -v cursor-agent &> /dev/null && ! command -v qwen &> /dev/null; then
  echo "⚠️  Warning: no supported agent CLI found."
  echo "   Install Cursor via: curl https://cursor.com/install -fsS | bash"
  echo "   Install Qwen via: https://qwenlm.github.io/qwen-code-docs/en/getting-started/install/"
  echo ""
fi

# Create directories
mkdir -p .ralph
mkdir -p .cursor/ralph-scripts

# =============================================================================
# CREATE RALPH_TASK.md IF NOT EXISTS
# =============================================================================

if [[ ! -f "RALPH_TASK.md" ]]; then
  echo "📝 Creating RALPH_TASK.md template..."
  if [[ -f "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md" ]]; then
    cp "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md" RALPH_TASK.md
  else
    cat > RALPH_TASK.md << 'EOF'
---
task: Your task description here
test_command: "pnpm test"
---

# Task

Describe what you want to accomplish.

## Success Criteria

1. [ ] First concrete, verifiable thing to complete
2. [ ] Second concrete, verifiable thing to complete
3. [ ] Third concrete, verifiable thing to complete

## Context

Any additional context the agent should know.

## Scaffolding Notes

- Ralph only tracks the checkbox list under `## Success Criteria`
- Keep each checkbox to one outcome you can verify with a command or observable result
- Put manual approval/browser/deploy steps here in notes, not in the tracked checklist
EOF
  fi
  echo "   Edit RALPH_TASK.md to define your task."
else
  echo "✓ RALPH_TASK.md already exists"
fi

# =============================================================================
# INITIALIZE STATE FILES
# =============================================================================

echo "📁 Initializing .ralph/ directory..."

cat > .ralph/guardrails.md << 'EOF'
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

(Signs added from observed failures will appear below)

EOF

cat > .ralph/progress.md << 'EOF'
<!-- RALPH_COMPACT_KEEP_START -->
# Progress Log

> Updated by the agent after significant work.

## Summary

- Iterations completed: 0
- Current status: Initialized

## How This Works

Progress is tracked in THIS FILE, not in LLM context.
When context is rotated (fresh agent), the new agent reads this file.
This is how Ralph maintains continuity across iterations.
Historical detail may be auto-rotated to `.ralph/archive/` during long runs.
<!-- RALPH_COMPACT_KEEP_END -->

## Session History

EOF

cat > .ralph/errors.log << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF

cat > .ralph/activity.log << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF

cat > .ralph/signals.log << 'EOF'
# Signal Log

> Durable signal/event history for the Ralph dashboard.

EOF

cat > .ralph/session-brief.md << 'EOF'
# Ralph Session Brief

> Auto-generated before each iteration. Read this first.

- Generated: not yet
- Criteria: 0 / 0 complete
- Next unchecked criterion: unknown
- Read strategy: open the relevant slice of `RALPH_TASK.md`, not the whole repo.
- Discovery strategy: shortlist files with `rg --files | rg` or `find`, then `rg -n`, then bounded `sed -n` windows.

EOF

cat > .ralph/navigation-brief.md << 'EOF'
# Ralph Navigation Brief

> Auto-generated before each iteration when Ralph needs a tighter map through a large file.

- Generated: not yet
- Last session signal: NONE
- Forced narrow mode: standby
- Current hot file: not yet identified
- Search-first workflow: shortlist files, grep for task words, then read one bounded slice at a time.

EOF

printf 'timestamp\titeration\tpath\tbytes\tlines\tper_file_reads\twrite_calls_before_read\tthrash_hit\n' > .ralph/read-trace.tsv
printf 'timestamp\titeration\texit_code\tstatus\tpath\tbefore_bytes\tafter_bytes\twork_path\tcommand\n' > .ralph/shell-edit-trace.tsv

cat > .ralph/runtime.env << 'EOF'
# Ralph runtime state
RALPH_RUNTIME_STATUS=idle
RALPH_RUNTIME_ITERATION=0
RALPH_RUNTIME_BACKEND=cursor
RALPH_RUNTIME_MODEL=auto
RALPH_RUNTIME_LAST_SIGNAL=NONE
RALPH_RUNTIME_LAST_EVENT=Waiting\ for\ Ralph
RALPH_RUNTIME_MODE=loop
RALPH_RUNTIME_AGENT_PID=''
RALPH_RUNTIME_UPDATED_AT=not\ yet
EOF

echo "0" > .ralph/.iteration

# =============================================================================
# INSTALL SCRIPTS
# =============================================================================

echo "📦 Installing scripts..."

# Copy scripts
cp "$SKILL_DIR/scripts/"*.sh .cursor/ralph-scripts/ 2>/dev/null || true
cp "$SKILL_DIR/scripts/"*.py .cursor/ralph-scripts/ 2>/dev/null || true
chmod +x .cursor/ralph-scripts/*.sh 2>/dev/null || true
chmod +x .cursor/ralph-scripts/*.py 2>/dev/null || true

echo "✓ Scripts installed to .cursor/ralph-scripts/"

# =============================================================================
# UPDATE .gitignore
# =============================================================================

if [[ -f ".gitignore" ]]; then
  # Don't gitignore .ralph/ - we want it tracked for state persistence
  if ! grep -q "ralph-config.json" .gitignore; then
    echo "" >> .gitignore
    echo "# Ralph config (may contain API keys)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
  echo "✓ Updated .gitignore"
else
  cat > .gitignore << 'EOF'
# Ralph config (may contain API keys)
.cursor/ralph-config.json
EOF
  echo "✓ Created .gitignore"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✅ Ralph initialized!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Files created:"
echo "  • RALPH_TASK.md        - Define your task here"
echo "  • .ralph/session-brief.md - Auto-generated restart brief (agent reads this first)"
echo "  • .ralph/navigation-brief.md - Hot-file navigation plan for the next iteration"
echo "  • .ralph/guardrails.md - Lessons learned (agent updates this)"
echo "  • .ralph/progress.md   - Progress log (agent updates this)"
echo "  • .ralph/activity.log  - Tool call log (parser updates this)"
echo "  • .ralph/read-trace.tsv - Large-read ledger for hotspot detection"
echo "  • .ralph/shell-edit-trace.tsv - Shell mutation ledger for partial edits"
echo "  • .ralph/signals.log   - Signal/event history (dashboard reads this)"
echo "  • .ralph/errors.log    - Failure log (parser updates this)"
echo ""
echo "Next steps:"
echo "  1. Edit RALPH_TASK.md to define your task and criteria"
echo "  2. Run: ./scripts/ralph-loop.sh"
echo "     (or: .cursor/ralph-scripts/ralph-loop.sh)"
echo ""
echo "The agent will work autonomously, rotating context as needed."
echo "Monitor progress: tail -f .ralph/activity.log"
echo ""
echo "Learn more: https://ghuntley.com/ralph/"
echo "═══════════════════════════════════════════════════════════════════"
