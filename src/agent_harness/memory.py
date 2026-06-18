from __future__ import annotations

from pathlib import Path

from .util import now_ts, read_json, write_json


def show_memory(project: Path) -> None:
    agent = project / ".agent"

    print(f"Memory folder: {agent}")

    for p in sorted(agent.rglob("*")):
        if p.is_file():
            rel = p.relative_to(agent)
            print(f"- {rel}")


def append_command_history(project: Path, result: dict) -> None:
    p = project / ".agent" / "command_history.json"
    data = read_json(p, {"commands": []})
    data.setdefault("commands", []).append(result)
    write_json(p, data)


def update_current_state(project: Path, text: str) -> None:
    p = project / ".agent" / "current_state.md"

    with p.open("a", encoding="utf-8") as f:
        f.write(f"\n## {now_ts()}\n\n{text}\n")
