#!/bin/bash
# Ralph Wiggum: One-click installer
# Usage: curl -fsSL https://raw.githubusercontent.com/FX-991ES-Plus-C/cheap_ralph-wiggum-cursor/main/install.sh | bash

set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/FX-991ES-Plus-C/cheap_ralph-wiggum-cursor/main}"

echo "═══════════════════════════════════════════════════════════════════"
echo "🐛 Ralph Wiggum Installer"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for state persistence."
  echo ""
  echo "   Run: git init"
  echo ""
fi

# Check for cursor-agent CLI
if ! command -v cursor-agent &> /dev/null; then
  echo "⚠️  Warning: cursor-agent CLI not found."
  echo "   Install via: curl https://cursor.com/install -fsS | bash"
  echo ""
fi

# Check for gum and offer to install
if ! command -v gum &> /dev/null; then
  echo "📦 gum not found (provides beautiful CLI menus)"
  
  # Auto-install if INSTALL_GUM=1 or prompt user
  SHOULD_INSTALL=""
  if [[ "${INSTALL_GUM:-}" == "1" ]]; then
    SHOULD_INSTALL="y"
  elif [[ "${INSTALL_GUM:-}" == "0" ]]; then
    SHOULD_INSTALL="n"
  else
    read -p "   Install gum? [y/N] " -n 1 -r < /dev/tty
    echo
    SHOULD_INSTALL="$REPLY"
  fi
  
  if [[ "$SHOULD_INSTALL" =~ ^[Yy]$ ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      if command -v brew &> /dev/null; then
        echo "   Installing via Homebrew..."
        brew install gum
      else
        echo "   ⚠️  Homebrew not found. Install manually: brew install gum"
      fi
    elif [[ -f /etc/debian_version ]]; then
      echo "   Installing via apt..."
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
      echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
      sudo apt update && sudo apt install -y gum
    elif [[ -f /etc/fedora-release ]] || [[ -f /etc/redhat-release ]]; then
      echo "   Installing via dnf..."
      echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo
      sudo dnf install -y gum
    else
      echo "   ⚠️  Unknown Linux distro. Install manually: https://github.com/charmbracelet/gum#installation"
    fi
  fi
  echo ""
fi

# Check for Textual and offer to install
if command -v python3 &> /dev/null; then
  if ! python3 - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("textual") else 1)
PY
  then
    echo "📦 Python package 'textual' not found (powers the FUN dashboard)"

    SHOULD_INSTALL_TEXTUAL=""
    if [[ "${INSTALL_TEXTUAL:-}" == "1" ]]; then
      SHOULD_INSTALL_TEXTUAL="y"
    elif [[ "${INSTALL_TEXTUAL:-}" == "0" ]]; then
      SHOULD_INSTALL_TEXTUAL="n"
    else
      read -p "   Install textual with pip? [y/N] " -n 1 -r < /dev/tty
      echo
      SHOULD_INSTALL_TEXTUAL="$REPLY"
    fi

    if [[ "$SHOULD_INSTALL_TEXTUAL" =~ ^[Yy]$ ]]; then
      python3 -m pip install --user textual || echo "   ⚠️  Could not install textual automatically."
    fi
    echo ""
  fi
else
  echo "⚠️  python3 not found. The Textual dashboard requires python3 + textual."
  echo ""
fi

WORKSPACE_ROOT="$(pwd)"

write_file_if_missing() {
  local path="$1"

  if [[ -f "$path" ]]; then
    echo "✓ Preserved $path"
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  cat > "$path"
  echo "✓ Created $path"
}

# =============================================================================
# CREATE DIRECTORIES
# =============================================================================

echo "📁 Creating directories..."
mkdir -p .cursor/ralph-scripts
mkdir -p .ralph

# =============================================================================
# DOWNLOAD SCRIPTS
# =============================================================================

echo "📥 Downloading Ralph scripts..."

SCRIPTS=(
  "ralph-common.sh"
  "ralph-setup.sh"
  "ralph-loop.sh"
  "ralph-once.sh"
  "ralph-stop.sh"
  "ralph-parallel.sh"
  "ralph-tui.py"
  "stream-parser.sh"
  "task-parser.sh"
  "ralph-retry.sh"
  "init-ralph.sh"
)

for script in "${SCRIPTS[@]}"; do
  if curl -fsSL "$REPO_RAW/scripts/$script" -o ".cursor/ralph-scripts/$script" 2>/dev/null; then
    chmod +x ".cursor/ralph-scripts/$script"
  else
    echo "   ⚠️  Could not download $script (may not exist yet)"
  fi
done

echo "✓ Scripts installed to .cursor/ralph-scripts/"


# =============================================================================
# INITIALIZE .ralph/ STATE
# =============================================================================

echo "📁 Initializing .ralph/ state directory..."

write_file_if_missing .ralph/guardrails.md << 'EOF'
# Ralph Guardrails (Signs)

> Lessons learned from past failures. READ THESE BEFORE ACTING.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Always read the existing file first
- **Added after**: Core principle

### Sign: Test After Changes
- **Trigger**: After any code change
- **Instruction**: Run tests to verify nothing broke
- **Added after**: Core principle

### Sign: Commit Checkpoints
- **Trigger**: Before risky changes
- **Instruction**: Commit current working state first
- **Added after**: Core principle

---

## Learned Signs

(Signs added from observed failures will appear below)

EOF

write_file_if_missing .ralph/progress.md << 'EOF'
# Progress Log

> Updated by the agent after significant work.

## Summary

- Iterations completed: 0
- Current status: Initialized

## How This Works

Progress is tracked in THIS FILE, not in LLM context.
When context is rotated (fresh agent), the new agent reads this file.
This is how Ralph maintains continuity across iterations.

## Session History

EOF

write_file_if_missing .ralph/errors.log << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF

write_file_if_missing .ralph/activity.log << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF

write_file_if_missing .ralph/signals.log << 'EOF'
# Signal Log

> Durable signal/event history for the Ralph dashboard.

EOF

write_file_if_missing .ralph/session-brief.md << 'EOF'
# Ralph Session Brief

> Auto-generated before each iteration. Read this first.

- Generated: not yet
- Criteria: 0 / 0 complete
- Next unchecked criterion: unknown
- Read strategy: open the relevant slice of `RALPH_TASK.md`, not the whole repo.

EOF

write_file_if_missing .ralph/runtime.env << 'EOF'
# Ralph runtime state
RALPH_RUNTIME_STATUS=idle
RALPH_RUNTIME_ITERATION=0
RALPH_RUNTIME_MODEL=auto
RALPH_RUNTIME_LAST_SIGNAL=NONE
RALPH_RUNTIME_LAST_EVENT=Waiting\ for\ Ralph
RALPH_RUNTIME_MODE=loop
RALPH_RUNTIME_AGENT_PID=''
RALPH_RUNTIME_UPDATED_AT=not\ yet
EOF

if [[ ! -f .ralph/.iteration ]]; then
  echo "0" > .ralph/.iteration
  echo "✓ Created .ralph/.iteration"
else
  echo "✓ Preserved .ralph/.iteration"
fi

echo "✓ .ralph/ upgrade complete"

# =============================================================================
# CREATE RALPH_TASK.md TEMPLATE
# =============================================================================

if [[ ! -f "RALPH_TASK.md" ]]; then
  echo "📝 Creating RALPH_TASK.md template..."
  cat > RALPH_TASK.md <<'TASKEOF'
---
task: Build a CLI todo app in TypeScript
test_command: "npx ts-node todo.ts list"
---

# Task: CLI Todo App (TypeScript)

Build a simple command-line todo application in TypeScript.

## Requirements

1. Single file: `todo.ts`
2. Uses `todos.json` for persistence
3. Three commands: add, list, done
4. TypeScript with proper types

## Success Criteria

1. [ ] `npx ts-node todo.ts add "Buy milk"` adds a todo and confirms
2. [ ] `npx ts-node todo.ts list` shows all todos with IDs and status
3. [ ] `npx ts-node todo.ts done 1` marks todo 1 as complete
4. [ ] Todos survive script restart (JSON persistence)
5. [ ] Invalid commands show helpful usage message
6. [ ] Code has proper TypeScript types (no `any`)

## Example Output

```
$ npx ts-node todo.ts add "Buy milk"
✓ Added: "Buy milk" (id: 1)

$ npx ts-node todo.ts list
1. [ ] Buy milk

$ npx ts-node todo.ts done 1
✓ Completed: "Buy milk"
```

---

## Ralph Instructions

1. Work on the next incomplete criterion (marked [ ])
2. Check off completed criteria (change [ ] to [x])
3. Run tests after changes
4. Commit your changes frequently
5. When ALL criteria are [x], output: `<ralph>COMPLETE</ralph>`
6. If stuck on the same issue 3+ times, output: `<ralph>GUTTER</ralph>`
TASKEOF
  echo "✓ Created RALPH_TASK.md with example task"
else
  echo "✓ Preserved RALPH_TASK.md"
fi

# =============================================================================
# UPDATE .gitignore
# =============================================================================

if [[ -f ".gitignore" ]]; then
  if ! grep -q "ralph-config.json" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Ralph config (may contain API key)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
else
  cat > .gitignore <<'EOF'
# Ralph config (may contain API key)
.cursor/ralph-config.json
EOF
fi
echo "✓ Updated .gitignore"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✅ Ralph installed!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Files created:"
echo ""
echo "  📁 .cursor/ralph-scripts/"
echo "     ├── ralph-setup.sh          - Main entry (interactive)"
echo "     ├── ralph-loop.sh           - CLI mode (for scripting)"
echo "     ├── ralph-once.sh           - Single iteration (testing)"
echo "     └── ...                     - Other utilities"
echo ""
echo "  📁 .ralph/                     - State files (tracked in git)"
echo "     ├── guardrails.md           - Lessons learned"
echo "     ├── progress.md             - Progress log"
echo "     ├── activity.log            - Tool call log"
echo "     └── errors.log              - Failure log"
echo ""
echo "  📄 RALPH_TASK.md               - Your task definition (edit this!)"
echo ""
echo "Next steps:"
echo "  1. Edit RALPH_TASK.md to define your actual task"
echo "  2. Run: ./.cursor/ralph-scripts/ralph-setup.sh"
echo ""
echo "Alternative commands:"
echo "  • ralph-once.sh    - Test with single iteration first"
echo "  • ralph-loop.sh    - CLI mode with flags (for scripting)"
echo ""
echo "Monitor progress:"
echo "  tail -f .ralph/activity.log"
echo ""
echo "Learn more: https://ghuntley.com/ralph/"
echo "═══════════════════════════════════════════════════════════════════"
