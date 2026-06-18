from __future__ import annotations

import json
from pathlib import Path

from .util import read_json


def workspace_snapshot(project: Path, max_files: int = 80) -> str:
    workspace = project / "workspace"

    if not workspace.exists():
        return "Workspace folder is missing."

    files = []

    for p in sorted(workspace.rglob("*")):
        if p.is_dir():
            continue
        rel = p.relative_to(workspace)
        if any(part in {"node_modules", ".git", "__pycache__", ".venv"} for part in rel.parts):
            continue
        files.append(str(rel))
        if len(files) >= max_files:
            break

    if not files:
        return "Workspace is empty."

    return "\n".join(f"- {f}" for f in files)


def memory_snapshot(project: Path) -> str:
    agent = project / ".agent"

    current_state = agent / "current_state.md"
    current_tail = ""
    if current_state.exists():
        current_tail = current_state.read_text(errors="replace")[-3000:]

    plan = read_json(agent / "plan.json", {})
    open_issues = read_json(agent / "open_issues.json", {"issues": []})
    commands = read_json(agent / "command_history.json", {"commands": []}).get("commands", [])
    last_commands = commands[-3:]

    return (
        "CURRENT STATE TAIL:\n"
        f"{current_tail}\n\n"
        "PLAN JSON:\n"
        f"{json.dumps(plan, indent=2)[:2000]}\n\n"
        "OPEN ISSUES:\n"
        f"{json.dumps(open_issues, indent=2)[:1200]}\n\n"
        "LAST COMMANDS:\n"
        f"{json.dumps(last_commands, indent=2)[:3000]}\n"
    )
