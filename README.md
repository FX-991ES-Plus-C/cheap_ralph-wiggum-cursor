# Ralph Wiggum for Cursor and Qwen

An implementation of [Geoffrey Huntley's Ralph Wiggum technique](https://ghuntley.com/ralph/) for headless agent CLIs such as Cursor and Qwen, enabling autonomous AI development with deliberate context management and stronger scaffolding for weaker, cheaper models.

> "That's the beauty of Ralph - the technique is deterministically bad in an undeterministic world."

## What is Ralph?

Ralph is a technique for autonomous AI development that treats LLM context like memory:

```bash
while :; do cat PROMPT.md | agent ; done
```

The same prompt is fed repeatedly to an AI agent. Progress persists in **files and git**, not in the LLM's context window. When context fills up, you get a fresh agent with fresh context.

### The malloc/free Problem

In traditional programming:
- `malloc()` allocates memory
- `free()` releases memory

In LLM context:
- Reading files, tool outputs, conversation = `malloc()`
- **There is no `free()`** - context cannot be selectively released
- Only way to free: start a new conversation

This creates two problems:

1. **Context pollution** - Failed attempts, unrelated code, and mixed concerns accumulate and confuse the model
2. **The gutter** - Once polluted, the model keeps referencing bad context. Like a bowling ball in the gutter, there's no saving it.

**Ralph's solution:** Deliberately rotate to fresh context before pollution builds up. State lives in files and git, not in the LLM's memory.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      ralph-setup.sh                          │
│                           │                                  │
│              ┌────────────┴────────────┐                    │
│              ▼                         ▼                    │
│         [gum UI]                  [fallback]                │
│  Backend + model selection     Simple prompts               │
│     Max iterations                                          │
│     Options (branch, PR)                                    │
│              │                         │                    │
│              └────────────┬────────────┘                    │
│                           ▼                                  │
│  cursor-agent / qwen --output-format stream-json             │
│                           │                                  │
│                           ▼                                  │
│                 agent-normalizer.sh                          │
│                           │                                  │
│                           ▼                                  │
│                   stream-parser.sh                           │
│                      │        │                              │
│     ┌────────────────┴────────┴────────────────┐            │
│     ▼                                           ▼            │
│  .ralph/                                    Signals          │
│  ├── session-brief.md (restart brief)      ├── WARN at 170k │
│  ├── activity.log     (tool calls)         ├── ROTATE at 200k│
│  ├── errors.log       (failures)           ├── COMPLETE     │
│  ├── progress.md      (compact live state) ├── GUTTER       │
│  ├── guardrails.md    (lessons learned)    ├── DEFER        │
│  └── tasks.yaml       (cached task state)  └── THRASH STOP  │
│                                                              │
│  When ROTATE → fresh context, continue from git             │
│  When DEFER → exponential backoff, retry same task          │
└─────────────────────────────────────────────────────────────┘
```

**Key features:**
- **Interactive setup** - Beautiful gum-based UI for backend selection, model mode, and options
- **FUN live dashboard** - Lightweight fullscreen TUI for activity, progress, tasks, errors, and signal history
- **Cheap-model handoff** - Auto-generates `.ralph/session-brief.md` so each new iteration starts from a curated working set instead of rediscovering context
- **Smarter token tracking** - Parser weights reads, writes, assistant output, shell output, and tool-call overhead instead of using a flat chars/4 guess
- **Shell edit detection** - Partial shell mutations like `sed -i`, `perl -0pi`, and here-doc rewrites are traced into session metrics
- **Anti-thrash detection** - Detects when the agent is stuck on repeated failures, write-thrashing, or repeated large-file rereads
- **Self-managing continuity** - Compacts live progress/activity logs and archives history so long runs stay restartable
- **Rate limit handling** - Detects rate limits/network errors, waits with exponential backoff
- **Task caching** - YAML backend with mtime invalidation for efficient task parsing
- **Learning from failures** - Agent updates `.ralph/guardrails.md` with lessons
- **State in git** - Commits frequently so next agent picks up from git history
- **Sequential run locking** - Prevents overlapping Ralph loops from stepping on the same workspace
- **Branch/PR workflow** - Optionally work on a branch and open PR when complete

## Why This Works Better with Cheap Models

The original Ralph idea assumes the model can reconstruct missing context cheaply. In practice, weaker models often burn most of their budget rereading large files and rebuilding the same mental state.

This version makes restart state explicit and portable:
- `session-brief.md` carries forward the current target, recent findings, dirty files, and large-file cautions
- `progress.md` stays compact while detailed history is rotated into `.ralph/archive/`
- the parser stops obvious reread loops before they become multi-iteration spirals
- file discovery is repo-agnostic, so the same scaffolding works across very different codebases

## Prerequisites

| Requirement | Check | How to Set Up |
|-------------|-------|---------------|
| **Git repo** | `git status` works | `git init` |
| **Supported agent CLI** | `which cursor-agent` or `which qwen` | Cursor: `curl https://cursor.com/install -fsS \| bash` or Qwen: [install docs](https://qwenlm.github.io/qwen-code-docs/en/getting-started/install/) |
| **gum** (optional) | `which gum` | Installer offers to install, or `brew install gum` |
| **python3 + textual** (dashboard only) | `python3 -c "import textual"` | Installer offers to install, or `python3 -m pip install textual` |

## Quick Start

### 1. Install Ralph

```bash
cd your-project
curl -fsSL https://raw.githubusercontent.com/FX-991ES-Plus-C/cheap_ralph-wiggum-cursor/main/install.sh | bash
```

This creates:
```
your-project/
├── .cursor/ralph-scripts/      # Ralph scripts
│   ├── ralph-setup.sh          # Main entry point (interactive)
│   ├── ralph-loop.sh           # CLI mode (for scripting)
│   ├── ralph-once.sh           # Single iteration (testing)
│   ├── ralph-tui.py            # Textual live dashboard / monitor
│   ├── ralph-parallel.sh       # Parallel execution with worktrees
│   ├── agent-normalizer.sh     # Backend event normalization
│   ├── stream-parser.sh        # Token tracking + error detection
│   ├── ralph-common.sh         # Shared functions
│   ├── ralph-retry.sh          # Exponential backoff retry logic
│   ├── task-parser.sh          # YAML-backed task parsing
│   └── init-ralph.sh           # Re-initialize if needed
├── .ralph/                     # State files (tracked in git)
│   ├── session-brief.md        # Auto-generated restart brief (agent reads first)
│   ├── progress.md             # Agent updates: what's done
│   ├── guardrails.md           # Lessons learned (Signs)
│   ├── activity.log            # Tool call log (parser writes)
│   ├── signals.log             # Durable WARN/ROTATE/GUTTER/etc history
│   ├── errors.log              # Failure log (parser writes)
│   └── tasks.yaml              # Cached task state (auto-generated)
├── .ralph-worktrees/           # Temporary (parallel mode only)
└── RALPH_TASK.md               # Your task definition
```

You can rerun the installer later to upgrade the Ralph scripts. Existing `.ralph/` state and `RALPH_TASK.md` are preserved; only missing state files are created.

### 2. (Optional) gum for Enhanced UI

The installer will offer to install gum automatically. You can also:
- Skip the prompt and auto-install: `curl ... | INSTALL_GUM=1 bash`
- Install manually: `brew install gum` (macOS) or see [gum installation](https://github.com/charmbracelet/gum#installation)

With gum, you get a beautiful interactive menu for backend selection, iterations, and options. Ralph is intentionally locked to backend-default `auto` mode:

```
? Agent backend: cursor
? Max iterations: 20

? Options:
  ◯ Commit to current branch
  ◯ Run single iteration first
  ◯ Work on new branch
  ◯ Open PR when complete
  ◯ Run in parallel mode         ← runs multiple agents concurrently
```

If you select "Run in parallel mode", you'll be prompted for:

```
? Max parallel agents: 3         ← default is 3, enter any number
```

Without gum, Ralph falls back to simple numbered prompts.

### 2b. (Optional) Textual for the Dashboard

The installer will offer to install `textual` automatically when `python3` is available. You can also install it manually:

```bash
python3 -m pip install textual
```

### 3. Define Your Task

Edit `RALPH_TASK.md`:

```markdown
---
task: Build a REST API
test_command: "pnpm test"
---

# Task: REST API

Build a REST API with user management.

## Success Criteria

1. [ ] GET /health returns 200
2. [ ] POST /users creates a user  
3. [ ] GET /users/:id returns user
4. [ ] All tests pass

## Context

- Use Express.js
- Store users in memory (no database needed)
```

**Important:** Use `[ ]` checkboxes. Ralph tracks completion by counting unchecked boxes.
The checkbox list under `## Success Criteria` is the source of truth Ralph tracks.
Keep each checkbox atomic and objectively verifiable, and keep manual approval/browser/deploy steps out of the tracked checklist.

### 4. Start the Loop

```bash
./.cursor/ralph-scripts/ralph-setup.sh
```

Ralph will:
1. Show interactive UI for backend, model mode, and options (or simple prompts if gum not installed)
2. Run the selected agent backend with your task
3. Parse output in real-time, tracking token usage
4. Generate `.ralph/session-brief.md` before each iteration so the next agent starts from a curated handoff
5. At 170k tokens: warn agent to wrap up current work
6. At 200k tokens: rotate to fresh context
7. Repeat until all `[ ]` are `[x]` (or max iterations reached)

### 4b. Run with the Dashboard

```bash
./.cursor/ralph-scripts/ralph-loop.sh --dashboard -y
```

This opens the Textual dashboard with:
- a dense cockpit header tuned for wide laptop terminals
- mission control that folds task progress into the top-line run summary plus live agent I/O telemetry from `.ralph/.last-session.env`
- a feedback radar that shows the latest pulse from activity, progress, tasks, signals, errors, and console at the same time
- automatic split view on roomy terminals so the main pane and a live buddy pane stay visible together
- a Frogmouth-style command bar for quick navigation and pane search
- a side rail for watch sources, checklist items, and recent signal jumps
- `1` `activity.log`
- `2` `progress.md`
- `3` `RALPH_TASK.md` / `ralph-tasks.md`
- `4` `signals.log`
- `5` `errors.log`
- `6` dashboard console log
- `tab` / `shift+tab` to cycle panes
- `/` or `:` to focus the command bar
- `ctrl+n` to toggle the side rail
- `F1` for the full operator help screen
- `up/down`, `j/k`, `pgup/pgdn`, `g/G` to scroll
- `?` to toggle the inline help
- `x` to stop a dashboard-launched Ralph loop

It reads durable state from `.ralph/runtime.env`, `.ralph/signals.log`, and `.ralph/.last-session.env`, so WARN / ROTATE / GUTTER / COMPLETE / DEFER stay connected to the UI.

### 5. Monitor Progress

```bash
# Watch activity in real-time
tail -f .ralph/activity.log

# Watch signal history in real-time
tail -f .ralph/signals.log

# Example output:
# [12:34:56] 🟢 READ src/index.ts (245 lines, ~24.5KB)
# [12:34:58] 🟢 WRITE src/routes/users.ts (50 lines, 2.1KB)
# [12:35:01] 🟢 SHELL pnpm test → exit 0
# [12:35:10] 🟢 TOKENS: 111,230 / 200,000 (56%) [read:30KB write:5KB assist:10KB shell:0KB]

# Check for failures
cat .ralph/errors.log
```

## Commands

| Command | Description |
|---------|-------------|
| `ralph-setup.sh` | **Primary** - Interactive setup + run loop |
| `ralph-once.sh` | Test single iteration before going AFK |
| `ralph-loop.sh` | CLI mode for scripting (see flags below) |
| `init-ralph.sh` | Re-initialize Ralph state |

### ralph-loop.sh Flags (for scripting/CI)

```bash
./ralph-loop.sh [options] [workspace]

Options:
  -n, --iterations N     Max iterations (default: 20)
  -m, --model MODEL      Model to use (must be: auto)
  --agent-backend NAME   Agent backend to use: cursor or qwen
  --branch NAME          Sequential: create/work on branch; Parallel: integration branch name
  --pr                   Sequential: open PR (requires --branch); Parallel: open ONE integration PR (branch optional)
  --parallel             Run tasks in parallel with worktrees
  --max-parallel N       Max parallel agents (default: 3)
  --no-merge             Skip auto-merge in parallel mode
  -y, --yes              Skip confirmation prompt
```

**Examples:**

```bash
# Scripted PR workflow
./ralph-loop.sh --branch feature/api --pr -y

# Explicitly request backend auto mode with more iterations
./ralph-loop.sh -n 50 -m auto

# Run Ralph with Qwen
./ralph-loop.sh --agent-backend qwen -y

# Run 4 agents in parallel
./ralph-loop.sh --parallel --max-parallel 4

# Parallel: keep branches separate
./ralph-loop.sh --parallel --no-merge

# Parallel: merge into an integration branch + open ONE PR
./ralph-loop.sh --parallel --max-parallel 5 --branch feature/multi-task --pr

# Parallel: open ONE PR using an auto-named integration branch
./ralph-loop.sh --parallel --max-parallel 5 --pr
```

## Parallel Execution

Ralph can run multiple agents concurrently, each in an isolated git worktree.

### Starting Parallel Mode

**Via gum UI (interactive):**
```bash
./ralph-setup.sh
# Select "Run in parallel mode" in options
# Enter number of agents when prompted (default: 3, no upper limit)
```

**Via CLI (scripting/CI):**
```bash
# Run 3 agents in parallel (default)
./ralph-loop.sh --parallel

# Run 10 agents in parallel (no hard cap)
./ralph-loop.sh --parallel --max-parallel 10

# Keep branches separate (no auto-merge)
./ralph-loop.sh --parallel --no-merge

# Merge into an integration branch (no PR)
./ralph-loop.sh --parallel --max-parallel 5 --branch feature/multi-task

# Merge into an integration branch and open ONE PR
./ralph-loop.sh --parallel --max-parallel 5 --branch feature/multi-task --pr

# Open ONE PR using an auto-named integration branch
./ralph-loop.sh --parallel --max-parallel 5 --pr
```

> **Note:** There's no hard limit on `--max-parallel`. The practical limit depends on your machine's resources and API rate limits.

### Integration branch + single PR

Parallel `--pr` creates **one integration branch** (either your `--branch NAME` or an auto-named `ralph/parallel-<run_id>`), merges all successful agent branches into it, then opens **one PR** back to the base branch.

This avoids “one PR per task” spam while keeping agents isolated.

### How Parallel Mode Works

```
┌────────────────────────────────────────────────────────────────┐
│                    Parallel Execution Flow                      │
├────────────────────────────────────────────────────────────────┤
│                                                                  │
│  RALPH_TASK.md                                                  │
│  - [ ] Task A                                                    │
│  - [ ] Task B           ┌──────────────────────────┐            │
│  - [ ] Task C     ───▶  │   Create Worktrees       │            │
│                         └──────────────────────────┘            │
│                                    │                             │
│                    ┌───────────────┼───────────────┐            │
│                    ▼               ▼               ▼            │
│              ┌──────────┐   ┌──────────┐   ┌──────────┐         │
│              │ Agent 1  │   │ Agent 2  │   │ Agent 3  │         │
│              │ worktree │   │ worktree │   │ worktree │         │
│              │  Task A  │   │  Task B  │   │  Task C  │         │
│              └────┬─────┘   └────┬─────┘   └────┬─────┘         │
│                   │              │              │                │
│                   ▼              ▼              ▼                │
│              branch-a       branch-b       branch-c              │
│                   │              │              │                │
│                   └──────────────┼──────────────┘                │
│                                  ▼                               │
│                         ┌──────────────┐                        │
│                         │  Auto-Merge  │                        │
│                         │  to base     │                        │
│                         └──────────────┘                        │
└────────────────────────────────────────────────────────────────┘
```

**Key benefits:**
- Each agent works in complete isolation (separate git worktree)
- No interference between agents working on different tasks
- Branches auto-merge after completion (or keep separate with `--no-merge`)
- Conflict detection and reporting
- Tasks are processed in batches (e.g., 5 agents = 5 tasks per batch)
- In parallel mode, agents do **not** update `.ralph/progress.md` (they write per-agent reports instead)

**When to use parallel mode:**
- Multiple independent tasks that don't conflict
- Large task lists you want completed faster
- CI/CD pipelines with parallelization budget

**When to use sequential mode:**
- Tasks that depend on each other
- Single complex task that needs focused attention
- Limited API rate limits

### Recommended Workflow: Parallel + Integration Pass

For best results, structure your work in two phases:

**Phase 1: Parallel execution** (isolated, independent tasks)
```markdown
# Tasks
- [ ] Add user authentication to /api/auth
- [ ] Create dashboard component
- [ ] Implement data export feature
- [ ] Add unit tests for utils/
```

**Phase 2: Integration pass** (one sequential agent, repo-wide polish)
```markdown
# Tasks
- [ ] Update README with new features
- [ ] Bump version in package.json
- [ ] Update CHANGELOG
- [ ] Fix any integration issues from parallel work
```

This pattern maximizes parallelism while avoiding merge conflicts on shared files.
The integration pass runs after parallel agents finish and handles all "touch everything" work.

### Task Groups (Phased Execution)

Control execution order with `<!-- group: N -->` annotations:

```markdown
# Tasks

- [ ] Create database schema <!-- group: 1 -->
- [ ] Create User model <!-- group: 1 -->
- [ ] Create Post model <!-- group: 1 -->
- [ ] Add relationships between models <!-- group: 2 -->
- [ ] Build API endpoints <!-- group: 3 -->
- [ ] Update README  # no annotation = runs LAST
```

**Execution order:**
1. Group 1 - runs first (all tasks in parallel, up to `--max-parallel`)
2. Group 2 - runs after group 1 merges complete
3. Group 3 - runs after group 2 merges complete
4. Unannotated tasks - run LAST (after all annotated groups)

**Why unannotated = last?**
- Safer default: forgetting to annotate doesn't jump the queue
- Integration/polish tasks naturally go last
- Override with `DEFAULT_GROUP=0` env var if you prefer unannotated first

**Within each group:**
- Tasks run in parallel (up to `--max-parallel`)
- All merges complete before next group starts
- RALPH_TASK.md checkboxes updated per group

**Worktree structure:**
```
project/
├── .ralph-worktrees/           # Temporary worktrees (auto-cleaned)
│   ├── <run_id>-job1/          # Agent worktree (isolated)
│   ├── <run_id>-job2/          # Agent worktree (isolated)
│   └── <run_id>-job3/          # Agent worktree (isolated)
└── (original project files)
```

Worktrees are automatically cleaned up after agents complete. Failed agents preserve their worktree for manual inspection.

### Parallel logs & per-agent reports

Each parallel run creates a run directory:

```
.ralph/parallel/<run_id>/
├── manifest.tsv                # job_id -> task_id -> branch -> status -> log
└── jobN.log                    # full agent CLI output for that job
```

Agents are instructed to write a committed per-agent report (to avoid `.ralph/progress.md` merge conflicts):

```
.ralph/parallel/<run_id>/agent-jobN.md
```

## How It Works

### The Loop

```
Iteration 1                    Iteration 2                    Iteration N
┌──────────────────┐          ┌──────────────────┐          ┌──────────────────┐
│ Fresh context    │          │ Fresh context    │          │ Fresh context    │
│       │          │          │       │          │          │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ Read session brief│         │ Read session brief│         │ Read session brief│
│ Read task slice   │─────────│ Read task slice   │─────────│ Read task slice   │
│ Read guardrails   │ (state  │ Read guardrails   │ (state  │ Read guardrails   │
│       │          │  in git) │       │          │  in git) │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ Work on criteria │          │ Work on criteria │          │ Work on criteria │
│ Commit to git    │          │ Commit to git    │          │ Commit to git    │
│       │          │          │       │          │          │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ 200k tokens      │          │ 200k tokens      │          │ All [x] done!    │
│ ROTATE ──────────┼──────────┼──────────────────┼──────────┼──► COMPLETE      │
└──────────────────┘          └──────────────────┘          └──────────────────┘
```

Each iteration:
1. Reads a curated restart brief and only the task/state files it actually needs
2. Works on unchecked criteria
3. Commits progress to git
4. Updates `.ralph/progress.md` and `.ralph/guardrails.md`
5. Rotates when context is full

### Git Protocol

The agent is instructed to commit frequently:

```bash
# After each criterion
git add -A && git commit -m 'ralph: [criterion] - description'

# Push periodically
git push
```

**Commits are the agent's memory.** The next iteration picks up from git history.

### The Learning Loop (Signs)

When something fails, the agent adds a "Sign" to `.ralph/guardrails.md`:

```markdown
### Sign: Check imports before adding
- **Trigger**: Adding a new import statement
- **Instruction**: First check if import already exists in file
- **Added after**: Iteration 3 - duplicate import caused build failure
```

Future iterations read guardrails first and follow them, preventing repeated mistakes.

```
Error occurs → errors.log → Agent analyzes → Updates guardrails.md → Future agents follow
```

## Context Health Indicators

The activity log shows context health with emoji:

| Emoji | Status | Token % | Meaning |
|-------|--------|---------|---------|
| 🟢 | Healthy | < 60% | Plenty of room |
| 🟡 | Warning | 60-85% | Approaching limit |
| 🔴 | Critical | > 85% | Rotation imminent |

Example:
```
[12:34:56] 🟢 READ src/index.ts (245 lines, ~24.5KB)
[12:40:22] 🟡 TOKENS: 142,000 / 200,000 (71%) - approaching limit [read:40KB write:8KB assist:10KB shell:0KB]
[12:45:33] 🔴 TOKENS: 181,000 / 200,000 (90%) - rotation imminent
```

## Gutter Detection

The parser detects when the agent is stuck:

| Pattern | Trigger | What Happens |
|---------|---------|--------------|
| Repeated failure | Same command failed 3x | GUTTER signal, then fresh-context rotation |
| File thrashing | Same file written 5x in 10 min | GUTTER signal, then fresh-context rotation |
| Large-file reread thrash | Repeated same-file large rereads before any write | GUTTER signal, then fresh-context rotation |
| Rotate-without-progress streak | Repeated rotate sessions with no useful work | THRASH STOP, then a fresh-loop restart while recovery budget remains |
| Agent signals | Agent outputs `<ralph>GUTTER</ralph>` | GUTTER signal, then fresh-context rotation |

When gutter is detected:
1. Ralph records the gutter event and rotates to a fresh context
2. Check `.ralph/errors.log` for the pattern if it repeats
3. Add a guardrail or tighten the task if the same issue keeps coming back

When a `THRASH STOP` occurs:
1. Ralph now tries a fresh top-level loop restart automatically by default
2. If the repeated thrash batches are consecutive and make no net progress, Ralph eventually stops again once the recovery budget is exhausted
3. If that happens, check `.ralph/activity.log` and `.ralph/errors.log`, then tighten the task or guardrails before rerunning

## Rate Limit & Transient Error Handling

The parser detects retryable API errors and handles them gracefully:

| Error Type | Examples | What Happens |
|------------|----------|--------------|
| Rate limits | 429, "rate limit exceeded", "quota" | DEFER signal |
| Network errors | timeout, connection reset, ECONNRESET | DEFER signal |
| Server errors | 502, 503, 504, "service unavailable" | DEFER signal |

When DEFER is triggered:
1. Agent stops current iteration
2. Waits with **exponential backoff** (15s base, doubles each retry, max 120s)
3. Adds jitter (0-25%) to prevent thundering herd
4. Retries the same task (does not increment iteration)

Example log:
```
⏸️  Rate limit or transient error detected.
   Waiting 32s before retrying (attempt 2)...
   Resuming...
```

## Completion Detection

Ralph detects completion in two ways:

1. **Checkbox check**: All `[ ]` in RALPH_TASK.md changed to `[x]`
2. **Agent sigil**: Agent outputs `<ralph>COMPLETE</ralph>`

Both are verified before declaring success.

## File Reference

| File | Purpose | Who Uses It |
|------|---------|-------------|
| `RALPH_TASK.md` | Task definition + success criteria | You define, agent reads |
| `.ralph/session-brief.md` | Curated restart brief for the next iteration | Ralph generates, agent reads first |
| `.ralph/progress.md` | What's been accomplished | Agent writes after work |
| `.ralph/guardrails.md` | Lessons learned (Signs) | Agent reads first, writes after failures |
| `.ralph/activity.log` | Tool call log with token counts | Parser writes, you monitor |
| `.ralph/shell-edit-trace.tsv` | Shell mutation ledger for partial edits | Parser writes, you inspect |
| `.ralph/errors.log` | Failures + gutter detection | Parser writes, agent reads |
| `.ralph/tasks.yaml` | Cached task state (auto-generated) | Task parser writes/reads |
| `.ralph/tasks.mtime` | Task file modification time | Cache invalidation |
| `.ralph/.iteration` | Current iteration number | Parser reads/writes |

## Configuration

Configuration is set via command-line flags or environment variables:

```bash
# Via flags (recommended)
./ralph-loop.sh -n 50 -m auto --agent-backend cursor

# Via environment
RALPH_MODEL=auto RALPH_AGENT_BACKEND=qwen MAX_ITERATIONS=50 ./ralph-loop.sh
```

`auto` means "backend default":
- Cursor: Cursor resolves the concrete model
- Qwen: Qwen uses its default model unless you explicitly extend Ralph later

Default thresholds in `ralph-common.sh`:

```bash
MAX_ITERATIONS=20                   # Max iterations before giving up
WARN_THRESHOLD=170000              # Tokens: send wrapup warning
ROTATE_THRESHOLD=200000            # Tokens: force rotation
AUTO_ROTATE_LOGS=true              # Compact live logs during long runs
MAX_VERY_LARGE_REREADS_PER_FILE=3  # Let giant files get one more full pass before gutter
MAX_LARGE_REREADS_PER_FILE=3       # Stop repeated large rereads
MAX_LARGE_READS_WITHOUT_WRITE=5    # Stop discovery-only thrash
MAX_THRASH_ROTATIONS=4             # Halt after repeated rotate-without-progress
MAX_CONSECUTIVE_THRASH_RECOVERIES=2 # Auto-restart after THRASH until consecutive no-progress restarts run out
THRASH_RECOVERY_DELAY_SECONDS=3    # Brief pause before a fresh-loop restart
```

## Troubleshooting

### "Supported agent CLI not found"

```bash
# Cursor
curl https://cursor.com/install -fsS | bash

# Qwen
# See: https://qwenlm.github.io/qwen-code-docs/en/getting-started/install/
```

### Agent keeps failing on same thing

Check `.ralph/errors.log` for the pattern. Either:
1. Fix the underlying issue manually
2. Add a guardrail to `.ralph/guardrails.md` explaining what to do differently

### Context rotates too frequently

The agent might be reading too many large files. Check `activity.log` for large READs and consider:
1. Adding a guardrail: "Use `rg -n`, `wc -l`, and `sed -n` before full-reading large files"
2. Tightening `RALPH_TASK.md` so the next unchecked criterion points to a narrower target
3. Letting Ralph regenerate `.ralph/session-brief.md`, then restarting from the smaller handoff

### Task never completes

Check if criteria are too vague. Each criterion should be:
- Specific and testable
- Achievable in a single iteration
- Not dependent on manual steps
- Backed by a `test_command` or another repeatable verification command
- Stored only once in the checkbox list under `## Success Criteria`

## Workflows

### Basic (default)

```bash
./ralph-setup.sh  # Interactive setup → runs loop → done
```

### Human-in-the-loop (recommended for new tasks)

```bash
./ralph-once.sh   # Run ONE iteration
# Review changes...
./ralph-setup.sh  # Continue with full loop
```

### Scripted/CI

```bash
./ralph-loop.sh --branch feature/foo --pr -y
```

## Learn More

- [Original Ralph technique](https://ghuntley.com/ralph/) - Geoffrey Huntley
- [Context as memory](https://ghuntley.com/allocations/) - The malloc/free metaphor
- [Cursor CLI docs](https://cursor.com/docs/cli/headless)
- [Qwen Code docs](https://qwenlm.github.io/qwen-code-docs/en/users/features/headless/)
- [gum - A tool for glamorous shell scripts](https://github.com/charmbracelet/gum)

## Credits

- **Original technique**: [Geoffrey Huntley](https://ghuntley.com/ralph/) - the Ralph Wiggum methodology
- **Initial implementation**: [Agrim Singh](https://x.com/agrimsingh) - this implementation

## License

MIT
