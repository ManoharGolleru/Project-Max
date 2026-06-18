#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v22_notes_memory.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v22_notes_memory_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py notes_flow.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/notes_flow.py <<'PY'
from __future__ import annotations

import ast
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

from .project_settings import ensure_project_config, load_project_config, project_max_dir


def _workspace_path(project: Path, config: dict[str, Any]) -> Path:
    workspace_value = str(config.get("workspace") or "workspace")
    workspace = Path(workspace_value).expanduser()

    if workspace.is_absolute():
        return workspace.resolve()

    return (project / workspace).resolve()


def _notes_path(project: Path) -> Path:
    return project_max_dir(project) / "project-notes.jsonl"


def _summaries_path(project: Path) -> Path:
    return project_max_dir(project) / "file-summaries.json"


def _research_history_path(project: Path) -> Path:
    return project_max_dir(project) / "research-history.jsonl"


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


def _write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in records))


def _load_notes(project: Path) -> list[dict[str, Any]]:
    return _load_jsonl(_notes_path(project))


def _save_notes(project: Path, config: dict[str, Any], records: list[dict[str, Any]]) -> None:
    max_items = 200
    history_cfg = config.get("history", {})
    if isinstance(history_cfg, dict):
        try:
            max_items = max(20, int(history_cfg.get("max_items", 100)) * 2)
        except (TypeError, ValueError):
            max_items = 200

    _write_jsonl(_notes_path(project), records[-max_items:])


def _load_summaries(project: Path) -> dict[str, Any]:
    path = _summaries_path(project)
    if not path.exists():
        return {}

    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}

    return value if isinstance(value, dict) else {}


def _save_summaries(project: Path, summaries: dict[str, Any]) -> None:
    _summaries_path(project).write_text(json.dumps(summaries, indent=2, sort_keys=True) + "\n")


def _print_usage() -> None:
    print("Use:")
    print("  max notes add \"note text\"")
    print("  max notes list")
    print("  max notes show <number>")
    print("  max notes search <query>")
    print("  max notes research")
    print("  max notes summarize <workspace-file>")
    print("  max notes summaries")


def _shorten(text: str, limit: int = 120) -> str:
    text = re.sub(r"\s+", " ", text.strip())
    if len(text) <= limit:
        return text
    return text[: limit - 3].rstrip() + "..."


def _add_note(project: Path, config: dict[str, Any], text: str) -> int:
    text = text.strip()
    if not text:
        print("Missing note text.")
        return 2

    records = _load_notes(project)
    record = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "kind": "note",
        "text": text,
    }
    records.append(record)
    _save_notes(project, config, records)

    print("Saved note.")
    print(f"{len(records)}. {_shorten(text)}")
    return 0


def _list_notes(project: Path) -> int:
    records = _load_notes(project)
    if not records:
        print("No project notes yet.")
        return 1

    print("Project notes")
    print("")
    for idx, record in enumerate(records, start=1):
        timestamp = record.get("timestamp", "")
        text = _shorten(str(record.get("text", "")))
        print(f"{idx}. {timestamp}  {text}")

    return 0


def _show_note(project: Path, raw_index: str) -> int:
    records = _load_notes(project)
    if not records:
        print("No project notes yet.")
        return 1

    try:
        index = int(raw_index)
    except ValueError:
        print("Note number must be an integer.")
        return 2

    if index < 1 or index > len(records):
        print(f"Note not found: {index}")
        return 1

    record = records[index - 1]
    print(f"Note {index}")
    print(f"Created: {record.get('timestamp', '')}")
    print("")
    print(str(record.get("text", "")).rstrip())
    return 0


def _search_notes(project: Path, query: str) -> int:
    query = query.strip().lower()
    if not query:
        print("Missing search query.")
        return 2

    records = _load_notes(project)
    matches: list[tuple[int, dict[str, Any]]] = []

    for idx, record in enumerate(records, start=1):
        haystack = json.dumps(record, ensure_ascii=False).lower()
        if query in haystack:
            matches.append((idx, record))

    if not matches:
        print("No matching notes.")
        return 1

    print("Matching notes")
    print("")
    for idx, record in matches:
        timestamp = record.get("timestamp", "")
        text = _shorten(str(record.get("text", "")), limit=180)
        print(f"{idx}. {timestamp}  {text}")

    return 0


def _list_research(project: Path) -> int:
    records = _load_jsonl(_research_history_path(project))
    if not records:
        print("No research history yet.")
        return 1

    print("Research notes")
    print("")
    for idx, record in enumerate(reversed(records[-20:]), start=1):
        ok = "OK" if record.get("ok") else "FAIL"
        mode = record.get("mode", "?")
        title = record.get("title", "?")
        saved = record.get("saved_path", "")
        source_count = record.get("ok_source_count", record.get("source_count", "?"))
        print(f"{idx}. {ok} {mode} {title} sources={source_count} -> {saved}")

    return 0


def _resolve_workspace_file(project: Path, config: dict[str, Any], raw_path: str) -> Path:
    workspace = _workspace_path(project, config)
    candidate = Path(raw_path).expanduser()

    if candidate.is_absolute():
        resolved = candidate.resolve()
    else:
        resolved = (workspace / candidate).resolve()

    try:
        resolved.relative_to(workspace)
    except ValueError:
        raise ValueError(f"File must be inside workspace: {workspace}")

    return resolved


def _python_static_summary(path: Path, text: str) -> dict[str, Any]:
    functions: list[str] = []
    classes: list[str] = []
    imports: list[str] = []
    has_argparse = "argparse" in text

    try:
        tree = ast.parse(text)
    except SyntaxError:
        return {
            "parse_ok": False,
            "functions": functions,
            "classes": classes,
            "imports": imports,
            "has_argparse": has_argparse,
        }

    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            functions.append(node.name)
        elif isinstance(node, ast.ClassDef):
            classes.append(node.name)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                imports.append(alias.name)
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            imports.append(module)

    return {
        "parse_ok": True,
        "functions": sorted(set(functions)),
        "classes": sorted(set(classes)),
        "imports": sorted(set(imports)),
        "has_argparse": has_argparse,
    }


def _summarize_file(project: Path, config: dict[str, Any], raw_path: str) -> int:
    try:
        path = _resolve_workspace_file(project, config, raw_path)
    except ValueError as exc:
        print(str(exc))
        return 2

    if not path.exists() or not path.is_file():
        print(f"File not found: {path}")
        return 1

    workspace = _workspace_path(project, config)
    rel = path.relative_to(workspace).as_posix()

    try:
        text = path.read_text(errors="replace")
    except Exception as exc:
        print(f"Could not read file: {exc}")
        return 1

    lines = text.splitlines()
    nonempty = [line for line in lines if line.strip()]

    summary: dict[str, Any] = {
        "path": rel,
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "bytes": path.stat().st_size,
        "line_count": len(lines),
        "nonempty_line_count": len(nonempty),
        "extension": path.suffix,
        "first_lines": lines[:5],
    }

    if path.suffix == ".py":
        summary["python"] = _python_static_summary(path, text)

    summaries = _load_summaries(project)
    summaries[rel] = summary
    _save_summaries(project, summaries)

    print(f"Saved file summary: {rel}")
    print(f"Lines: {summary['line_count']}")
    print(f"Bytes: {summary['bytes']}")

    py = summary.get("python")
    if isinstance(py, dict):
        print(f"Python parse ok: {py.get('parse_ok')}")
        print("Functions: " + ", ".join(py.get("functions", [])))
        print("Classes: " + ", ".join(py.get("classes", [])))
        print("Imports: " + ", ".join(py.get("imports", [])))

    return 0


def _list_summaries(project: Path) -> int:
    summaries = _load_summaries(project)
    if not summaries:
        print("No file summaries yet.")
        return 1

    print("File summaries")
    print("")
    for path, item in sorted(summaries.items()):
        line_count = item.get("line_count", "?")
        timestamp = item.get("timestamp", "")
        extra = ""
        py = item.get("python")
        if isinstance(py, dict):
            funcs = py.get("functions", [])
            if funcs:
                extra = " functions=" + ",".join(funcs[:6])
        print(f"- {path} lines={line_count} updated={timestamp}{extra}")

    return 0


def notes_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)

    if not args or args[0] in {"help", "-h", "--help"}:
        _print_usage()
        return 0

    command = args[0]

    if command in {"add", "remember"}:
        return _add_note(project, config, " ".join(args[1:]))

    if command in {"list", "ls"}:
        return _list_notes(project)

    if command == "show":
        if len(args) < 2:
            print("Missing note number.")
            return 2
        return _show_note(project, args[1])

    if command in {"search", "find"}:
        return _search_notes(project, " ".join(args[1:]))

    if command in {"research", "research-notes"}:
        return _list_research(project)

    if command in {"summarize", "summary"}:
        if len(args) < 2:
            print("Missing workspace file path.")
            print("Example: max notes summarize calc2.py")
            return 2
        return _summarize_file(project, config, args[1])

    if command in {"summaries", "file-summaries"}:
        return _list_summaries(project)

    print(f"Unknown notes command: {command}")
    _print_usage()
    return 2
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

import_line = "from .notes_flow import notes_project as direct_notes_project"

if import_line not in text:
    markers = [
        "from .research_flow import research_project as direct_research_project\n",
        "from .browser_flow import browser_project as direct_browser_project\n",
        "from .web_flow import web_project as direct_web_project\n",
        "from .project_settings import config_project as direct_config_project\n",
        "from .skill_manager import skills_command as max_skills_command\n",
    ]
    for marker in markers:
        if marker in text:
            text = text.replace(marker, marker + import_line + "\n", 1)
            break
    else:
        future = "from __future__ import annotations\n"
        if future in text:
            text = text.replace(future, future + import_line + "\n", 1)
        else:
            raise SystemExit("Could not find safe import location in max_cli.py")

if '"notes": {' not in text:
    markers = [
        '    "research": {',
        '    "browser": {',
        '    "web": {',
        '    "read": {',
    ]
    entry = '''    "notes": {
        "aliases": ["memory"],
        "summary": "Save project notes and simple file summaries.",
        "usage": "max notes [add|list|show|search|research|summarize|summaries]",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
'''
    for marker in markers:
        if marker in text:
            text = text.replace(marker, entry + marker, 1)
            break
    else:
        raise SystemExit("Could not find COMMANDS insertion point for notes.")

if "def _direct_notes(" not in text:
    marker = "def main(argv: list[str] | None = None) -> int:\n"
    func = '''\n\ndef _direct_notes(args: list[str]) -> int:\n    project, rest = _direct_project_and_rest(args)\n    if project is None:\n        ui.fail("No project selected.")\n        print("Use: max use <project> or max new <project>")\n        return 2\n    return direct_notes_project(project, rest)\n\n\n'''
    if marker not in text:
        raise SystemExit("Could not find main() in max_cli.py")
    text = text.replace(marker, func + marker, 1)

branch = '''    if argv and argv[0] in {"notes", "memory"}:\n        return _direct_notes(argv[1:])\n\n'''

if branch not in text:
    markers = [
        '    if argv and argv[0] in {"research", "lookup"}:\n',
        '    if argv and argv[0] in {"browser", "chromium"}:\n',
        '    if argv and argv[0] in {"web", "internet", "url"}:\n',
        '    if argv and argv[0] in {"config", "settings", "set"}:\n',
        '    if argv and argv[0] in {"plan", "outline"}:\n',
    ]
    for marker in markers:
        if marker in text:
            text = text.replace(marker, branch + marker, 1)
            break
    else:
        raise SystemExit("Could not find direct command section in main().")

if '("max notes summarize calc2.py", "Save a lightweight file summary")' not in text:
    text = text.replace(
        '("max research \\"python argparse examples\\"", "Collect sources into research notes"),',
        '("max research \\"python argparse examples\\"", "Collect sources into research notes"),\n        ("max notes summarize calc2.py", "Save a lightweight file summary"),',
    )

text = text.replace(
    '"read", "search", "web", "browser", "research", "index"',
    '"read", "search", "web", "browser", "research", "notes", "index"',
)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.22 notes + memory-lite installed."
echo ""
echo "Try:"
echo "  max notes add \"v21c research search works\""
echo "  max notes list"
echo "  max notes show 1"
echo "  max notes search research"
echo "  max notes research"
echo "  max notes summarize calc2.py"
echo "  max notes summaries"
