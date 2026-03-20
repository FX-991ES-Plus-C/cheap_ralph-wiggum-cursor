#!/usr/bin/env python3
"""Ralph Wiggum Textual dashboard."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import inspect
import os
import shlex
import signal
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import IO, Any


LOG_TAIL_LIMITS = {
    "activity": 2500,
    "signals": 1200,
    "errors": 1200,
    "console": 2500,
}
FOLLOWABLE_VIEWS = {"activity", "progress", "signals", "errors", "console"}
COMPANION_ORDER = ("tasks", "activity", "console", "progress", "signals", "errors")
STALE_AFTER_SECONDS = 90

VIEW_ORDER = ("activity", "progress", "tasks", "signals", "errors", "console")
VIEW_LABELS = {
    "activity": "Activity",
    "progress": "Progress",
    "tasks": "Tasks",
    "signals": "Signals",
    "errors": "Errors",
    "console": "Console",
}
TAB_LABELS = {
    "activity": "1 Activity",
    "progress": "2 Progress",
    "tasks": "3 Tasks",
    "signals": "4 Signals",
    "errors": "5 Errors",
    "console": "6 Console",
}
SIGNAL_MARKERS = ("WARN", "ROTATE", "GUTTER", "COMPLETE", "DEFER")
SIGNAL_STYLES = {
    "WARN": "bold #ffd166",
    "ROTATE": "bold #f4a261",
    "GUTTER": "bold #90e0ef",
    "COMPLETE": "bold #2a9d8f",
    "DEFER": "bold #e76f51",
}
EMPTY_STATE_HINTS = {
    "activity": "Ralph writes token summaries and loop events here.",
    "progress": "Compacted notes and session history land here.",
    "tasks": "Checklist items from RALPH_TASK.md or ralph-tasks.md show up here.",
    "signals": "Parser signals like WARN, ROTATE, and COMPLETE appear here.",
    "errors": "Dashboard launch failures and parser issues collect here.",
    "console": "Stdout and stderr from dashboard-launched Ralph runs are captured here.",
}
FILTER_LABELS = {
    "all": "all",
    "interesting": "interesting",
    "signals": "signals",
    "errors": "errors",
}
VIEW_FILTER_ORDER = {
    "activity": ("all", "interesting", "signals", "errors"),
    "progress": ("all", "interesting"),
    "tasks": ("all",),
    "signals": ("all", "interesting"),
    "errors": ("all", "errors"),
    "console": ("all", "interesting", "signals", "errors"),
}


@dataclass
class FileViewState:
    body: str
    meta: str
    path: Path
    exists: bool
    line_count: int


@dataclass
class PaneMemory:
    scroll_y: float = 0.0
    auto_follow: bool = False
    search_query: str = ""
    filter_mode: str = "all"
    attention_raw_line: int | None = None


@dataclass
class DashboardState:
    workspace: Path
    task_file: Path
    runtime: dict[str, str]
    session: dict[str, str]
    done_count: int
    total_count: int
    remaining_count: int
    next_task: str
    token_count: int
    token_pct: int
    health_label: str
    latest_signals: list[str]
    signal_timeline: list[str]
    stale_seconds: int | None
    is_stale: bool
    is_complete: bool
    views: dict[str, FileViewState]


def decode_shell_value(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return ""
    try:
        tokens = shlex.split(raw, posix=True)
    except ValueError:
        return raw.strip("'\"")
    if not tokens:
        return ""
    return tokens[0]


def read_shell_env(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}

    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, raw = line.split("=", 1)
        values[key.strip()] = decode_shell_value(raw)
    return values


def read_file_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def count_task_progress(task_file: Path) -> tuple[int, int]:
    if not task_file.exists():
        return 0, 0

    total = 0
    done = 0
    for line in task_file.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.lstrip()
        if not stripped:
            continue
        if not (
            stripped.startswith("- [")
            or stripped.startswith("* [")
            or (stripped[0].isdigit() and ". [" in stripped[:8])
        ):
            continue
        if "[x]" in stripped.lower():
            done += 1
            total += 1
        elif "[ ]" in stripped:
            total += 1
    return done, total


def next_task_label(task_file: Path) -> str:
    if not task_file.exists():
        return "No task file yet"

    for raw_line in task_file.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = raw_line.lstrip()
        if "[ ]" not in stripped:
            continue
        if stripped.startswith("- ") or stripped.startswith("* ") or (
            stripped and stripped[0].isdigit() and ". " in stripped[:8]
        ):
            marker = stripped.find("[ ]")
            if marker != -1:
                return stripped[marker + 3 :].strip()
    return "All visible criteria checked"


def latest_token_summary(activity_file: Path, session: dict[str, str]) -> tuple[int, int]:
    token_count = 0
    token_pct = 0

    if activity_file.exists():
        for line in reversed(
            activity_file.read_text(encoding="utf-8", errors="replace").splitlines()
        ):
            if "TOKENS:" not in line:
                continue
            try:
                before_pct = line.split("(", 1)[1]
                token_pct = int(before_pct.split("%", 1)[0])
                token_count = int(line.split("TOKENS:", 1)[1].split("/", 1)[0].strip())
                return token_count, token_pct
            except (IndexError, ValueError):
                break

    raw_tokens = session.get("RALPH_SESSION_TOKENS", "0")
    try:
        token_count = int(raw_tokens)
    except ValueError:
        token_count = 0

    if token_count > 0:
        token_pct = int(token_count * 100 / 200000)
    return token_count, token_pct


def health_label(token_pct: int) -> str:
    if token_pct >= 90:
        return "SPICY"
    if token_pct >= 72:
        return "TOASTY"
    return "CHILL"


def select_task_file(workspace: Path) -> Path:
    alt = workspace / "ralph-tasks.md"
    if alt.exists():
        return alt
    return workspace / "RALPH_TASK.md"


def view_paths_for_workspace(workspace: Path, task_file: Path) -> dict[str, Path]:
    ralph_dir = workspace / ".ralph"
    return {
        "activity": ralph_dir / "activity.log",
        "progress": ralph_dir / "progress.md",
        "tasks": task_file,
        "signals": ralph_dir / "signals.log",
        "errors": ralph_dir / "errors.log",
        "console": ralph_dir / "tui-run.log",
    }


def build_empty_view_state(path: Path, view_name: str, headline: str) -> FileViewState:
    lines = [
        headline,
        f"Watching: {path}",
        EMPTY_STATE_HINTS[view_name],
        "Tip: press ? for help or : to open the command palette.",
    ]
    return FileViewState(
        body="\n".join(lines) + "\n",
        meta=f"{path.name} · waiting",
        path=path,
        exists=path.exists(),
        line_count=0,
    )


def build_view_state(path: Path, view_name: str) -> FileViewState:
    if not path.exists():
        return build_empty_view_state(path, view_name, f"{VIEW_LABELS[view_name]} is on standby.")

    raw = read_file_text(path)
    lines = raw.splitlines()
    total_lines = len(lines)
    if total_lines == 0:
        return build_empty_view_state(
            path,
            view_name,
            f"{VIEW_LABELS[view_name]} is ready but still empty.",
        )

    if view_name in LOG_TAIL_LIMITS and total_lines > LOG_TAIL_LIMITS[view_name]:
        limit = LOG_TAIL_LIMITS[view_name]
        start = total_lines - limit + 1
        body_lines = [
            f"[showing last {limit} of {total_lines} lines]",
            "",
            *lines[-limit:],
        ]
        meta = f"{path.name} · lines {start}-{total_lines} of {total_lines}"
    else:
        body_lines = lines
        meta = f"{path.name} · {total_lines} lines"

    return FileViewState(
        body="\n".join(body_lines).rstrip() + "\n",
        meta=meta,
        path=path,
        exists=True,
        line_count=total_lines,
    )


def parse_runtime_timestamp(raw: str) -> datetime | None:
    cleaned = raw.strip()
    if len(cleaned) < 19:
        return None
    try:
        return datetime.strptime(cleaned[:19], "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None


def signal_from_line(line: str) -> str | None:
    upper_line = line.upper()
    for marker in SIGNAL_MARKERS:
        if f"SIGNAL={marker}" in upper_line:
            return marker
        if f"<RALPH>{marker}</RALPH>" in upper_line:
            return marker
        if marker in upper_line and any(token in upper_line for token in ("signal", "<ralph>", "dashboard")):
            return marker
    return None


def recent_signal_timeline(lines: list[str]) -> list[str]:
    timeline = [marker for line in lines if (marker := signal_from_line(line))]
    if not timeline:
        return ["NONE"]
    return timeline[-6:]


def errorish_line(line: str) -> bool:
    lowered = line.lower()
    return any(
        keyword in lowered
        for keyword in (
            "error",
            "exception",
            "traceback",
            "fatal",
            "failed",
            "denied",
            "timeout",
            "rate limit",
        )
    )


def signalish_line(line: str) -> bool:
    return signal_from_line(line) is not None or "signal=" in line.lower() or "<ralph>" in line.lower()


def interesting_line(line: str) -> bool:
    lowered = line.lower()
    return (
        signalish_line(line)
        or errorish_line(line)
        or "tokens:" in lowered
        or "iteration" in lowered
        or "complete" in lowered
        or "warn" in lowered
        or "gutter" in lowered
        or "rotate" in lowered
    )


def mood_snapshot(state: DashboardState) -> tuple[str, str, str]:
    last_signal = state.runtime["RALPH_RUNTIME_LAST_SIGNAL"].upper()
    if state.is_complete:
        return "\\o/", "mission accomplished", "#2a9d8f"
    if state.is_stale:
        return "-_-", "waiting for fresh log crumbs", "#e76f51"
    if last_signal == "WARN":
        return "<!>", "heads-up, context is getting warm", "#ffd166"
    if last_signal == "ROTATE":
        return "<o>", "fresh context loading", "#f4a261"
    if last_signal == "GUTTER":
        return "<:>", "squeezed but still on mission", "#90e0ef"
    if last_signal == "DEFER":
        return "x_x", "taking a beat before another pass", "#e76f51"
    if state.health_label == "SPICY":
        return "<o>", "token volcano but under control", "#f4a261"
    return "\\o/", "turbo wiggle", "#ffd166"


def staleness_snapshot(runtime: dict[str, str]) -> tuple[int | None, bool]:
    status = runtime.get("RALPH_RUNTIME_STATUS", "").lower()
    if status not in {"running", "loop", "looping"}:
        return None, False

    updated_at = parse_runtime_timestamp(runtime.get("RALPH_RUNTIME_UPDATED_AT", ""))
    if updated_at is None:
        return None, False

    age_seconds = max(int((datetime.now() - updated_at).total_seconds()), 0)
    return age_seconds, age_seconds >= STALE_AFTER_SECONDS


def load_dashboard_state(workspace: Path) -> DashboardState:
    ralph_dir = workspace / ".ralph"
    runtime = read_shell_env(ralph_dir / "runtime.env")
    session = read_shell_env(ralph_dir / ".last-session.env")
    task_file = select_task_file(workspace)
    done_count, total_count = count_task_progress(task_file)
    remaining_count = max(total_count - done_count, 0)
    token_count, token_pct = latest_token_summary(ralph_dir / "activity.log", session)

    signal_lines: list[str] = []
    latest_signals: list[str] = []
    signals_file = ralph_dir / "signals.log"
    if signals_file.exists():
        signal_lines = signals_file.read_text(encoding="utf-8", errors="replace").splitlines()
        latest_signals = signal_lines[-4:]

    view_paths = view_paths_for_workspace(workspace, task_file)
    views = {
        view_name: build_view_state(path, view_name)
        for view_name, path in view_paths.items()
    }

    runtime_defaults = {
        "RALPH_RUNTIME_STATUS": "idle",
        "RALPH_RUNTIME_ITERATION": "0",
        "RALPH_RUNTIME_MODEL": "unknown",
        "RALPH_RUNTIME_LAST_SIGNAL": "NONE",
        "RALPH_RUNTIME_LAST_EVENT": "Waiting for Ralph",
        "RALPH_RUNTIME_MODE": "monitor",
        "RALPH_RUNTIME_UPDATED_AT": "not yet",
    }
    for key, value in runtime_defaults.items():
        runtime.setdefault(key, value)

    stale_seconds, is_stale = staleness_snapshot(runtime)
    last_signal = runtime["RALPH_RUNTIME_LAST_SIGNAL"].upper()
    is_complete = last_signal == "COMPLETE" or runtime["RALPH_RUNTIME_STATUS"].lower() in {
        "complete",
        "completed",
        "done",
    }

    return DashboardState(
        workspace=workspace,
        task_file=task_file,
        runtime=runtime,
        session=session,
        done_count=done_count,
        total_count=total_count,
        remaining_count=remaining_count,
        next_task=next_task_label(task_file),
        token_count=token_count,
        token_pct=token_pct,
        health_label=health_label(token_pct),
        latest_signals=latest_signals,
        signal_timeline=recent_signal_timeline(signal_lines),
        stale_seconds=stale_seconds,
        is_stale=is_stale,
        is_complete=is_complete,
        views=views,
    )


def build_placeholder_state(workspace: Path) -> DashboardState:
    task_file = select_task_file(workspace)
    view_paths = view_paths_for_workspace(workspace, task_file)
    views = {
        view_name: FileViewState(
            body=f"Loading {VIEW_LABELS[view_name]}...\n",
            meta="loading",
            path=path,
            exists=False,
            line_count=0,
        )
        for view_name, path in view_paths.items()
    }
    return DashboardState(
        workspace=workspace,
        task_file=task_file,
        runtime={
            "RALPH_RUNTIME_STATUS": "loading",
            "RALPH_RUNTIME_ITERATION": "0",
            "RALPH_RUNTIME_MODEL": "loading",
            "RALPH_RUNTIME_LAST_SIGNAL": "NONE",
            "RALPH_RUNTIME_LAST_EVENT": "Hydrating dashboard",
            "RALPH_RUNTIME_MODE": "monitor",
            "RALPH_RUNTIME_UPDATED_AT": "not yet",
        },
        session={},
        done_count=0,
        total_count=0,
        remaining_count=0,
        next_task="Loading tasks...",
        token_count=0,
        token_pct=0,
        health_label="CHILL",
        latest_signals=[],
        signal_timeline=["NONE"],
        stale_seconds=None,
        is_stale=False,
        is_complete=False,
        views=views,
    )


def append_dashboard_error(workspace: Path, message: str) -> None:
    ralph_dir = workspace / ".ralph"
    ralph_dir.mkdir(parents=True, exist_ok=True)
    error_file = ralph_dir / "errors.log"
    timestamp = datetime.now().strftime("%H:%M:%S")
    with error_file.open("a", encoding="utf-8") as handle:
        handle.write(f"[{timestamp}] dashboard: {message}\n")


def strip_tail_header(lines: list[str]) -> list[str]:
    if len(lines) >= 2 and lines[0].startswith("[showing last ") and lines[1] == "":
        return lines[2:]
    return lines


def estimate_unread_lines(previous_body: str, current_body: str) -> int:
    if previous_body == current_body:
        return 0

    previous_lines = strip_tail_header(previous_body.splitlines())
    current_lines = strip_tail_header(current_body.splitlines())

    if not previous_lines:
        return max(len(current_lines), 1)

    max_overlap = min(len(previous_lines), len(current_lines))
    overlap = 0
    for size in range(max_overlap, 0, -1):
        if previous_lines[-size:] == current_lines[:size]:
            overlap = size
            break

    return max(len(current_lines) - overlap, 1)


def render_progress_bar(done_count: int, total_count: int, width: int = 20) -> str:
    if total_count <= 0:
        return "[" + "." * width + "]"
    filled = min(width, int(done_count * width / total_count))
    return "[" + "#" * filled + "." * (width - filled) + "]"


def render_snapshot(state: DashboardState) -> str:
    lines = [
        "Ralph Dashboard",
        f"Workspace: {state.workspace}",
        (
            "Status: "
            f"{state.runtime['RALPH_RUNTIME_STATUS']}  "
            f"Iteration: {state.runtime['RALPH_RUNTIME_ITERATION']}  "
            f"Mode: {state.runtime['RALPH_RUNTIME_MODE']}  "
            f"Model: {state.runtime['RALPH_RUNTIME_MODEL']}"
        ),
        (
            "Signal: "
            f"{state.runtime['RALPH_RUNTIME_LAST_SIGNAL']}  "
            f"Event: {state.runtime['RALPH_RUNTIME_LAST_EVENT']}"
        ),
        (
            "Progress: "
            f"{state.done_count}/{state.total_count} "
            f"{render_progress_bar(state.done_count, state.total_count)} "
            f"remaining:{state.remaining_count}"
        ),
        f"Next: {state.next_task}",
        (
            "Tokens: "
            f"{state.token_count}/200000 ({state.token_pct}%) "
            f"health:{state.health_label}"
        ),
        f"Timeline: {' > '.join(state.signal_timeline)}",
        (
            "Freshness: "
            + (
                f"stale ({state.stale_seconds}s)"
                if state.is_stale and state.stale_seconds is not None
                else "fresh"
            )
        ),
        "Views: activity progress tasks signals errors console",
        "",
        f"Pane: {VIEW_LABELS['tasks']}",
        state.views["tasks"].meta,
        state.views["tasks"].body.rstrip(),
    ]
    return "\n".join(lines) + "\n"


def parse_args(argv: list[str]) -> argparse.Namespace:
    child_args: list[str] = []
    if "--" in argv:
        separator = argv.index("--")
        child_args = argv[separator + 1 :]
        argv = argv[:separator]

    parser = argparse.ArgumentParser(description="Ralph Textual dashboard")
    parser.add_argument("first", nargs="?", help="mode or workspace")
    parser.add_argument("second", nargs="?", help="workspace if mode is supplied first")
    parser.add_argument("--workspace", dest="workspace_flag", help="workspace to monitor")
    parser.add_argument(
        "--snapshot",
        action="store_true",
        help="render a plain-text snapshot and exit",
    )
    args = parser.parse_args(argv)
    args.child_args = child_args
    return args


def normalize_args(args: argparse.Namespace) -> tuple[str, Path, list[str]]:
    mode = "monitor"
    workspace = args.workspace_flag

    if args.first in ("monitor", "loop"):
        mode = args.first
        if workspace is None:
            workspace = args.second
    elif args.first and workspace is None:
        workspace = args.first

    return mode, Path(workspace or ".").resolve(), list(args.child_args)


def require_textual() -> None:
    python_bin = os.environ.get("PYTHON_BIN", sys.executable)
    try:
        import textual  # noqa: F401
    except ImportError as exc:  # pragma: no cover - exercised manually
        print("❌ The Ralph dashboard now uses Python + Textual.", file=sys.stderr)
        print("", file=sys.stderr)
        print("Install the dependency with:", file=sys.stderr)
        print(f"  {python_bin} -m pip install textual", file=sys.stderr)
        print("", file=sys.stderr)
        print("Then rerun Ralph with --dashboard.", file=sys.stderr)
        raise SystemExit(1) from exc


def launch_textual_dashboard(workspace: Path, mode: str, child_args: list[str]) -> int:
    require_textual()

    from rich.console import Group
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
    from textual.app import App, ComposeResult
    from textual.binding import Binding
    from textual.containers import Container, Horizontal, Vertical, VerticalScroll
    from textual.events import Key
    from textual.widgets import Footer, Header, Input, Static, TabPane, TabbedContent

    @dataclass
    class PaletteCommand:
        label: str
        action_name: str
        aliases: str
        description: str

    class AutoFollowScroll(VerticalScroll):
        def watch_scroll_y(self, old_value: float, new_value: float) -> None:
            super().watch_scroll_y(old_value, new_value)
            parent = self.parent
            if isinstance(parent, FileView):
                parent.handle_scroll_position_change(old_value, new_value)

    class FileView(Vertical):
        DEFAULT_CSS = """
        FileView {
            height: 1fr;
            layout: vertical;
        }

        FileView > .file-meta {
            height: auto;
            padding: 0 1;
            color: #f4d35e;
            background: #1a2230;
            text-style: bold;
        }

        FileView > VerticalScroll {
            height: 1fr;
            border: round #415a77;
            background: #0d1117;
        }

        FileView > VerticalScroll > .file-body {
            width: 100%;
            padding: 0 1;
            color: #f7f4ea;
        }
        """

        def __init__(
            self,
            view_name: str,
            follow_output: bool = False,
            *args: Any,
            **kwargs: Any,
        ) -> None:
            super().__init__(*args, **kwargs)
            self.view_name = view_name
            self.follow_output = follow_output
            self.auto_follow = follow_output
            self._current_state: FileViewState | None = None
            self._source_body = ""
            self._source_path = Path(".")
            self._current_meta = ""
            self._display_lines: list[str] = []
            self._display_raw_line_map: list[int] = []
            self._display_line_ranges: list[tuple[int, int]] = []
            self._current_body = ""
            self._last_rendered_meta: str | None = None
            self._last_rendered_body_key: tuple[str, str, int, str, int | None] | None = None
            self._suspend_follow_tracking = False
            self._search_query = ""
            self._search_matches: list[tuple[int, int, int]] = []
            self._search_index = -1
            self._filter_mode = "all"
            self._attention_raw_line: int | None = None

        def compose(self) -> ComposeResult:
            yield Static("", classes="file-meta")
            with AutoFollowScroll():
                yield Static("", classes="file-body")

        def configure(self, view_name: str, follow_output: bool) -> None:
            self.view_name = view_name
            self.follow_output = follow_output
            if not follow_output:
                self.auto_follow = False
            if self._filter_mode not in self.supported_filters():
                self._filter_mode = self.supported_filters()[0]
            self._rebuild_display_body()
            self.refresh_meta()
            self.refresh_body()

        def supported_filters(self) -> tuple[str, ...]:
            return VIEW_FILTER_ORDER.get(self.view_name, ("all",))

        def export_memory(self) -> PaneMemory:
            scroll_y = 0.0
            try:
                scroll_y = float(self.scroll_view().scroll_y)
            except Exception:
                scroll_y = 0.0
            return PaneMemory(
                scroll_y=scroll_y,
                auto_follow=self.auto_follow,
                search_query=self._search_query,
                filter_mode=self._filter_mode,
                attention_raw_line=self._attention_raw_line,
            )

        def apply_memory(self, memory: PaneMemory, *, restore_scroll: bool = False) -> None:
            self._filter_mode = (
                memory.filter_mode
                if memory.filter_mode in self.supported_filters()
                else self.supported_filters()[0]
            )
            self._search_query = memory.search_query
            self._attention_raw_line = memory.attention_raw_line
            self.auto_follow = self.follow_output and memory.auto_follow
            self._rebuild_display_body()
            self.refresh_meta()
            self.refresh_body()
            if restore_scroll:
                if self.follow_output and self.auto_follow:
                    self.scroll_to_latest()
                else:
                    self.scroll_to_line(int(memory.scroll_y), pause_follow=False)

        def set_state(self, state: FileViewState) -> None:
            self._current_state = state
            self._current_meta = state.meta
            body_changed = state.body != self._source_body or state.path != self._source_path
            self._source_body = state.body
            self._source_path = state.path
            if body_changed:
                self._rebuild_display_body()
            self.refresh_meta()
            self.refresh_body()
            if body_changed:
                if self.follow_output and self.auto_follow:
                    self.scroll_to_latest()
                elif self.follow_output and self.is_at_latest():
                    self.set_auto_follow(True)

        def _rebuild_display_body(self) -> None:
            if self._current_state is None:
                self._display_lines = []
                self._display_raw_line_map = []
                self._display_line_ranges = []
                self._current_body = ""
                self._rebuild_search_matches()
                return

            raw_lines = self._current_state.body.rstrip("\n").split("\n")
            if not raw_lines:
                raw_lines = [""]

            prefix: list[tuple[int, str]] = []
            content: list[tuple[int, str]]
            if len(raw_lines) >= 2 and raw_lines[0].startswith("[showing last ") and raw_lines[1] == "":
                prefix = [(-1, raw_lines[0]), (-1, raw_lines[1])]
                content = list(enumerate(raw_lines[2:], start=2))
            else:
                content = list(enumerate(raw_lines))

            if not self._current_state.exists or self._current_state.line_count == 0:
                display_items = [(-1, line) for line in raw_lines]
            else:
                filtered = self._apply_filter(content)
                if self._filter_mode != "all" and not filtered:
                    display_items = prefix + [
                        (-1, f"No lines match filter '{FILTER_LABELS[self._filter_mode]}' yet."),
                        (-1, f"Watching: {self._current_state.path}"),
                        (-1, "Tip: press v/V to cycle filters or : to open the command palette."),
                    ]
                else:
                    display_items = prefix + (filtered or content)

            self._display_lines = [line for _, line in display_items]
            self._display_raw_line_map = [raw_index for raw_index, _ in display_items]
            self._current_body = "\n".join(self._display_lines).rstrip() + "\n"
            self._display_line_ranges = []
            offset = 0
            for line in self._display_lines:
                start = offset
                end = start + len(line)
                self._display_line_ranges.append((start, end))
                offset = end + 1
            self._rebuild_search_matches()

        def _apply_filter(self, content: list[tuple[int, str]]) -> list[tuple[int, str]]:
            if self._filter_mode == "all":
                return content
            if self._filter_mode == "interesting":
                return [(index, line) for index, line in content if interesting_line(line)]
            if self._filter_mode == "signals":
                return [(index, line) for index, line in content if signalish_line(line)]
            if self._filter_mode == "errors":
                return [(index, line) for index, line in content if errorish_line(line)]
            return content

        def refresh_meta(self) -> None:
            rendered_meta = self._render_meta()
            if rendered_meta == self._last_rendered_meta:
                return
            self.query_one(".file-meta", Static).update(
                Text(rendered_meta, no_wrap=True, overflow="ellipsis")
            )
            self._last_rendered_meta = rendered_meta

        def _render_meta(self) -> str:
            extras: list[str] = []
            if self.follow_output:
                extras.append(f"follow {'live' if self.auto_follow else 'paused'}")
            if self._filter_mode != "all":
                extras.append(f"filter {FILTER_LABELS[self._filter_mode]}")
            if self._search_query:
                preview = self._search_query[:18] + ("..." if len(self._search_query) > 18 else "")
                if self._search_matches:
                    extras.append(f"search {self._search_index + 1}/{len(self._search_matches)} '{preview}'")
                else:
                    extras.append(f"search 0 '{preview}'")
            return " · ".join(part for part in [self._current_meta, *extras] if part)

        def refresh_body(self) -> None:
            body_key = (
                self._current_body,
                self._search_query,
                self._search_index,
                self._filter_mode,
                self._attention_raw_line,
            )
            if body_key == self._last_rendered_body_key:
                return
            self.query_one(".file-body", Static).update(self._render_body())
            self._last_rendered_body_key = body_key

        def _render_body(self) -> Text:
            text = Text(self._current_body)
            for line_index, line in enumerate(self._display_lines):
                if line_index >= len(self._display_line_ranges):
                    break
                start, end = self._display_line_ranges[line_index]
                raw_line = self._display_raw_line_map[line_index]
                style = self._line_style(raw_line, line)
                if style:
                    text.stylize(style, start, end)
                if raw_line != -1 and raw_line == self._attention_raw_line:
                    text.stylize("bold #081c15 on #ffd166", start, end)

            for index, (start, end, _) in enumerate(self._search_matches):
                style = (
                    "bold #081c15 on #ffd166"
                    if index == self._search_index
                    else "#f7f4ea on #335c67"
                )
                text.stylize(style, start, end)
            return text

        def _line_style(self, raw_line: int, line: str) -> str | None:
            stripped = line.strip()
            if raw_line == -1:
                if stripped.startswith("Watching:"):
                    return "bold #8ecae6"
                if stripped.startswith("Tip:"):
                    return "bold #ffd166"
                return "dim #d9d9d9"

            signal_name = signal_from_line(line)
            if signal_name:
                return SIGNAL_STYLES[signal_name]
            if self.view_name == "tasks":
                if stripped.startswith("#"):
                    return "bold #8ecae6"
                if "[ ]" in line:
                    return "bold #ffd166"
                if "[x]" in line.lower():
                    return "dim #2a9d8f"
            if errorish_line(line):
                return "bold #e76f51"
            if "TOKENS:" in line:
                return "bold #8ecae6"
            if stripped.startswith("#"):
                return "bold #90e0ef"
            if self.view_name == "progress" and stripped.startswith("- "):
                return "#e9edc9"
            return None

        def _rebuild_search_matches(self) -> None:
            self._search_matches = []
            if not self._search_query or not self._current_body:
                self._search_index = -1
                return

            needle = self._search_query.lower()
            offset = 0
            for line_index, raw_line in enumerate(self._current_body.splitlines(keepends=True)):
                lowered = raw_line.lower()
                start = 0
                while True:
                    match_index = lowered.find(needle, start)
                    if match_index == -1:
                        break
                    self._search_matches.append(
                        (
                            offset + match_index,
                            offset + match_index + len(needle),
                            line_index,
                        )
                    )
                    start = match_index + len(needle)
                offset += len(raw_line)

            if not self._search_matches:
                self._search_index = -1
            elif self._search_index < 0 or self._search_index >= len(self._search_matches):
                self._search_index = 0

        def scroll_view(self) -> AutoFollowScroll:
            return self.query_one(AutoFollowScroll)

        def is_at_latest(self) -> bool:
            scroll_view = self.scroll_view()
            return scroll_view.max_scroll_y <= 0 or (
                scroll_view.scroll_y >= max(scroll_view.max_scroll_y - 1, 0)
            )

        def set_auto_follow(self, enabled: bool) -> None:
            if not self.follow_output:
                return
            if self.auto_follow == enabled:
                return
            self.auto_follow = enabled
            self.refresh_meta()

        def handle_scroll_position_change(self, old_value: float, new_value: float) -> None:
            del old_value, new_value
            if not self.follow_output or self._suspend_follow_tracking:
                return
            self.set_auto_follow(self.is_at_latest())

        def scroll_to_latest(self) -> None:
            if not self.follow_output:
                return

            def follow_now() -> None:
                scroll_view = self.scroll_view()
                self._suspend_follow_tracking = True
                try:
                    scroll_view.scroll_end(
                        animate=False,
                        immediate=True,
                        x_axis=False,
                        y_axis=True,
                    )
                finally:
                    self._suspend_follow_tracking = False
                self.set_auto_follow(self.is_at_latest())

            self.call_after_refresh(follow_now)

        def toggle_follow(self) -> bool:
            if not self.follow_output:
                return False
            if self.auto_follow:
                self.set_auto_follow(False)
            else:
                self.set_auto_follow(True)
                self.scroll_to_latest()
            return self.auto_follow

        def current_filter_mode(self) -> str:
            return self._filter_mode

        def cycle_filter(self, backwards: bool = False) -> str:
            filters = self.supported_filters()
            index = filters.index(self._filter_mode) if self._filter_mode in filters else 0
            step = -1 if backwards else 1
            self._filter_mode = filters[(index + step) % len(filters)]
            self._rebuild_display_body()
            self.refresh_meta()
            self.refresh_body()
            if self.follow_output and self.auto_follow:
                self.scroll_to_latest()
            return self._filter_mode

        def search_query(self) -> str:
            return self._search_query

        def search_match_count(self) -> int:
            return len(self._search_matches)

        def set_search_query(self, query: str, *, jump_to_first: bool = True) -> int:
            self._search_query = query.strip()
            self._rebuild_search_matches()
            self.refresh_meta()
            self.refresh_body()
            if jump_to_first and self._search_matches:
                self._search_index = 0
                self.refresh_meta()
                self.refresh_body()
                self.jump_to_current_search_result()
            return len(self._search_matches)

        def jump_to_current_search_result(self) -> str | None:
            if not self._search_matches or self._search_index < 0:
                return None
            _, _, line_index = self._search_matches[self._search_index]
            self.scroll_to_line(line_index, pause_follow=True)
            return f"Match {self._search_index + 1}/{len(self._search_matches)}"

        def jump_to_search_result(self, backwards: bool = False) -> str | None:
            if not self._search_matches:
                return None
            if self._search_index < 0:
                self._search_index = 0
            else:
                step = -1 if backwards else 1
                self._search_index = (self._search_index + step) % len(self._search_matches)
            self.refresh_meta()
            self.refresh_body()
            return self.jump_to_current_search_result()

        def scroll_to_line(self, line_index: int, *, pause_follow: bool = False) -> None:
            if pause_follow and self.follow_output:
                self.set_auto_follow(False)

            def jump_now() -> None:
                self.scroll_view().scroll_to(y=max(line_index, 0), animate=False, immediate=True)
                self.sync_follow_state_after_manual_scroll()

            self.call_after_refresh(jump_now)

        def visible_top_line(self) -> int:
            return int(self.scroll_view().scroll_y)

        def _cycle_to_lines(
            self,
            line_matches: list[tuple[int, int, str]],
            *,
            backwards: bool = False,
        ) -> str | None:
            if not line_matches:
                return None

            current_line = self.visible_top_line()
            selected_line, selected_raw, selected_text = line_matches[0]
            if backwards:
                for line_index, raw_index, line_text in reversed(line_matches):
                    if line_index < current_line:
                        selected_line, selected_raw, selected_text = line_index, raw_index, line_text
                        break
                else:
                    selected_line, selected_raw, selected_text = line_matches[-1]
            else:
                for line_index, raw_index, line_text in line_matches:
                    if line_index > current_line:
                        selected_line, selected_raw, selected_text = line_index, raw_index, line_text
                        break

            self._attention_raw_line = selected_raw if selected_raw != -1 else None
            self.refresh_body()
            self.scroll_to_line(selected_line, pause_follow=True)
            return selected_text

        def jump_to_unchecked_task(self, backwards: bool = False) -> str | None:
            task_lines = [
                (line_index, raw_index, line.strip())
                for line_index, (raw_index, line) in enumerate(
                    zip(self._display_raw_line_map, self._display_lines)
                )
                if raw_index != -1 and "[ ]" in line
            ]
            return self._cycle_to_lines(task_lines, backwards=backwards)

        def jump_to_signal_marker(self, backwards: bool = False) -> str | None:
            marker_lines = [
                (line_index, raw_index, line.strip())
                for line_index, (raw_index, line) in enumerate(
                    zip(self._display_raw_line_map, self._display_lines)
                )
                if raw_index != -1 and signal_from_line(line)
            ]
            return self._cycle_to_lines(marker_lines, backwards=backwards)

        def sync_follow_state_after_manual_scroll(self) -> None:
            if not self.follow_output or self._suspend_follow_tracking:
                return
            self.set_auto_follow(self.is_at_latest())

        def scroll_line_up(self) -> None:
            self.scroll_view().scroll_up(animate=False)
            self.sync_follow_state_after_manual_scroll()

        def scroll_line_down(self) -> None:
            self.scroll_view().scroll_down(animate=False)
            self.sync_follow_state_after_manual_scroll()

        def scroll_page_up(self) -> None:
            self.scroll_view().scroll_page_up(animate=False)
            self.sync_follow_state_after_manual_scroll()

        def scroll_page_down(self) -> None:
            self.scroll_view().scroll_page_down(animate=False)
            self.sync_follow_state_after_manual_scroll()

        def scroll_home_fast(self) -> None:
            self.scroll_view().scroll_home(animate=False)
            self.sync_follow_state_after_manual_scroll()

        def scroll_end_fast(self) -> None:
            if self.follow_output:
                self.set_auto_follow(True)
                self.scroll_to_latest()
                return
            self.scroll_view().scroll_end(animate=False)

    class RalphDashboardApp(App[None]):
        TITLE = "Ralph Dashboard"
        CSS = """
        Screen {
            background: #10161d;
            color: #f7f4ea;
        }

        Header {
            background: #2a6f97;
            color: #fefae0;
        }

        Footer {
            background: #1f2937;
            color: #fefae0;
        }

        #body {
            layout: vertical;
            height: 1fr;
        }

        #cards {
            height: auto;
            layout: horizontal;
            padding: 1;
        }

        .card {
            width: 1fr;
            min-height: 9;
            margin-right: 1;
        }

        #signal-card {
            margin-right: 0;
        }

        #help-strip {
            height: auto;
            padding: 0 1;
            background: #223046;
            color: #ffd166;
        }

        #timeline-strip {
            height: auto;
            padding: 0 1;
            background: #132238;
            color: #90e0ef;
        }

        #celebration-strip {
            height: auto;
            padding: 0 1;
            background: #264653;
            color: #fefae0;
            text-style: bold;
        }

        #celebration-strip.hidden {
            display: none;
        }

        #search-bar {
            height: auto;
            padding: 0 1;
            background: #14213d;
            color: #fefae0;
            layout: horizontal;
        }

        #search-bar.hidden {
            display: none;
        }

        #search-label {
            width: auto;
            padding-right: 1;
            color: #ffd166;
            text-style: bold;
        }

        #search-input {
            width: 1fr;
        }

        #palette-panel {
            height: auto;
            margin: 0 1;
            padding: 1;
            border: round #415a77;
            background: #0d1b2a;
        }

        #palette-panel.hidden {
            display: none;
        }

        #palette-title {
            color: #ffd166;
            text-style: bold;
        }

        #palette-results {
            padding-top: 1;
            color: #f7f4ea;
        }

        #content-row {
            height: 1fr;
            layout: horizontal;
        }

        #primary-column {
            width: 2fr;
            height: 1fr;
        }

        #companion-column {
            width: 1fr;
            min-width: 36;
            height: 1fr;
            margin: 0 1 1 0;
        }

        #companion-column.hidden {
            display: none;
        }

        #companion-label {
            height: auto;
            padding: 0 1;
            background: #233554;
            color: #ffd166;
            text-style: bold;
        }

        #status-strip {
            height: auto;
            padding: 0 1;
            background: #1b263b;
            color: #f4f1de;
        }

        TabbedContent {
            height: 1fr;
            margin: 0 1 1 1;
        }

        TabPane {
            padding: 0;
        }
        """

        BINDINGS = [
            Binding("1", "show_activity", show=False),
            Binding("2", "show_progress", show=False),
            Binding("3", "show_tasks", show=False),
            Binding("4", "show_signals", show=False),
            Binding("5", "show_errors", show=False),
            Binding("6", "show_console", show=False),
            Binding("tab", "next_view", show=False),
            Binding("shift+tab", "previous_view", show=False),
            Binding("left", "previous_view", show=False),
            Binding("right", "next_view", show=False),
            Binding("up", "scroll_up", show=False),
            Binding("down", "scroll_down", show=False),
            Binding("j", "scroll_down", show=False),
            Binding("k", "scroll_up", show=False),
            Binding("pageup", "page_up", show=False),
            Binding("pagedown", "page_down", show=False),
            Binding("g", "scroll_home", show=False),
            Binding("G", "scroll_end", show=False),
            Binding("f", "toggle_follow", show=False),
            Binding("v", "cycle_filter", show=False),
            Binding("V", "cycle_filter_reverse", show=False),
            Binding("s", "toggle_split", show=False),
            Binding("b", "cycle_companion", show=False),
            Binding("B", "cycle_companion_reverse", show=False),
            Binding("slash", "open_search", show=False),
            Binding("n", "search_next", show=False),
            Binding("N", "search_previous", show=False),
            Binding("t", "jump_next_task", show=False),
            Binding("T", "jump_previous_task", show=False),
            Binding("right_square_bracket", "jump_next_signal", show=False),
            Binding("left_square_bracket", "jump_previous_signal", show=False),
            Binding("colon", "open_palette", show=False),
            Binding("ctrl+p", "open_palette", show=False),
            Binding("escape", "cancel_overlay", show=False),
            Binding("r", "refresh_now", "Refresh", show=True),
            Binding("question_mark", "toggle_help", "Help", show=True),
            Binding("x", "stop_loop", "Stop Loop", show=True),
            Binding("q", "quit_dashboard", "Quit", show=True),
        ]

        def __init__(self, workspace: Path, mode: str, child_args: list[str]) -> None:
            super().__init__()
            self.workspace = workspace
            self.mode = mode
            self.child_args = child_args
            self.smoke_exit = os.environ.get("RALPH_TUI_SMOKE_EXIT") == "1"
            self.help_expanded = True
            self.note = "Dashboard ready."
            self.tick = 0
            self.last_state = build_placeholder_state(workspace)
            self.refresh_in_flight = False
            self.search_open = False
            self.palette_open = False
            self.palette_selected = 0
            self.palette_matches: list[PaletteCommand] = []
            self.unread_counts = {view_name: 0 for view_name in VIEW_ORDER}
            self.split_mode = False
            self.companion_view_name = "tasks"
            self.child_process: asyncio.subprocess.Process | None = None
            self.child_exit_code = 0
            self.console_handle: IO[str] | None = None
            self.child_wait_task: asyncio.Task[None] | None = None
            self.console_path = workspace / ".ralph" / "tui-run.log"

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            with Container(id="body"):
                with Horizontal(id="cards"):
                    yield Static(classes="card", id="hero-card")
                    yield Static(classes="card", id="progress-card")
                    yield Static(classes="card", id="signal-card")
                yield Static(id="help-strip")
                yield Static(id="timeline-strip")
                yield Static(id="celebration-strip", classes="hidden")
                with Horizontal(id="search-bar", classes="hidden"):
                    yield Static("Search", id="search-label")
                    yield Input(placeholder="Search the current pane", id="search-input")
                with Vertical(id="palette-panel", classes="hidden"):
                    yield Static("Command Palette", id="palette-title")
                    yield Input(placeholder="Type a command and press Enter", id="palette-input")
                    yield Static(id="palette-results")
                with Horizontal(id="content-row"):
                    with Vertical(id="primary-column"):
                        with TabbedContent(id="views", initial="activity"):
                            with TabPane("1 Activity", id="activity"):
                                yield FileView("activity", follow_output=True, id="activity-view")
                            with TabPane("2 Progress", id="progress"):
                                yield FileView("progress", follow_output=True, id="progress-view")
                            with TabPane("3 Tasks", id="tasks"):
                                yield FileView("tasks", id="tasks-view")
                            with TabPane("4 Signals", id="signals"):
                                yield FileView("signals", follow_output=True, id="signals-view")
                            with TabPane("5 Errors", id="errors"):
                                yield FileView("errors", follow_output=True, id="errors-view")
                            with TabPane("6 Console", id="console"):
                                yield FileView("console", follow_output=True, id="console-view")
                    with Vertical(id="companion-column", classes="hidden"):
                        yield Static(id="companion-label")
                        yield FileView("tasks", id="companion-view")
                yield Static(id="status-strip")
            yield Footer()

        def on_mount(self) -> None:
            self.sub_title = str(self.workspace)
            if self.console_path.parent.exists():
                self.console_path.touch()
            self.update_tab_labels()
            self.update_timeline_strip()
            self.update_celebration_strip()
            self.update_split_layout()
            self.schedule_refresh()
            self.set_interval(0.5, self.schedule_refresh)
            if self.mode == "loop":
                asyncio.create_task(self.start_child_loop())
            if self.smoke_exit:
                self.set_timer(0.2, self.exit)

        def active_view_name(self) -> str:
            return self.query_one(TabbedContent).active or "activity"

        def active_file_view(self) -> FileView:
            return self.query_one(f"#{self.active_view_name()}-view", FileView)

        def search_input(self) -> Input:
            return self.query_one("#search-input", Input)

        def palette_input(self) -> Input:
            return self.query_one("#palette-input", Input)

        def current_companion_view(self) -> str:
            active = self.active_view_name()
            if self.companion_view_name != active:
                return self.companion_view_name
            for candidate in COMPANION_ORDER:
                if candidate != active:
                    self.companion_view_name = candidate
                    return candidate
            return self.companion_view_name

        def command_specs(self) -> list[PaletteCommand]:
            return [
                PaletteCommand("Show Activity", "show_activity", "activity logs", "Switch to activity stream"),
                PaletteCommand("Show Progress", "show_progress", "progress notes", "Switch to progress markdown"),
                PaletteCommand("Show Tasks", "show_tasks", "tasks checklist", "Switch to the task list"),
                PaletteCommand("Show Signals", "show_signals", "signals warn rotate complete", "Switch to signal history"),
                PaletteCommand("Show Errors", "show_errors", "errors failures", "Switch to error log"),
                PaletteCommand("Show Console", "show_console", "console stdout stderr", "Switch to Ralph console output"),
                PaletteCommand("Toggle Split View", "toggle_split", "split buddy side by side", "Show or hide a buddy pane"),
                PaletteCommand("Cycle Buddy Pane", "cycle_companion", "buddy companion pin", "Swap the companion pane"),
                PaletteCommand("Toggle Follow", "toggle_follow", "follow live tail", "Pause or resume live follow"),
                PaletteCommand("Cycle Filter", "cycle_filter", "filter interesting signals errors", "Change the current pane filter"),
                PaletteCommand("Open Search", "open_search", "search find", "Search the current pane"),
                PaletteCommand("Next Task", "jump_next_task", "next task unchecked", "Jump to the next unchecked task"),
                PaletteCommand("Previous Task", "jump_previous_task", "previous task unchecked", "Jump to the previous unchecked task"),
                PaletteCommand("Next Signal", "jump_next_signal", "next signal marker", "Jump to the next Ralph signal"),
                PaletteCommand("Previous Signal", "jump_previous_signal", "previous signal marker", "Jump to the previous Ralph signal"),
                PaletteCommand("Refresh Dashboard", "refresh_now", "refresh reload", "Force an immediate refresh"),
                PaletteCommand("Toggle Help", "toggle_help", "help guide", "Collapse or expand the help strip"),
                PaletteCommand("Stop Loop", "stop_loop", "stop terminate", "Stop the dashboard-launched Ralph loop"),
                PaletteCommand("Quit Dashboard", "quit_dashboard", "quit exit close", "Close the dashboard"),
            ]

        def update_tab_labels(self) -> None:
            active_view = self.active_view_name()
            tabbed_content = self.query_one(TabbedContent)
            self.unread_counts[active_view] = 0
            for view_name in VIEW_ORDER:
                label = TAB_LABELS[view_name]
                unread = self.unread_counts.get(view_name, 0)
                if unread > 0 and view_name != active_view:
                    label = f"{label} [{unread}]"
                tabbed_content.get_tab(view_name).label = label

        def update_unread_counts(self, previous_state: DashboardState, state: DashboardState) -> None:
            if previous_state.runtime.get("RALPH_RUNTIME_STATUS") == "loading":
                return
            active_view = self.active_view_name()
            for view_name in VIEW_ORDER:
                delta = estimate_unread_lines(
                    previous_state.views[view_name].body,
                    state.views[view_name].body,
                )
                if delta <= 0:
                    continue
                if view_name == active_view:
                    self.unread_counts[view_name] = 0
                else:
                    self.unread_counts[view_name] += delta

        def set_search_open(self, enabled: bool) -> None:
            if enabled and self.palette_open:
                self.set_palette_open(False)
            self.search_open = enabled
            search_bar = self.query_one("#search-bar", Horizontal)
            search_input = self.search_input()
            if enabled:
                search_bar.remove_class("hidden")
                search_input.value = self.active_file_view().search_query()
                search_input.focus()
                self.set_note("Search the current pane. Enter keeps highlights; Esc closes.")
            else:
                search_bar.add_class("hidden")
                search_input.blur()

        def set_palette_open(self, enabled: bool) -> None:
            if enabled and self.search_open:
                self.set_search_open(False)
            self.palette_open = enabled
            palette_panel = self.query_one("#palette-panel", Vertical)
            palette_input = self.palette_input()
            if enabled:
                palette_panel.remove_class("hidden")
                palette_input.value = ""
                self.palette_selected = 0
                self.update_palette_results("")
                palette_input.focus()
                self.set_note("Command palette open. Type, then Enter to launch the top match.")
            else:
                palette_panel.add_class("hidden")
                palette_input.blur()

        def update_palette_results(self, query: str) -> None:
            lowered = query.lower().strip()
            matches: list[tuple[int, PaletteCommand]] = []
            for command in self.command_specs():
                haystack = " ".join(
                    [command.label.lower(), command.aliases.lower(), command.description.lower()]
                )
                if not lowered:
                    matches.append((1, command))
                    continue
                if lowered not in haystack:
                    continue
                score = 3
                if command.label.lower().startswith(lowered):
                    score = 0
                elif lowered in command.aliases.lower():
                    score = 1
                elif lowered in command.description.lower():
                    score = 2
                matches.append((score, command))

            self.palette_matches = [
                command for _, command in sorted(matches, key=lambda item: (item[0], item[1].label))
            ][:8]
            self.palette_selected = min(self.palette_selected, max(len(self.palette_matches) - 1, 0))

            results = Text()
            if not self.palette_matches:
                results.append("No commands match that search yet.", style="dim #d9d9d9")
            else:
                for index, command in enumerate(self.palette_matches):
                    prefix = "> " if index == self.palette_selected else "  "
                    style = "bold #081c15 on #ffd166" if index == self.palette_selected else "#f7f4ea"
                    results.append(f"{prefix}{command.label:<20} {command.description}", style=style)
                    results.append("\n")
            self.query_one("#palette-results", Static).update(results)

        def move_palette_selection(self, delta: int) -> None:
            if not self.palette_matches:
                return
            self.palette_selected = (self.palette_selected + delta) % len(self.palette_matches)
            self.update_palette_results(self.palette_input().value)

        def invoke_action(self, action_name: str) -> None:
            handler = getattr(self, f"action_{action_name}")
            result = handler()
            if inspect.isawaitable(result):
                asyncio.create_task(result)

        def run_palette_selection(self) -> None:
            if not self.palette_matches:
                self.set_note("No command is selected.")
                return
            action_name = self.palette_matches[self.palette_selected].action_name
            self.set_palette_open(False)
            self.invoke_action(action_name)

        def update_cards(self) -> None:
            state = self.last_state
            mascot, mood, mood_color = mood_snapshot(state)
            freshness = (
                f"STALE for {state.stale_seconds}s"
                if state.is_stale and state.stale_seconds is not None
                else "fresh"
            )
            layout = (
                f"buddy {VIEW_LABELS[self.current_companion_view()].lower()}"
                if self.split_mode
                else "solo view"
            )

            hero_lines = Group(
                Text(f"Ralph Dashboard  {mascot}", style="bold #fefae0"),
                Text(f"Mood: {mood}", style=f"bold {mood_color}"),
                Text(f"Workspace: {self.workspace.name}", style="#f7f4ea"),
                Text(
                    "Status: "
                    f"{state.runtime['RALPH_RUNTIME_STATUS']}  "
                    f"Iteration: {state.runtime['RALPH_RUNTIME_ITERATION']}",
                    style="#bde0fe",
                ),
                Text(f"Freshness: {freshness}  |  Layout: {layout}", style="#f7f4ea"),
                Text(
                    "Event: "
                    f"{state.runtime['RALPH_RUNTIME_LAST_EVENT']}",
                    style="#f7f4ea",
                    overflow="ellipsis",
                ),
                Text(
                    "Updated: "
                    f"{state.runtime['RALPH_RUNTIME_UPDATED_AT']}",
                    style="dim",
                ),
            )

            progress_table = Table.grid(expand=True)
            progress_table.add_column(justify="left")
            progress_table.add_column(justify="right")
            progress_table.add_row(
                f"Criteria  {state.done_count}/{state.total_count}",
                render_progress_bar(state.done_count, state.total_count),
            )
            progress_table.add_row("Remaining", str(state.remaining_count))
            progress_table.add_row("Tokens", f"{state.token_count}/200000 ({state.token_pct}%)")
            progress_table.add_row("Health", state.health_label)
            progress_table.add_row("Filter", FILTER_LABELS[self.active_file_view().current_filter_mode()])
            progress_table.add_row(
                "Next",
                state.next_task[:28] + ("..." if len(state.next_task) > 28 else ""),
            )

            latest_signal = state.runtime["RALPH_RUNTIME_LAST_SIGNAL"]
            signal_lines = Group(
                Text(f"Signal: {latest_signal}", style="bold #90e0ef"),
                Text("Trail: " + " > ".join(state.signal_timeline[-5:]), style="#ffd166"),
                *[
                    Text(line or " ", style="#f7f4ea", overflow="ellipsis")
                    for line in (state.latest_signals[-3:] or ["No signals yet."])
                ],
            )

            self.query_one("#hero-card", Static).update(
                Panel(hero_lines, title="Mission Control", border_style=mood_color)
            )
            self.query_one("#progress-card", Static).update(
                Panel(progress_table, title="Progress", border_style="#f4a261")
            )
            self.query_one("#signal-card", Static).update(
                Panel(signal_lines, title="Signals", border_style="#e9c46a")
            )

        def update_help_strip(self) -> None:
            if self.help_expanded:
                message = (
                    "Keys: 1-6 views | tab/shift-tab or left/right switch | "
                    "j/k scroll | g/G jump | f follow | v/V filter | / search | "
                    "n/N matches | t/T tasks | [/] signals | s split | b/B buddy | "
                    ": palette | r refresh | ? help | x stop | q quit"
                )
            else:
                message = "Press ? to reopen the control guide."
            self.query_one("#help-strip", Static).update(Text(message))

        def update_timeline_strip(self) -> None:
            state = self.last_state
            message = "Signal Trail: " + " > ".join(state.signal_timeline)
            if state.is_stale and state.stale_seconds is not None:
                message += f"  |  stale for {state.stale_seconds}s"
            else:
                message += "  |  logs look fresh"
            self.query_one("#timeline-strip", Static).update(
                Text(message, no_wrap=True, overflow="ellipsis")
            )

        def update_celebration_strip(self) -> None:
            banner = self.query_one("#celebration-strip", Static)
            if self.last_state.is_complete:
                banner.remove_class("hidden")
                banner.update(
                    Text(
                        "MISSION COMPLETE  |  Ralph hit COMPLETE and the dashboard is doing a tiny victory lap."
                    )
                )
            else:
                banner.add_class("hidden")
                banner.update(Text(""))

        def update_status_strip(self) -> None:
            if self.child_process and self.child_process.returncode is None:
                child_state = "Background Ralph loop is running."
            elif self.mode == "loop":
                child_state = f"Background Ralph loop finished with exit code {self.child_exit_code}."
            else:
                child_state = "Monitor mode: read-only dashboard."

            state = self.last_state
            split_summary = (
                f"Split:{VIEW_LABELS[self.current_companion_view()]}"
                if self.split_mode
                else "Split:off"
            )
            stale_summary = (
                f"Stale:{state.stale_seconds}s"
                if state.is_stale and state.stale_seconds is not None
                else "Fresh"
            )
            summary = (
                f"{self.note}  |  Active: {VIEW_LABELS[self.active_view_name()]}  |  "
                f"Mode: {state.runtime['RALPH_RUNTIME_MODE']}  |  "
                f"Model: {state.runtime['RALPH_RUNTIME_MODEL']}  |  "
                f"Filter: {FILTER_LABELS[self.active_file_view().current_filter_mode()]}  |  "
                f"{split_summary}  |  {stale_summary}  |  "
                f"{child_state}"
            )
            self.query_one("#status-strip", Static).update(
                Text(summary, no_wrap=True, overflow="ellipsis")
            )

        def set_note(self, message: str) -> None:
            self.note = message
            self.update_status_strip()

        def emit_notifications(
            self,
            previous_state: DashboardState,
            state: DashboardState,
            *,
            allow_toasts: bool = True,
        ) -> None:
            if previous_state.runtime.get("RALPH_RUNTIME_STATUS") == "loading":
                return

            previous_signal = previous_state.latest_signals[-1] if previous_state.latest_signals else ""
            current_signal = state.latest_signals[-1] if state.latest_signals else ""
            if allow_toasts and current_signal and current_signal != previous_signal:
                signal_name = signal_from_line(current_signal)
                if signal_name:
                    severity = "information"
                    if signal_name in {"WARN", "DEFER"}:
                        severity = "warning"
                    self.notify(
                        current_signal[-160:],
                        title=f"Ralph {signal_name}",
                        severity=severity,
                        timeout=4,
                    )

            if allow_toasts and state.is_stale and not previous_state.is_stale and state.stale_seconds is not None:
                self.notify(
                    f"No dashboard updates for {state.stale_seconds}s.",
                    title="Ralph looks stale",
                    severity="warning",
                    timeout=4,
                )

            if allow_toasts and state.is_complete and not previous_state.is_complete:
                self.notify(
                    "Ralph marked the current run COMPLETE.",
                    title="Mission Complete",
                    severity="information",
                    timeout=5,
                )

        def update_split_layout(self) -> None:
            column = self.query_one("#companion-column", Vertical)
            companion_view = self.query_one("#companion-view", FileView)
            if not self.split_mode:
                column.add_class("hidden")
                return

            companion_name = self.current_companion_view()
            source_view = self.query_one(f"#{companion_name}-view", FileView)
            column.remove_class("hidden")
            self.query_one("#companion-label", Static).update(
                Text(f"Buddy Pane  {VIEW_LABELS[companion_name]}  |  b/B cycle  |  s hide")
            )
            companion_view.configure(companion_name, companion_name in FOLLOWABLE_VIEWS)
            companion_view.apply_memory(source_view.export_memory(), restore_scroll=False)
            companion_view.set_state(self.last_state.views[companion_name])

        def schedule_refresh(self) -> None:
            if self.refresh_in_flight:
                return
            self.refresh_in_flight = True
            asyncio.create_task(self.refresh_dashboard_async())

        async def refresh_dashboard_async(self) -> None:
            try:
                self.tick += 1
                previous_state = self.last_state
                state = await asyncio.to_thread(load_dashboard_state, self.workspace)
                self.update_unread_counts(previous_state, state)
                self.last_state = state
                for view_name in VIEW_ORDER:
                    self.query_one(f"#{view_name}-view", FileView).set_state(state.views[view_name])
                self.emit_notifications(previous_state, state)
                self.update_tab_labels()
                self.update_cards()
                self.update_help_strip()
                self.update_timeline_strip()
                self.update_celebration_strip()
                self.update_split_layout()
                self.update_status_strip()
            finally:
                self.refresh_in_flight = False

        def refresh_dashboard(self) -> None:
            self.tick += 1
            previous_state = self.last_state
            state = load_dashboard_state(self.workspace)
            self.update_unread_counts(previous_state, state)
            self.last_state = state
            for view_name in VIEW_ORDER:
                self.query_one(f"#{view_name}-view", FileView).set_state(state.views[view_name])
            self.emit_notifications(previous_state, state, allow_toasts=False)
            self.update_tab_labels()
            self.update_cards()
            self.update_help_strip()
            self.update_timeline_strip()
            self.update_celebration_strip()
            self.update_split_layout()
            self.update_status_strip()

        async def start_child_loop(self) -> None:
            if self.child_process is not None and self.child_process.returncode is None:
                self.set_note("Loop already running.")
                return

            await asyncio.to_thread(self.console_path.write_text, "", encoding="utf-8")
            self.console_handle = self.console_path.open("a", encoding="utf-8")
            loop_script = self.workspace / ".cursor" / "ralph-scripts" / "ralph-loop.sh"
            if not loop_script.exists():
                loop_script = Path(__file__).resolve().parent / "ralph-loop.sh"

            env = os.environ.copy()
            env["RALPH_TUI_ACTIVE"] = "1"
            try:
                self.child_process = await asyncio.create_subprocess_exec(
                    str(loop_script),
                    *self.child_args,
                    stdout=self.console_handle,
                    stderr=asyncio.subprocess.STDOUT,
                    cwd=self.workspace,
                    env=env,
                    start_new_session=True,
                )
            except Exception as exc:
                message = f"Failed to launch Ralph loop: {exc}"
                append_dashboard_error(self.workspace, message)
                await self.close_console_handle()
                self.set_note(message)
                self.notify(message, title="Dashboard launch failed", severity="error", timeout=6)
                return

            self.child_wait_task = asyncio.create_task(self.wait_for_child_loop())
            self.set_note("Launched Ralph loop in the background.")
            self.notify("Ralph loop started in the background.", title="Loop Started", timeout=3)

        async def wait_for_child_loop(self) -> None:
            if self.child_process is None:
                return

            process = self.child_process
            exit_code = await process.wait()
            self.child_exit_code = exit_code
            if self.child_process is process:
                self.child_process = None
            await self.close_console_handle()
            self.set_note(f"Background Ralph loop finished with exit code {exit_code}.")
            self.notify(
                f"Background Ralph loop exited with code {exit_code}.",
                title="Loop Finished",
                severity="warning" if exit_code else "information",
                timeout=4,
            )

        async def close_console_handle(self) -> None:
            if self.console_handle is not None and not self.console_handle.closed:
                await asyncio.to_thread(self.console_handle.close)
            self.console_handle = None

        async def stop_child_loop(self) -> None:
            if self.child_process is None or self.child_process.returncode is not None:
                self.set_note("No launched Ralph loop is running.")
                return

            assert self.child_process.pid is not None
            try:
                os.killpg(self.child_process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

            try:
                self.child_exit_code = await asyncio.wait_for(self.child_process.wait(), timeout=2)
            except asyncio.TimeoutError:
                try:
                    os.killpg(self.child_process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.child_exit_code = await self.child_process.wait()

            if self.child_wait_task is not None:
                self.child_wait_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await self.child_wait_task
                self.child_wait_task = None

            self.child_process = None
            await self.close_console_handle()
            self.set_note("Stopped the launched Ralph loop.")
            self.notify("Stopped the dashboard-launched Ralph loop.", title="Loop Stopped", timeout=3)

        def show_view(self, view_name: str, *, announce: bool = True) -> None:
            self.query_one(TabbedContent).active = view_name
            self.unread_counts[view_name] = 0
            self.update_tab_labels()
            self.update_split_layout()
            if self.search_open:
                search_input = self.search_input()
                search_input.value = self.query_one(f"#{view_name}-view", FileView).search_query()
                search_input.focus()
            if announce:
                self.set_note(f"Showing {VIEW_LABELS[view_name].lower()}.")

        def on_tabbed_content_tab_activated(self, event: TabbedContent.TabActivated) -> None:
            del event
            self.unread_counts[self.active_view_name()] = 0
            self.update_tab_labels()
            self.update_split_layout()
            if self.search_open:
                search_input = self.search_input()
                search_input.value = self.active_file_view().search_query()
                search_input.focus()
            if self.palette_open:
                self.update_palette_results(self.palette_input().value)
            self.update_status_strip()

        def on_input_changed(self, event: Input.Changed) -> None:
            if event.input.id == "search-input" and self.search_open:
                self.active_file_view().set_search_query(event.value)
                return
            if event.input.id == "palette-input" and self.palette_open:
                self.palette_selected = 0
                self.update_palette_results(event.value)

        def on_input_submitted(self, event: Input.Submitted) -> None:
            if event.input.id == "search-input":
                if event.value.strip():
                    matches = self.active_file_view().search_match_count()
                    self.set_note(f"Search locked in with {matches} matches.")
                else:
                    self.set_note("Search cleared.")
                self.set_search_open(False)
                return
            if event.input.id == "palette-input":
                self.run_palette_selection()

        def on_key(self, event: Key) -> None:
            if not self.palette_open:
                return
            if event.key == "down":
                self.move_palette_selection(1)
                event.stop()
            elif event.key == "up":
                self.move_palette_selection(-1)
                event.stop()

        def action_show_activity(self) -> None:
            self.show_view("activity")

        def action_show_progress(self) -> None:
            self.show_view("progress")

        def action_show_tasks(self) -> None:
            self.show_view("tasks")

        def action_show_signals(self) -> None:
            self.show_view("signals")

        def action_show_errors(self) -> None:
            self.show_view("errors")

        def action_show_console(self) -> None:
            self.show_view("console")

        def action_next_view(self) -> None:
            index = VIEW_ORDER.index(self.active_view_name())
            self.show_view(VIEW_ORDER[(index + 1) % len(VIEW_ORDER)])

        def action_previous_view(self) -> None:
            index = VIEW_ORDER.index(self.active_view_name())
            self.show_view(VIEW_ORDER[(index - 1) % len(VIEW_ORDER)])

        def action_scroll_up(self) -> None:
            self.active_file_view().scroll_line_up()

        def action_scroll_down(self) -> None:
            self.active_file_view().scroll_line_down()

        def action_page_up(self) -> None:
            self.active_file_view().scroll_page_up()

        def action_page_down(self) -> None:
            self.active_file_view().scroll_page_down()

        def action_scroll_home(self) -> None:
            self.active_file_view().scroll_home_fast()

        def action_scroll_end(self) -> None:
            self.active_file_view().scroll_end_fast()

        def action_toggle_follow(self) -> None:
            file_view = self.active_file_view()
            enabled = file_view.toggle_follow()
            if not file_view.follow_output:
                self.set_note(f"{VIEW_LABELS[self.active_view_name()]} does not use live follow.")
                return
            self.set_note(
                f"{VIEW_LABELS[self.active_view_name()]} follow is now {'live' if enabled else 'paused'}."
            )
            if self.split_mode:
                self.update_split_layout()

        def action_cycle_filter(self) -> None:
            mode_name = FILTER_LABELS[self.active_file_view().cycle_filter(backwards=False)]
            self.set_note(f"{VIEW_LABELS[self.active_view_name()]} filter set to {mode_name}.")
            if self.split_mode:
                self.update_split_layout()

        def action_cycle_filter_reverse(self) -> None:
            mode_name = FILTER_LABELS[self.active_file_view().cycle_filter(backwards=True)]
            self.set_note(f"{VIEW_LABELS[self.active_view_name()]} filter set to {mode_name}.")
            if self.split_mode:
                self.update_split_layout()

        def _next_companion_view(self, backwards: bool = False) -> str:
            order = list(COMPANION_ORDER)
            current = self.current_companion_view()
            index = order.index(current) if current in order else 0
            step = -1 if backwards else 1
            for offset in range(1, len(order) + 1):
                candidate = order[(index + offset * step) % len(order)]
                if candidate != self.active_view_name():
                    return candidate
            return current

        def action_toggle_split(self) -> None:
            self.split_mode = not self.split_mode
            if self.split_mode:
                self.companion_view_name = self.current_companion_view()
                self.update_split_layout()
                self.set_note(
                    f"Split view on with {VIEW_LABELS[self.current_companion_view()].lower()} as the buddy pane."
                )
            else:
                self.update_split_layout()
                self.set_note("Split view off.")

        def action_cycle_companion(self) -> None:
            if not self.split_mode:
                self.split_mode = True
            self.companion_view_name = self._next_companion_view(backwards=False)
            self.update_split_layout()
            self.set_note(f"Buddy pane switched to {VIEW_LABELS[self.current_companion_view()].lower()}.")

        def action_cycle_companion_reverse(self) -> None:
            if not self.split_mode:
                self.split_mode = True
            self.companion_view_name = self._next_companion_view(backwards=True)
            self.update_split_layout()
            self.set_note(f"Buddy pane switched to {VIEW_LABELS[self.current_companion_view()].lower()}.")

        def action_open_search(self) -> None:
            self.set_search_open(True)

        def action_open_palette(self) -> None:
            self.set_palette_open(True)

        def action_cancel_overlay(self) -> None:
            if self.palette_open:
                self.set_palette_open(False)
                self.set_note("Command palette closed.")
                return
            if self.search_open:
                self.set_search_open(False)
                self.set_note("Search bar closed.")

        def action_search_next(self) -> None:
            result = self.active_file_view().jump_to_search_result(backwards=False)
            self.set_note(result or "No search results in the current pane.")

        def action_search_previous(self) -> None:
            result = self.active_file_view().jump_to_search_result(backwards=True)
            self.set_note(result or "No search results in the current pane.")

        def action_jump_next_task(self) -> None:
            self.show_view("tasks", announce=False)
            result = self.query_one("#tasks-view", FileView).jump_to_unchecked_task(backwards=False)
            self.set_note(f"Jumped to task: {result[:72]}" if result else "No unchecked task found.")
            if self.split_mode:
                self.update_split_layout()

        def action_jump_previous_task(self) -> None:
            self.show_view("tasks", announce=False)
            result = self.query_one("#tasks-view", FileView).jump_to_unchecked_task(backwards=True)
            self.set_note(f"Jumped to task: {result[:72]}" if result else "No unchecked task found.")
            if self.split_mode:
                self.update_split_layout()

        def action_jump_next_signal(self) -> None:
            self.show_view("signals", announce=False)
            result = self.query_one("#signals-view", FileView).jump_to_signal_marker(backwards=False)
            self.set_note(
                f"Jumped to signal: {result[:72]}" if result else "No Ralph signal marker found."
            )
            if self.split_mode:
                self.update_split_layout()

        def action_jump_previous_signal(self) -> None:
            self.show_view("signals", announce=False)
            result = self.query_one("#signals-view", FileView).jump_to_signal_marker(backwards=True)
            self.set_note(
                f"Jumped to signal: {result[:72]}" if result else "No Ralph signal marker found."
            )
            if self.split_mode:
                self.update_split_layout()

        async def action_refresh_now(self) -> None:
            await self.refresh_dashboard_async()
            self.set_note("Manual refresh complete.")

        def action_toggle_help(self) -> None:
            self.help_expanded = not self.help_expanded
            self.update_help_strip()
            self.set_note("Help expanded." if self.help_expanded else "Help collapsed.")

        async def action_stop_loop(self) -> None:
            await self.stop_child_loop()

        def action_quit_dashboard(self) -> None:
            if self.child_process is not None and self.child_process.returncode is None:
                self.set_note("Loop still running. Press x first if you want to stop it.")
                return
            self.exit()

        def finalize(self) -> None:
            if self.child_wait_task is not None:
                self.child_wait_task.cancel()
                self.child_wait_task = None
            if self.console_handle is not None and not self.console_handle.closed:
                self.console_handle.close()
                self.console_handle = None
            if self.child_process is not None and self.child_process.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    assert self.child_process.pid is not None
                    os.killpg(self.child_process.pid, signal.SIGTERM)

    headless = os.environ.get("RALPH_TUI_HEADLESS") == "1"
    size = None
    raw_size = os.environ.get("RALPH_TUI_SIZE", "")
    if "x" in raw_size:
        try:
            width, height = raw_size.lower().split("x", 1)
            size = (int(width), int(height))
        except ValueError:
            size = None

    app = RalphDashboardApp(workspace=workspace, mode=mode, child_args=child_args)
    app.run(headless=headless, mouse=not headless, size=size)
    app.finalize()
    return app.child_exit_code


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    mode, workspace, child_args = normalize_args(args)

    state = load_dashboard_state(workspace)
    if args.snapshot:
        sys.stdout.write(render_snapshot(state))
        return 0

    return launch_textual_dashboard(workspace, mode, child_args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
