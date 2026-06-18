from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .util import now_ts, write_json


def sessions_root(project: Path) -> Path:
    root = project / ".agent" / "sessions"
    root.mkdir(parents=True, exist_ok=True)
    return root


def make_session_id() -> str:
    return "session_" + time.strftime("%Y%m%d_%H%M%S")


def latest_file(project: Path) -> Path:
    return sessions_root(project) / "latest"


def create_session(project: Path, title: str = "Max session") -> str:
    sid = make_session_id()
    sdir = sessions_root(project) / sid
    sdir.mkdir(parents=True, exist_ok=True)

    meta = {
        "session_id": sid,
        "title": title,
        "created_at": now_ts(),
        "updated_at": now_ts(),
        "project": str(project),
    }

    write_json(sdir / "meta.json", meta)
    (sdir / "transcript.jsonl").touch()
    (sdir / "events.jsonl").touch()
    (sdir / "summary.md").write_text(f"# {title}\n\nCreated: {meta['created_at']}\n")
    latest_file(project).write_text(sid)

    return sid


def get_latest_session_id(project: Path) -> str | None:
    lf = latest_file(project)
    if not lf.exists():
        return None

    sid = lf.read_text().strip()
    if not sid:
        return None

    if not (sessions_root(project) / sid).exists():
        return None

    return sid


def ensure_session(project: Path, title: str = "Max session", session_id: str | None = None) -> str:
    root = sessions_root(project)

    if session_id:
        if (root / session_id).exists():
            latest_file(project).write_text(session_id)
            return session_id
        return create_session(project, title=title)

    latest = get_latest_session_id(project)
    if latest:
        return latest

    return create_session(project, title=title)


def session_dir(project: Path, session_id: str | None = None) -> Path:
    sid = ensure_session(project, session_id=session_id)
    return sessions_root(project) / sid


def append_jsonl(path: Path, obj: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def log_event(project: Path, event_type: str, data: dict[str, Any], session_id: str | None = None) -> str:
    sid = ensure_session(project, session_id=session_id)
    sdir = sessions_root(project) / sid

    event = {
        "timestamp": now_ts(),
        "type": event_type,
        "data": data,
    }

    append_jsonl(sdir / "events.jsonl", event)

    meta_path = sdir / "meta.json"
    try:
        meta = json.loads(meta_path.read_text())
    except Exception:
        meta = {"session_id": sid}
    meta["updated_at"] = now_ts()
    write_json(meta_path, meta)

    return sid


def log_message(project: Path, role: str, content: str, session_id: str | None = None) -> str:
    sid = ensure_session(project, session_id=session_id)
    sdir = sessions_root(project) / sid

    msg = {
        "timestamp": now_ts(),
        "role": role,
        "content": content,
    }

    append_jsonl(sdir / "transcript.jsonl", msg)

    return sid


def list_sessions(project: Path) -> list[dict[str, Any]]:
    root = sessions_root(project)
    items: list[dict[str, Any]] = []

    for sdir in sorted(root.glob("session_*"), reverse=True):
        meta_path = sdir / "meta.json"
        try:
            meta = json.loads(meta_path.read_text())
        except Exception:
            meta = {
                "session_id": sdir.name,
                "title": sdir.name,
                "created_at": "",
                "updated_at": "",
            }

        transcript = sdir / "transcript.jsonl"
        count = 0
        if transcript.exists():
            count = len(transcript.read_text(errors="replace").splitlines())

        meta["message_count"] = count
        items.append(meta)

    return items


def print_sessions(project: Path) -> None:
    items = list_sessions(project)

    if not items:
        print("No sessions yet.")
        return

    latest = get_latest_session_id(project)

    print("")
    print("Max sessions")
    print("=" * 72)

    for item in items:
        marker = "*" if item.get("session_id") == latest else " "
        print(
            f"{marker} {item.get('session_id')}  "
            f"{item.get('updated_at', '')}  "
            f"{item.get('message_count', 0)} message(s)"
        )

    print("")
    print("* = latest session")
    print("")


def print_session(project: Path, session_id: str | None = None, tail: int = 40) -> None:
    sid = session_id or get_latest_session_id(project)

    if not sid:
        print("No session found.")
        return

    sdir = sessions_root(project) / sid

    if not sdir.exists():
        print(f"Session not found: {sid}")
        return

    print("")
    print(f"Session: {sid}")
    print("=" * 72)

    transcript = sdir / "transcript.jsonl"

    if not transcript.exists():
        print("No transcript found.")
        return

    lines = transcript.read_text(errors="replace").splitlines()
    lines = lines[-tail:]

    for line in lines:
        try:
            item = json.loads(line)
            role = item.get("role", "")
            content = item.get("content", "")
            ts = item.get("timestamp", "")
            print("")
            print(f"[{role}] {ts}")
            print(content)
        except Exception:
            print(line)

    print("")
