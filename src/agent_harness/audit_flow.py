from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

from .project_settings import ensure_project_config, load_project_config, project_max_dir


HISTORY_FILES = {
    "task": "task-history.jsonl",
    "test": "test-history.jsonl",
    "web": "web-history.jsonl",
    "browser": "browser-history.jsonl",
    "research": "research-history.jsonl",
    "notes": "project-notes.jsonl",
}

SUMMARY_FILE = "file-summaries.json"


def _workspace_path(project: Path, config: dict[str, Any]) -> Path:
    workspace_value = str(config.get("workspace") or "workspace")
    workspace = Path(workspace_value).expanduser()

    if workspace.is_absolute():
        return workspace.resolve()

    return (project / workspace).resolve()


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []

    records: list[dict[str, Any]] = []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue

        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue

        if isinstance(value, dict):
            records.append(value)

    return records


def _load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}

    try:
        value = json.loads(path.read_text(errors="replace"))
    except json.JSONDecodeError:
        return {}

    return value if isinstance(value, dict) else {}


def _parse_timestamp(value: str) -> datetime:
    if not value:
        return datetime.min

    cleaned = value.strip()

    try:
        return datetime.fromisoformat(cleaned)
    except ValueError:
        pass

    for fmt in [
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d %H:%M:%S",
        "%Y%m%d_%H%M%S",
    ]:
        try:
            return datetime.strptime(cleaned, fmt)
        except ValueError:
            continue

    return datetime.min


def _shorten(text: str, limit: int = 120) -> str:
    text = re.sub(r"\s+", " ", str(text).strip())
    if len(text) <= limit:
        return text
    return text[: limit - 3].rstrip() + "..."


def _event_title(source: str, record: dict[str, Any]) -> str:
    if source == "task":
        status = record.get("status", "")
        request = record.get("request", "")
        return f"task {status} {request}".strip()

    if source == "test":
        command = " ".join(str(part) for part in record.get("command", []))
        exit_code = record.get("exit_code", "")
        return f"test exit={exit_code} {command}".strip()

    if source == "web":
        op = record.get("op", "web")
        url = record.get("url", "")
        status = record.get("status", "")
        return f"web {op} {status} {url}".strip()

    if source == "browser":
        op = record.get("op", "browser")
        backend = record.get("backend", "?")
        url = record.get("url", "")
        return f"browser {op} [{backend}] {url}".strip()

    if source == "research":
        mode = record.get("mode", "research")
        title = record.get("title", "")
        saved = record.get("saved_path", "")
        return f"research {mode} {title} -> {saved}".strip()

    if source == "notes":
        kind = record.get("kind", "note")
        text = _shorten(record.get("text", ""))
        return f"note {kind} {text}".strip()

    if source == "summary":
        path = record.get("path", "")
        lines = record.get("line_count", "?")
        return f"summary {path} lines={lines}".strip()

    return _shorten(json.dumps(record, ensure_ascii=False))


def _record_ok(source: str, record: dict[str, Any]) -> bool:
    if "ok" in record:
        return bool(record.get("ok"))

    if source in {"notes", "summary"}:
        return True

    return True


def _collect_events(project: Path) -> list[dict[str, Any]]:
    max_dir = project_max_dir(project)
    events: list[dict[str, Any]] = []

    for source, filename in HISTORY_FILES.items():
        path = max_dir / filename
        for record in _load_jsonl(path):
            timestamp = str(record.get("timestamp", ""))
            events.append(
                {
                    "timestamp": timestamp,
                    "source": source,
                    "ok": _record_ok(source, record),
                    "title": _event_title(source, record),
                    "record": record,
                    "path": str(path),
                }
            )

    summaries = _load_json(max_dir / SUMMARY_FILE)
    for file_path, record in summaries.items():
        if not isinstance(record, dict):
            continue

        timestamp = str(record.get("timestamp", ""))
        item = dict(record)
        item.setdefault("path", file_path)

        events.append(
            {
                "timestamp": timestamp,
                "source": "summary",
                "ok": True,
                "title": _event_title("summary", item),
                "record": item,
                "path": str(max_dir / SUMMARY_FILE),
            }
        )

    events.sort(key=lambda item: _parse_timestamp(str(item.get("timestamp", ""))), reverse=True)
    return events


def _print_usage() -> None:
    print("Use:")
    print("  max audit")
    print("  max audit list")
    print("  max audit search <query>")
    print("  max audit show <number>")
    print("  max audit paths")
    print("  max audit export")
    print("  max timeline")


def _list_events(events: list[dict[str, Any]], limit: int = 20) -> int:
    if not events:
        print("No audit events yet.")
        return 1

    print("Project timeline")
    print("")

    for idx, event in enumerate(events[:limit], start=1):
        status = "OK" if event.get("ok") else "FAIL"
        timestamp = event.get("timestamp", "")
        source = event.get("source", "?")
        title = _shorten(event.get("title", ""), 160)
        print(f"{idx}. {status} {timestamp} [{source}] {title}")

    return 0


def _search_events(events: list[dict[str, Any]], query: str) -> int:
    query = query.strip().lower()
    if not query:
        print("Missing search query.")
        return 2

    matches: list[tuple[int, dict[str, Any]]] = []

    for idx, event in enumerate(events, start=1):
        haystack = json.dumps(event, ensure_ascii=False).lower()
        if query in haystack:
            matches.append((idx, event))

    if not matches:
        print("No matching audit events.")
        return 1

    print("Matching audit events")
    print("")

    for idx, event in matches[:30]:
        status = "OK" if event.get("ok") else "FAIL"
        timestamp = event.get("timestamp", "")
        source = event.get("source", "?")
        title = _shorten(event.get("title", ""), 180)
        print(f"{idx}. {status} {timestamp} [{source}] {title}")

    return 0


def _show_event(events: list[dict[str, Any]], raw_index: str) -> int:
    if not events:
        print("No audit events yet.")
        return 1

    try:
        index = int(raw_index)
    except ValueError:
        print("Event number must be an integer.")
        return 2

    if index < 1 or index > len(events):
        print(f"Audit event not found: {index}")
        return 1

    event = events[index - 1]

    print(f"Audit event {index}")
    print(f"Timestamp: {event.get('timestamp', '')}")
    print(f"Source: {event.get('source', '')}")
    print(f"Status: {'OK' if event.get('ok') else 'FAIL'}")
    print(f"History path: {event.get('path', '')}")
    print("")
    print(json.dumps(event.get("record", {}), indent=2, sort_keys=True, ensure_ascii=False))

    return 0


def _paths(project: Path, config: dict[str, Any]) -> int:
    max_dir = project_max_dir(project)
    workspace = _workspace_path(project, config)

    print("Audit paths")
    print("")
    print(f"Project: {project}")
    print(f"Workspace: {workspace}")
    print(f"Max dir: {max_dir}")
    print("")

    for source, filename in HISTORY_FILES.items():
        path = max_dir / filename
        exists = "yes" if path.exists() else "no"
        print(f"{source}: {path} exists={exists}")

    summary_path = max_dir / SUMMARY_FILE
    print(f"summary: {summary_path} exists={'yes' if summary_path.exists() else 'no'}")

    return 0


def _export_events(project: Path, events: list[dict[str, Any]]) -> int:
    if not events:
        print("No audit events to export.")
        return 1

    max_dir = project_max_dir(project)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = max_dir / f"audit-export-{stamp}.json"

    out_path.write_text(json.dumps(events, indent=2, sort_keys=True, ensure_ascii=False) + "\n")

    try:
        rel = out_path.relative_to(project).as_posix()
    except ValueError:
        rel = str(out_path)

    print(f"Audit export saved: {rel}")
    print(f"Events: {len(events)}")
    return 0


def audit_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)

    if not args:
        args = ["list"]

    command = args[0]

    if command in {"help", "-h", "--help"}:
        _print_usage()
        return 0

    if command == "paths":
        return _paths(project, config)

    events = _collect_events(project)

    if command in {"list", "ls", "timeline"}:
        return _list_events(events)

    if command in {"search", "find"}:
        return _search_events(events, " ".join(args[1:]))

    if command == "show":
        if len(args) < 2:
            print("Missing audit event number.")
            return 2
        return _show_event(events, args[1])

    if command == "export":
        return _export_events(project, events)

    print(f"Unknown audit command: {command}")
    _print_usage()
    return 2
