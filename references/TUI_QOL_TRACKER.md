# Ralph TUI QoL Tracker

This checklist tracks the current quality-of-life pass for the Textual dashboard.

## Core UX

- [x] Per-pane state survives view switching for search, follow, filter, and scroll behavior.
- [x] Split view keeps a buddy pane visible beside the primary pane.
- [x] Task navigation supports next and previous unchecked items.
- [x] Signal navigation supports next and previous Ralph markers.
- [x] Command palette is available for shortcut discovery and fast actions.

## Observability

- [x] Log panes support live follow with automatic pause and resume.
- [x] Inactive tabs show unread badges when new log lines arrive.
- [x] Filters support `all`, `interesting`, `signals`, and `errors` where relevant.
- [x] Important Ralph events trigger toast notifications.
- [x] Recent signal history is visible in the timeline strip.
- [x] Staleness detection warns when Ralph appears to stop updating.

## Presentation

- [x] Empty panes explain what file is being watched and how it gets populated.
- [x] Signal and error lines are colorized for faster scanning.
- [x] Ralph mood and status react to the current run state.
- [x] Completion gets a dedicated celebration banner.

## Validation

- [x] `python3 -m py_compile scripts/ralph-tui.py`
- [x] `bash scripts/test-dashboard-smoke.sh`
- [x] Headless Textual launch with `RALPH_TUI_HEADLESS=1` and `RALPH_TUI_SMOKE_EXIT=1`
