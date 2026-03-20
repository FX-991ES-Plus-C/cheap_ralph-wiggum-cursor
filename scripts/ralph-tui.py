#!/usr/bin/env python3
"""Ralph Wiggum Textual dashboard."""

from __future__ import annotations

import asyncio
import argparse
import contextlib
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

VIEW_ORDER = ("activity", "progress", "tasks", "signals", "errors", "console")
VIEW_LABELS = {
    "activity": "Activity",
    "progress": "Progress",
    "tasks": "Tasks",
    "signals": "Signals",
    "errors": "Errors",
    "console": "Console",
}

MOODS = (
    "turbo wiggle",
    "guardrails engaged",
    "snack-powered focus",
    "laser bonk mode",
    "tiny but mighty",
    "chaos with receipts",
)

MASCOTS = ("\\o/", "<o>", "o/", "\\o")


@dataclass
class FileViewState:
    body: str
    meta: str


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
        if "[x]" in stripped:
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

    rotate_threshold = 200000
    if token_count > 0:
        token_pct = int(token_count * 100 / rotate_threshold)
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


def build_view_state(path: Path, view_name: str) -> FileViewState:
    if not path.exists():
        return FileViewState(body=f"Waiting for {path.name}\n", meta="waiting")

    raw = read_file_text(path)
    lines = raw.splitlines()
    total_lines = len(lines)

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
        body_lines = lines if lines else ["(empty)"]
        meta = f"{path.name} · {total_lines} lines"

    body = "\n".join(body_lines).rstrip() + "\n"
    return FileViewState(body=body, meta=meta)


def load_dashboard_state(workspace: Path) -> DashboardState:
    ralph_dir = workspace / ".ralph"
    runtime = read_shell_env(ralph_dir / "runtime.env")
    session = read_shell_env(ralph_dir / ".last-session.env")
    task_file = select_task_file(workspace)
    done_count, total_count = count_task_progress(task_file)
    remaining_count = max(total_count - done_count, 0)
    token_count, token_pct = latest_token_summary(ralph_dir / "activity.log", session)

    latest_signals = []
    signals_file = ralph_dir / "signals.log"
    if signals_file.exists():
        latest_signals = signals_file.read_text(
            encoding="utf-8", errors="replace"
        ).splitlines()[-4:]

    view_paths = {
        "activity": ralph_dir / "activity.log",
        "progress": ralph_dir / "progress.md",
        "tasks": task_file,
        "signals": ralph_dir / "signals.log",
        "errors": ralph_dir / "errors.log",
        "console": ralph_dir / "tui-run.log",
    }

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
        views=views,
    )


def build_placeholder_state(workspace: Path) -> DashboardState:
    task_file = select_task_file(workspace)
    runtime = {
        "RALPH_RUNTIME_STATUS": "loading",
        "RALPH_RUNTIME_ITERATION": "0",
        "RALPH_RUNTIME_MODEL": "loading",
        "RALPH_RUNTIME_LAST_SIGNAL": "NONE",
        "RALPH_RUNTIME_LAST_EVENT": "Hydrating dashboard",
        "RALPH_RUNTIME_MODE": "monitor",
        "RALPH_RUNTIME_UPDATED_AT": "not yet",
    }
    views = {
        view_name: FileViewState(
            body=f"Loading {VIEW_LABELS[view_name]}...\n",
            meta="loading",
        )
        for view_name in VIEW_ORDER
    }
    return DashboardState(
        workspace=workspace,
        task_file=task_file,
        runtime=runtime,
        session={},
        done_count=0,
        total_count=0,
        remaining_count=0,
        next_task="Loading tasks...",
        token_count=0,
        token_pct=0,
        health_label="CHILL",
        latest_signals=[],
        views=views,
    )


def append_dashboard_error(workspace: Path, message: str) -> None:
    ralph_dir = workspace / ".ralph"
    ralph_dir.mkdir(parents=True, exist_ok=True)
    error_file = ralph_dir / "errors.log"
    timestamp = datetime.now().strftime("%H:%M:%S")
    with error_file.open("a", encoding="utf-8") as handle:
        handle.write(f"[{timestamp}] dashboard: {message}\n")


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
    parser.add_argument(
        "first",
        nargs="?",
        help="mode or workspace",
    )
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
    elif args.first:
        if workspace is None:
            workspace = args.first

    if workspace is None:
        workspace = "."

    return mode, Path(workspace).resolve(), list(args.child_args)


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
    from textual.widgets import Footer, Header, Static, TabPane, TabbedContent

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

        def compose(self) -> ComposeResult:
            yield Static("", classes="file-meta")
            with VerticalScroll():
                yield Static("", classes="file-body")

        def set_state(self, state: FileViewState) -> None:
            self.query_one(".file-meta", Static).update(state.meta)
            self.query_one(".file-body", Static).update(state.body)

        def scroll_line_up(self) -> None:
            self.query_one(VerticalScroll).scroll_up(animate=False)

        def scroll_line_down(self) -> None:
            self.query_one(VerticalScroll).scroll_down(animate=False)

        def scroll_page_up(self) -> None:
            self.query_one(VerticalScroll).scroll_page_up(animate=False)

        def scroll_page_down(self) -> None:
            self.query_one(VerticalScroll).scroll_page_down(animate=False)

        def scroll_home_fast(self) -> None:
            self.query_one(VerticalScroll).scroll_home(animate=False)

        def scroll_end_fast(self) -> None:
            self.query_one(VerticalScroll).scroll_end(animate=False)

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
            Binding("1", "show_activity", "1 Activity", show=False),
            Binding("2", "show_progress", "2 Progress", show=False),
            Binding("3", "show_tasks", "3 Tasks", show=False),
            Binding("4", "show_signals", "4 Signals", show=False),
            Binding("5", "show_errors", "5 Errors", show=False),
            Binding("6", "show_console", "6 Console", show=False),
            Binding("tab", "next_view", "Next View", show=False),
            Binding("shift+tab", "previous_view", "Prev View", show=False),
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
                with TabbedContent(id="views", initial="activity"):
                    with TabPane("1 Activity", id="activity"):
                        yield FileView(id="activity-view")
                    with TabPane("2 Progress", id="progress"):
                        yield FileView(id="progress-view")
                    with TabPane("3 Tasks", id="tasks"):
                        yield FileView(id="tasks-view")
                    with TabPane("4 Signals", id="signals"):
                        yield FileView(id="signals-view")
                    with TabPane("5 Errors", id="errors"):
                        yield FileView(id="errors-view")
                    with TabPane("6 Console", id="console"):
                        yield FileView(id="console-view")
                yield Static(id="status-strip")
            yield Footer()

        def on_mount(self) -> None:
            self.sub_title = str(self.workspace)
            if self.console_path.parent.exists():
                self.console_path.touch()
            self.schedule_refresh()
            self.set_interval(0.5, self.schedule_refresh)
            if self.mode == "loop":
                asyncio.create_task(self.start_child_loop())
            if self.smoke_exit:
                self.set_timer(0.2, self.exit)

        def active_view_name(self) -> str:
            return self.query_one(TabbedContent).active or "activity"

        def active_file_view(self) -> FileView:
            view_name = self.active_view_name()
            return self.query_one(f"#{view_name}-view", FileView)

        def schedule_refresh(self) -> None:
            if self.refresh_in_flight:
                return
            self.refresh_in_flight = True
            asyncio.create_task(self.refresh_dashboard_async())

        async def refresh_dashboard_async(self) -> None:
            try:
                self.tick += 1
                state = await asyncio.to_thread(load_dashboard_state, self.workspace)
                self.last_state = state
                self.update_cards()
                self.update_help_strip()
                self.update_status_strip()

                for view_name in VIEW_ORDER:
                    self.query_one(f"#{view_name}-view", FileView).set_state(
                        self.last_state.views[view_name]
                    )
            finally:
                self.refresh_in_flight = False

        def refresh_dashboard(self) -> None:
            """Backward-compatible sync entrypoint used by snapshot/headless tests."""
            self.tick += 1
            self.last_state = load_dashboard_state(self.workspace)
            self.update_cards()
            self.update_help_strip()
            self.update_status_strip()

            for view_name in VIEW_ORDER:
                self.query_one(f"#{view_name}-view", FileView).set_state(
                    self.last_state.views[view_name]
                )

        def update_cards(self) -> None:
            state = self.last_state
            mascot = MASCOTS[self.tick % len(MASCOTS)]
            mood = MOODS[self.tick % len(MOODS)]

            hero_lines = Group(
                Text(f"Ralph Dashboard  {mascot}", style="bold #fefae0"),
                Text(f"Mood: {mood}", style="bold #ffd166"),
                Text(f"Workspace: {self.workspace.name}", style="#f7f4ea"),
                Text(
                    "Status: "
                    f"{state.runtime['RALPH_RUNTIME_STATUS']}  "
                    f"Iteration: {state.runtime['RALPH_RUNTIME_ITERATION']}",
                    style="#bde0fe",
                ),
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
            progress_table.add_row(
                "Remaining",
                str(state.remaining_count),
            )
            progress_table.add_row(
                "Tokens",
                f"{state.token_count}/200000 ({state.token_pct}%)",
            )
            progress_table.add_row("Health", state.health_label)
            progress_table.add_row(
                "Next",
                state.next_task[:28] + ("..." if len(state.next_task) > 28 else ""),
            )

            latest_signal = state.runtime["RALPH_RUNTIME_LAST_SIGNAL"]
            latest_signal_lines = state.latest_signals[-3:] or ["No signals yet."]
            signal_lines = Group(
                Text(
                    f"Signal: {latest_signal}",
                    style="bold #90e0ef",
                ),
                *[
                    Text(line or " ", style="#f7f4ea", overflow="ellipsis")
                    for line in latest_signal_lines
                ],
            )

            self.query_one("#hero-card", Static).update(
                Panel(hero_lines, title="Mission Control", border_style="#2a9d8f")
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
                    "Keys: 1-6 jump views | tab/shift-tab or left/right switch panes | "
                    "up/down or j/k scroll | pgup/pgdn page | g/G jump | r refresh | "
                    "? toggle help | x stop launched loop | q quit"
                )
            else:
                message = "Press ? to reopen the control guide."
            self.query_one("#help-strip", Static).update(message)

        def update_status_strip(self) -> None:
            if self.child_process and self.child_process.returncode is None:
                child_state = "Background Ralph loop is running."
            elif self.mode == "loop":
                child_state = (
                    f"Background Ralph loop finished with exit code {self.child_exit_code}."
                )
            else:
                child_state = "Monitor mode: read-only dashboard."

            active = VIEW_LABELS[self.active_view_name()]
            state = self.last_state
            summary = (
                f"{self.note}  |  Active: {active}  |  "
                f"Mode: {state.runtime['RALPH_RUNTIME_MODE']}  |  "
                f"Model: {state.runtime['RALPH_RUNTIME_MODEL']}  |  "
                f"{child_state}"
            )
            self.query_one("#status-strip", Static).update(summary)

        def set_note(self, message: str) -> None:
            self.note = message
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
                return

            self.child_wait_task = asyncio.create_task(self.wait_for_child_loop())
            self.set_note("Launched Ralph loop in the background.")

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
                self.child_exit_code = await asyncio.wait_for(
                    self.child_process.wait(), timeout=2
                )
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

        def show_view(self, view_name: str) -> None:
            self.query_one(TabbedContent).active = view_name
            self.set_note(f"Showing {VIEW_LABELS[view_name].lower()}.")

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
            current = self.active_view_name()
            index = VIEW_ORDER.index(current)
            self.show_view(VIEW_ORDER[(index + 1) % len(VIEW_ORDER)])

        def action_previous_view(self) -> None:
            current = self.active_view_name()
            index = VIEW_ORDER.index(current)
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

        async def action_refresh_now(self) -> None:
            await self.refresh_dashboard_async()
            self.set_note("Manual refresh complete.")

        def action_toggle_help(self) -> None:
            self.help_expanded = not self.help_expanded
            self.set_note("Help expanded." if self.help_expanded else "Help collapsed.")
            self.update_help_strip()

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
