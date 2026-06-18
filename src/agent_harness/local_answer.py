from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .config import load_config
from .sessions import log_event, log_message
from .util import read_json


def _workspace(project: Path) -> Path:
    return project / "workspace"


def _agent(project: Path) -> Path:
    return project / ".agent"


def _file_count(project: Path) -> tuple[int, int]:
    workspace = _workspace(project)
    files = 0
    dirs = 0

    if not workspace.exists():
        return 0, 0

    for p in workspace.rglob("*"):
        rel = p.relative_to(workspace)
        if any(part in {"node_modules", ".git", "__pycache__", ".venv"} for part in rel.parts):
            continue
        if p.is_file():
            files += 1
        elif p.is_dir():
            dirs += 1

    return files, dirs


def files_text(project: Path, max_items: int = 80) -> str:
    workspace = _workspace(project)

    if not workspace.exists():
        return f"The workspace folder does not exist yet:\n{workspace}"

    items: list[str] = []

    for p in sorted(workspace.rglob("*")):
        rel = p.relative_to(workspace)
        if any(part in {"node_modules", ".git", "__pycache__", ".venv"} for part in rel.parts):
            continue

        if p.is_dir():
            continue

        try:
            size = p.stat().st_size
        except Exception:
            size = 0

        items.append(f"- {rel} ({size} bytes)")

        if len(items) >= max_items:
            break

    if not items:
        return (
            f"The workspace is empty.\n\n"
            f"Workspace path:\n{workspace}\n\n"
            "There are no project files yet inside `workspace/`."
        )

    files, dirs = _file_count(project)

    more = ""
    if files > len(items):
        more = f"\n\nShowing {len(items)} of {files} files."

    return (
        f"Workspace path:\n{workspace}\n\n"
        f"Found {files} file(s) and {dirs} folder(s).\n\n"
        "Files:\n"
        + "\n".join(items)
        + more
    )


def last_command_text(project: Path) -> str:
    data = read_json(_agent(project) / "command_history.json", {"commands": []})
    commands = data.get("commands", [])

    if not commands:
        return "No commands have been run through Max yet."

    last = commands[-1]

    return (
        "Last command:\n\n"
        f"Command: {last.get('command')}\n"
        f"OK: {last.get('ok')}\n"
        f"Blocked: {last.get('blocked')}\n"
        f"Exit code: {last.get('exit_code')}\n"
        f"Time: {last.get('timestamp', '')}\n\n"
        f"stdout:\n{(last.get('stdout') or '').strip() or '[empty]'}\n\n"
        f"stderr:\n{(last.get('stderr') or '').strip() or '[empty]'}"
    )


def memory_text(project: Path) -> str:
    agent = _agent(project)

    if not agent.exists():
        return f"No `.agent/` memory folder found at:\n{agent}"

    files = []

    for p in sorted(agent.rglob("*")):
        if p.is_file():
            files.append(f"- {p.relative_to(agent)}")

    if not files:
        return f"The memory folder exists but has no files:\n{agent}"

    return (
        f"Memory folder:\n{agent}\n\n"
        "Memory files:\n"
        + "\n".join(files[:120])
    )


def model_text(project: Path) -> str:
    global_cfg = load_config()
    project_cfg = read_json(project / "agent.config.json", {})

    model = project_cfg.get("model") or global_cfg.get("model")
    context = project_cfg.get("context") or global_cfg.get("default_context")
    temp = project_cfg.get("temperature") or global_cfg.get("temperature")
    ram_limit = project_cfg.get("ram_limit_gb") or global_cfg.get("ram_limit_gb")

    return (
        "Current model settings:\n\n"
        f"Model: {model}\n"
        f"Context: {context}\n"
        f"Temperature: {temp}\n"
        f"RAM limit: {ram_limit} GB\n\n"
        "This is read from the project config first, then the global Max config."
    )


def status_text(project: Path) -> str:
    agent = _agent(project)
    workspace = _workspace(project)

    plan = read_json(agent / "plan.json", {})
    open_issues = read_json(agent / "open_issues.json", {"issues": []})
    completed = read_json(agent / "completed_steps.json", {"steps": []})
    commands = read_json(agent / "command_history.json", {"commands": []}).get("commands", [])
    files, dirs = _file_count(project)

    last = commands[-1] if commands else None

    lines = [
        "Project status:",
        "",
        f"Project: {project}",
        f"Workspace: {workspace}",
        f"Memory: {agent}",
        "",
        f"Workspace files: {files}",
        f"Workspace folders: {dirs}",
        f"Plan goal: {plan.get('goal', 'none')}",
        f"Plan steps: {len(plan.get('steps', []))}",
        f"Open issues: {len(open_issues.get('issues', []))}",
        f"Completed steps: {len(completed.get('steps', []))}",
        f"Commands run: {len(commands)}",
    ]

    if last:
        lines.extend(
            [
                "",
                "Last command:",
                f"  {last.get('command')}",
                f"  OK: {last.get('ok')}",
                f"  Blocked: {last.get('blocked')}",
            ]
        )

    return "\n".join(lines)


def paths_text(project: Path) -> str:
    return (
        "Current Max paths:\n\n"
        f"Project:\n{project}\n\n"
        f"Workspace:\n{_workspace(project)}\n\n"
        f"Memory:\n{_agent(project)}"
    )




def info_text(project: Path) -> str:
    return (
        status_text(project)
        + "\n\n"
        + model_text(project)
        + "\n\n"
        + paths_text(project)
    )


def _contains_any(text: str, phrases: list[str]) -> bool:
    return any(p in text for p in phrases)


def local_answer(project: Path, prompt: str) -> dict[str, Any] | None:
    t0 = time.time()
    lower = prompt.strip().lower()

    if not lower:
        return None

    # File/project contents
    if _contains_any(
        lower,
        [
            "what is in this project",
            "what is in the project",
            "what's in this project",
            "what is inside this project",
            "what files",
            "files are here",
            "what is here",
            "list files",
            "show files",
            "workspace empty",
            "anything in this project",
            "what is in the workspace",
            "what's in the workspace",
        ],
    ):
        reply = files_text(project)
        intent = "files"

    # Status
    elif _contains_any(
        lower,
        [
            "status",
            "current state",
            "current status",
            "what is going on",
            "where are we",
            "project state",
            "overview",
        ],
    ):
        reply = status_text(project)
        intent = "status"

    # Last command/history
    elif _contains_any(
        lower,
        [
            "last command",
            "previous command",
            "recent command",
            "what command",
            "command history",
            "last thing",
        ],
    ):
        reply = last_command_text(project)
        intent = "last_command"

    # Model/config
    elif _contains_any(
        lower,
        [
            "what model",
            "which model",
            "model am i using",
            "qwen",
            "context size",
            "temperature",
            "ram limit",
        ],
    ):
        reply = model_text(project)
        intent = "model"

    # Memory
    elif _contains_any(
        lower,
        [
            "memory",
            "agent memory",
            ".agent",
            "memory files",
        ],
    ):
        reply = memory_text(project)
        intent = "memory"

    # Paths
    elif _contains_any(
        lower,
        [
            "where is this project",
            "project path",
            "workspace path",
            "where is workspace",
            "where is the memory",
        ],
    ):
        reply = paths_text(project)
        intent = "paths"

    else:
        return None

    elapsed = round(time.time() - t0, 4)

    return {
        "source": "local",
        "intent": intent,
        "reply": reply,
        "duration_sec": elapsed,
    }


def print_local_answer(result: dict[str, Any]) -> None:
    print("")
    print(f"Max [local, {result.get('duration_sec', 0):.2f}s]")
    print("=" * 72)
    print(result["reply"])
    print("")


def answer_local_and_log(project: Path, prompt: str, result: dict[str, Any], interactive: bool = True) -> dict[str, Any]:
    log_message(project, "user", prompt)
    log_message(project, "assistant", result["reply"])
    log_event(project, "local_answer", result)

    if interactive:
        print_local_answer(result)

    return {
        "reply": result["reply"],
        "source": "local",
        "intent": result.get("intent"),
        "duration_sec": result.get("duration_sec"),
        "need_command": False,
        "suggested_command": "",
        "reason": "Answered locally without model call.",
        "command_result": None,
    }
