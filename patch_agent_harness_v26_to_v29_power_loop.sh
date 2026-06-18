#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v26_to_v29_power_loop.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v26_to_v29_power_loop_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py power_flow.py audit_flow.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/power_flow.py <<'PY'
from __future__ import annotations

import json
import re
import shlex
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

from .project_settings import ensure_project_config, load_project_config, project_max_dir


HISTORY_FILES = {
    "test": "test-history.jsonl",
    "task": "task-history.jsonl",
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


def _write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in records))


def _load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}

    try:
        value = json.loads(path.read_text(errors="replace"))
    except json.JSONDecodeError:
        return {}

    return value if isinstance(value, dict) else {}


def _shorten(text: Any, limit: int = 160) -> str:
    value = re.sub(r"\s+", " ", str(text).strip())
    if len(value) <= limit:
        return value
    return value[: limit - 3].rstrip() + "..."


def _history_path(project: Path, name: str) -> Path:
    return project_max_dir(project) / HISTORY_FILES[name]


def _task_history_path(project: Path) -> Path:
    return _history_path(project, "task")


def _load_tasks(project: Path) -> list[dict[str, Any]]:
    return _load_jsonl(_task_history_path(project))


def _save_tasks(project: Path, config: dict[str, Any], records: list[dict[str, Any]]) -> None:
    max_items = 100
    history_cfg = config.get("history", {})
    if isinstance(history_cfg, dict):
        try:
            max_items = int(history_cfg.get("max_items", 100))
        except (TypeError, ValueError):
            max_items = 100

    _write_jsonl(_task_history_path(project), records[-max_items:])


def _append_task(project: Path, config: dict[str, Any], record: dict[str, Any]) -> dict[str, Any]:
    records = _load_tasks(project)
    record = dict(record)
    record.setdefault("timestamp", datetime.now().isoformat(timespec="seconds"))
    record.setdefault("id", len(records) + 1)
    records.append(record)
    _save_tasks(project, config, records)
    return record


def _workspace_tree(workspace: Path, max_depth: int = 2, max_items: int = 80) -> list[str]:
    if not workspace.exists():
        return [f"(workspace not found: {workspace})"]

    lines: list[str] = []
    count = 0

    def walk(path: Path, prefix: str, depth: int) -> None:
        nonlocal count
        if depth > max_depth or count >= max_items:
            return

        children = [
            child
            for child in sorted(path.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
            if child.name not in {"__pycache__", ".pytest_cache", ".git", "downloads", "browser-artifacts"}
        ]

        for idx, child in enumerate(children):
            if count >= max_items:
                return

            last = idx == len(children) - 1
            branch = "└── " if last else "├── "
            lines.append(prefix + branch + child.name + ("/" if child.is_dir() else ""))
            count += 1

            if child.is_dir():
                next_prefix = prefix + ("    " if last else "│   ")
                walk(child, next_prefix, depth + 1)

    lines.append(workspace.name + "/")
    walk(workspace, "", 1)

    if count >= max_items:
        lines.append(f"... truncated after {max_items} items")

    return lines


def _latest(records: list[dict[str, Any]], n: int) -> list[dict[str, Any]]:
    return list(reversed(records[-n:]))


def _last_failed_test(project: Path) -> dict[str, Any] | None:
    tests = _load_jsonl(_history_path(project, "test"))
    for record in reversed(tests):
        try:
            exit_code = int(record.get("exit_code", 0))
        except (TypeError, ValueError):
            exit_code = 0
        if exit_code != 0:
            return record
    return None


def _last_test(project: Path) -> dict[str, Any] | None:
    tests = _load_jsonl(_history_path(project, "test"))
    return tests[-1] if tests else None


def _command_text(command: Any) -> str:
    if isinstance(command, list):
        return " ".join(str(part) for part in command)
    return str(command or "")


def _available_commands() -> list[str]:
    return [
        "max files",
        "max read <file>",
        "max search <term>",
        "max run <file.py> [args]",
        "max test [command]",
        "max web read <url>",
        "max browser screenshot <url>",
        "max research \"query\"",
        "max notes summarize <file>",
        "max audit",
        "max shell",
        "max change \"request\"",
        "max fix",
        "max task \"request\"",
    ]


def _build_context_text(
    project: Path,
    config: dict[str, Any],
    mode: str = "brief",
    task_request: str = "",
) -> str:
    workspace = _workspace_path(project, config)
    max_dir = project_max_dir(project)

    lines: list[str] = []
    lines.append("# Max project context")
    lines.append("")
    lines.append(f"Created: {datetime.now().isoformat(timespec='seconds')}")
    lines.append(f"Project: {project.name}")
    lines.append(f"Project path: {project}")
    lines.append(f"Workspace path: {workspace}")
    lines.append(f"Workspace exists: {workspace.exists()}")

    if task_request:
        lines.append("")
        lines.append("## Current request")
        lines.append(task_request)

    lines.append("")
    lines.append("## Permissions")
    lines.append(f"allow_network: {config.get('allow_network')}")
    lines.append(f"allow_browser: {config.get('allow_browser')}")
    lines.append(f"allow_downloads: {config.get('allow_downloads')}")

    lines.append("")
    lines.append("## Workspace tree")
    lines.extend(_workspace_tree(workspace, max_depth=3 if mode == "full" else 2))

    summaries = _load_json(max_dir / SUMMARY_FILE)
    if summaries:
        lines.append("")
        lines.append("## File summaries")
        for path, item in sorted(summaries.items()):
            if not isinstance(item, dict):
                continue
            line_count = item.get("line_count", "?")
            timestamp = item.get("timestamp", "")
            line = f"- {path}, lines={line_count}, updated={timestamp}"
            py = item.get("python")
            if isinstance(py, dict):
                funcs = py.get("functions", [])
                classes = py.get("classes", [])
                imports = py.get("imports", [])
                if funcs:
                    line += ", functions=" + ",".join(str(x) for x in funcs[:8])
                if classes:
                    line += ", classes=" + ",".join(str(x) for x in classes[:5])
                if imports and mode == "full":
                    line += ", imports=" + ",".join(str(x) for x in imports[:8])
            lines.append(line)

    notes = _load_jsonl(_history_path(project, "notes"))
    if notes:
        lines.append("")
        lines.append("## Recent project notes")
        for record in _latest(notes, 5 if mode == "brief" else 12):
            lines.append(f"- {record.get('timestamp', '')}: {_shorten(record.get('text', ''), 220)}")

    research = _load_jsonl(_history_path(project, "research"))
    if research:
        lines.append("")
        lines.append("## Recent research")
        for record in _latest(research, 5 if mode == "brief" else 12):
            lines.append(
                f"- {record.get('timestamp', '')}: {record.get('mode', '')} "
                f"{_shorten(record.get('title', ''), 120)} -> {record.get('saved_path', '')}"
            )

    last_test = _last_test(project)
    if last_test:
        lines.append("")
        lines.append("## Last test")
        status = "PASS" if int(last_test.get("exit_code", 1)) == 0 else "FAIL"
        lines.append(f"{status}: {_command_text(last_test.get('command'))}")
        lines.append(f"exit_code: {last_test.get('exit_code')}")
        if last_test.get("stderr_tail"):
            lines.append("stderr_tail:")
            lines.append(_shorten(last_test.get("stderr_tail", ""), 800))

    failed = _last_failed_test(project)
    if failed:
        lines.append("")
        lines.append("## Last failed test")
        lines.append(f"Command: {_command_text(failed.get('command'))}")
        lines.append(f"Exit code: {failed.get('exit_code')}")
        if failed.get("stdout_tail"):
            lines.append("stdout_tail:")
            lines.append(_shorten(failed.get("stdout_tail", ""), 800))
        if failed.get("stderr_tail"):
            lines.append("stderr_tail:")
            lines.append(_shorten(failed.get("stderr_tail", ""), 1200))

    tasks = _load_tasks(project)
    if tasks:
        lines.append("")
        lines.append("## Recent tasks")
        for record in _latest(tasks, 5 if mode == "brief" else 12):
            lines.append(
                f"- #{record.get('id')} {record.get('timestamp', '')} "
                f"{record.get('status', '')}: {_shorten(record.get('request', ''), 180)}"
            )

    audits: list[dict[str, Any]] = []
    for name in ["test", "web", "browser", "research", "notes", "task"]:
        for record in _load_jsonl(_history_path(project, name)):
            item = dict(record)
            item["_source"] = name
            audits.append(item)

    if audits:
        audits = audits[-8 if mode == "brief" else -20:]
        lines.append("")
        lines.append("## Recent activity")
        for record in reversed(audits):
            src = record.get("_source", "?")
            timestamp = record.get("timestamp", "")
            if src == "test":
                desc = f"test exit={record.get('exit_code')} {_command_text(record.get('command'))}"
            elif src == "research":
                desc = f"research {record.get('title')} -> {record.get('saved_path')}"
            elif src == "task":
                desc = f"task {record.get('status')} {_shorten(record.get('request', ''), 100)}"
            elif src == "notes":
                desc = f"note {_shorten(record.get('text', ''), 100)}"
            else:
                desc = f"{src} {record.get('op', '')} {record.get('url', '')}"
            lines.append(f"- {timestamp} [{src}] {_shorten(desc, 220)}")

    lines.append("")
    lines.append("## Available commands")
    for command in _available_commands():
        lines.append(f"- {command}")

    return "\n".join(lines).rstrip() + "\n"


def power_context_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)

    mode = "brief"
    task_request = ""

    clean_args: list[str] = []
    idx = 0
    while idx < len(args):
        item = args[idx]
        if item == "--full":
            mode = "full"
            idx += 1
            continue
        if item == "--brief":
            mode = "brief"
            idx += 1
            continue
        if item == "--for":
            task_request = " ".join(args[idx + 1:]).strip()
            break
        clean_args.append(item)
        idx += 1

    if clean_args and not task_request:
        task_request = " ".join(clean_args).strip()

    print(_build_context_text(project, config, mode=mode, task_request=task_request))
    return 0


def _tasks_usage() -> None:
    print("Use:")
    print("  max tasks")
    print("  max tasks last")
    print("  max tasks show <number>")
    print("  max tasks search <query>")
    print("  max tasks path")
    print("  max task history")


def power_tasks_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)
    records = _load_tasks(project)

    if not args:
        args = ["list"]

    command = args[0]

    if command in {"help", "-h", "--help"}:
        _tasks_usage()
        return 0

    if command in {"path", "paths"}:
        print(_task_history_path(project))
        return 0

    if command in {"list", "history", "ls"}:
        if not records:
            print("No task history yet.")
            return 1
        print("Task history")
        print("")
        for record in reversed(records[-20:]):
            print(
                f"#{record.get('id')} {record.get('timestamp', '')} "
                f"{record.get('status', '')}: {_shorten(record.get('request', ''), 180)}"
            )
        return 0

    if command == "last":
        if not records:
            print("No task history yet.")
            return 1
        record = records[-1]
        print(json.dumps(record, indent=2, sort_keys=True, ensure_ascii=False))
        return 0

    if command == "show":
        if len(args) < 2:
            print("Missing task number.")
            return 2
        try:
            index = int(args[1])
        except ValueError:
            print("Task number must be an integer.")
            return 2
        if index < 1 or index > len(records):
            print(f"Task not found: {index}")
            return 1
        print(json.dumps(records[index - 1], indent=2, sort_keys=True, ensure_ascii=False))
        return 0

    if command in {"search", "find"}:
        query = " ".join(args[1:]).strip().lower()
        if not query:
            print("Missing search query.")
            return 2

        matches: list[dict[str, Any]] = []
        for record in records:
            if query in json.dumps(record, ensure_ascii=False).lower():
                matches.append(record)

        if not matches:
            print("No matching tasks.")
            return 1

        print("Matching tasks")
        print("")
        for record in matches[-20:]:
            print(
                f"#{record.get('id')} {record.get('timestamp', '')} "
                f"{record.get('status', '')}: {_shorten(record.get('request', ''), 180)}"
            )
        return 0

    print(f"Unknown tasks command: {command}")
    _tasks_usage()
    return 2


def _call_change(project: Path, request: str, run_test: bool = True) -> tuple[int, str]:
    try:
        from .edit_flow import change_project
    except Exception as exc:
        return 1, f"Could not import change_project: {exc}"

    try:
        result = change_project(project, request, yes=False, dry_run=False, run_test=run_test)
    except TypeError:
        try:
            result = change_project(project, request)
        except Exception as exc:
            return 1, f"change_project failed: {exc}"
    except Exception as exc:
        return 1, f"change_project failed: {exc}"

    if isinstance(result, int):
        return result, f"change_project returned exit code {result}"

    if isinstance(result, dict):
        if result.get("ok") is False:
            return 1, json.dumps(result, ensure_ascii=False)
        return 0, json.dumps(result, ensure_ascii=False)

    return 0, str(result)


def _run_test(project: Path, args: list[str] | None = None) -> int:
    try:
        from .test_flow import test_project
    except Exception as exc:
        print(f"Could not import test runner: {exc}")
        return 1

    return int(test_project(project, args or []))


def _fix_usage() -> None:
    print("Use:")
    print("  max fix")
    print("  max fix \"describe the bug\"")
    print("  max fix --no-test")


def power_fix_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)

    if args and args[0] in {"help", "-h", "--help"}:
        _fix_usage()
        return 0

    run_test = True
    clean_args: list[str] = []
    for item in args:
        if item == "--no-test":
            run_test = False
        else:
            clean_args.append(item)

    explicit_problem = " ".join(clean_args).strip()
    failed = _last_failed_test(project)

    if not explicit_problem and not failed:
        print("No failed test found.")
        print("Run a failing command first, for example:")
        print("  max test calc2.py multiply 2 3")
        print("")
        print("Or describe the bug:")
        print("  max fix \"multiply command is missing\"")
        return 1

    context = _build_context_text(
        project,
        config,
        mode="brief",
        task_request=explicit_problem or "Fix the last failed test.",
    )

    pieces: list[str] = []
    pieces.append("Fix the problem below with the smallest safe patch.")
    pieces.append("Do not rewrite unrelated files.")
    pieces.append("Prefer a focused code change plus a useful test command.")
    pieces.append("")

    if explicit_problem:
        pieces.append("User-described problem:")
        pieces.append(explicit_problem)
        pieces.append("")

    if failed:
        pieces.append("Last failed test:")
        pieces.append(f"Command: {_command_text(failed.get('command'))}")
        pieces.append(f"Exit code: {failed.get('exit_code')}")
        if failed.get("stdout_tail"):
            pieces.append("stdout_tail:")
            pieces.append(str(failed.get("stdout_tail", "")).strip())
        if failed.get("stderr_tail"):
            pieces.append("stderr_tail:")
            pieces.append(str(failed.get("stderr_tail", "")).strip())
        pieces.append("")

    pieces.append("Project context:")
    pieces.append(context)

    request = "\n".join(pieces)

    record = _append_task(
        project,
        config,
        {
            "kind": "fix",
            "status": "started",
            "request": explicit_problem or "Fix last failed test",
            "failed_command": _command_text(failed.get("command")) if failed else "",
        },
    )

    print(f"Fix task recorded as #{record.get('id')}")
    print("Calling Max change flow with debugging context...")
    print("")

    code, message = _call_change(project, request, run_test=run_test)

    record["status"] = "completed" if code == 0 else "failed"
    record["completed_at"] = datetime.now().isoformat(timespec="seconds")
    record["result_code"] = code
    record["result_message"] = _shorten(message, 1000)

    records = _load_tasks(project)
    if records:
        records[-1] = record
        _save_tasks(project, config, records)

    if code != 0:
        print("")
        print("Fix flow did not complete cleanly.")
        print(message)
        return code

    if run_test and failed:
        print("")
        print("Rerunning the failed command through max test...")
        failed_command = failed.get("original_args") or failed.get("command") or []
        if isinstance(failed_command, list):
            return _run_test(project, [str(x) for x in failed_command])

    return 0


def _task_usage() -> None:
    print("Use:")
    print("  max task \"request\"")
    print("  max task --no-test \"request\"")
    print("  max task history")
    print("  max task last")
    print("")
    print("Example:")
    print("  max task \"add multiply and divide subcommands to calc2.py\"")


def power_task_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)

    if not args or args[0] in {"help", "-h", "--help"}:
        _task_usage()
        return 0

    if args[0] in {"history", "list", "last", "show", "search", "path", "paths"}:
        return power_tasks_project(project, args)

    run_test = True
    clean_args: list[str] = []
    for item in args:
        if item == "--no-test":
            run_test = False
        else:
            clean_args.append(item)

    request_text = " ".join(clean_args).strip()
    if not request_text:
        print("Missing task request.")
        _task_usage()
        return 2

    context = _build_context_text(project, config, mode="brief", task_request=request_text)

    enhanced_request = f"""Complete this coding task as a small, safe change.

User task:
{request_text}

Required workflow:
1. Inspect the relevant workspace files.
2. Make the smallest patch that satisfies the request.
3. Include or infer a useful test command when Python files change.
4. Avoid unrelated rewrites.
5. Summarize what changed.

Project context:
{context}
"""

    record = _append_task(
        project,
        config,
        {
            "kind": "task",
            "status": "started",
            "request": request_text,
            "run_test": run_test,
        },
    )

    print(f"Task recorded as #{record.get('id')}")
    print("Calling Max change flow with project context...")
    print("")

    code, message = _call_change(project, enhanced_request, run_test=run_test)

    test_code: int | None = None
    fix_code: int | None = None

    if code == 0 and run_test:
        print("")
        print("Running default workspace test...")
        test_code = _run_test(project, [])

        if test_code != 0:
            print("")
            print("Default test failed. Starting one fix attempt...")
            fix_code = power_fix_project(project, [])

    final_ok = code == 0 and (test_code in {None, 0}) and (fix_code in {None, 0})

    record["status"] = "completed" if final_ok else "failed"
    record["completed_at"] = datetime.now().isoformat(timespec="seconds")
    record["change_code"] = code
    record["test_code"] = test_code
    record["fix_code"] = fix_code
    record["result_message"] = _shorten(message, 1000)

    records = _load_tasks(project)
    if records:
        records[-1] = record
        _save_tasks(project, config, records)

    if final_ok:
        print("")
        print("Task loop completed.")
        return 0

    print("")
    print("Task loop ended with a failure.")
    print("Check:")
    print("  max task last")
    print("  max test last")
    return 1
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

import_line = (
    "from .power_flow import power_context_project as direct_power_context_project, "
    "power_tasks_project as direct_power_tasks_project, "
    "power_fix_project as direct_power_fix_project, "
    "power_task_project as direct_power_task_project"
)

if import_line not in text:
    markers = [
        "from .test_flow import test_project as direct_test_project\n",
        "from .workspace_flow import workspace_project as direct_workspace_project\n",
        "from .audit_flow import audit_project as direct_audit_project\n",
        "from .notes_flow import notes_project as direct_notes_project\n",
        "from .research_flow import research_project as direct_research_project\n",
        "from .browser_flow import browser_project as direct_browser_project\n",
        "from .web_flow import web_project as direct_web_project\n",
        "from .project_settings import config_project as direct_config_project\n",
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


def ensure_entry(name: str, entry: str) -> None:
    global text
    if f'"{name}": {{' in text:
        return
    marker = '    "test": {'
    if marker not in text:
        marker = '    "workspace": {'
    if marker not in text:
        marker = '    "audit": {'
    if marker not in text:
        raise SystemExit(f"Could not find COMMANDS insertion point for {name}.")
    text = text.replace(marker, entry + marker, 1)


ensure_entry(
    "tasks",
    '''    "tasks": {
        "aliases": ["task-history"],
        "summary": "Show task history.",
        "usage": "max tasks [list|last|show|search|path]",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
''',
)

# Add direct helper functions.
if "def _direct_power_context(" not in text:
    marker = "def main(argv: list[str] | None = None) -> int:\n"
    func = '''\n\ndef _direct_power_context(args: list[str]) -> int:\n    project, rest = _direct_project_and_rest(args)\n    if project is None:\n        ui.fail("No project selected.")\n        print("Use: max use <project> or max new <project>")\n        return 2\n    return direct_power_context_project(project, rest)\n\n\ndef _direct_power_tasks(args: list[str]) -> int:\n    project, rest = _direct_project_and_rest(args)\n    if project is None:\n        ui.fail("No project selected.")\n        print("Use: max use <project> or max new <project>")\n        return 2\n    return direct_power_tasks_project(project, rest)\n\n\ndef _direct_power_fix(args: list[str]) -> int:\n    project, rest = _direct_project_and_rest(args)\n    if project is None:\n        ui.fail("No project selected.")\n        print("Use: max use <project> or max new <project>")\n        return 2\n    return direct_power_fix_project(project, rest)\n\n\ndef _direct_power_task(args: list[str]) -> int:\n    project, rest = _direct_project_and_rest(args)\n    if project is None:\n        ui.fail("No project selected.")\n        print("Use: max use <project> or max new <project>")\n        return 2\n    return direct_power_task_project(project, rest)\n\n\n'''
    if marker not in text:
        raise SystemExit("Could not find main() in max_cli.py")
    text = text.replace(marker, func + marker, 1)

# Replace existing simple direct branches where present.
lines = text.splitlines()

def replace_return_for_branch(command_names: set[str], return_line: str) -> bool:
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith("if argv and argv[0] in {"):
            continue

        found = False
        for name in command_names:
            if f'"{name}"' in stripped or f"'{name}'" in stripped:
                found = True
                break

        if not found:
            continue

        indent = line[: len(line) - len(line.lstrip())]
        for j in range(i + 1, min(i + 8, len(lines))):
            if lines[j].lstrip().startswith("return "):
                lines[j] = indent + "    " + return_line
                return True

    return False

replace_return_for_branch({"context", "content"}, "return _direct_power_context(argv[1:])")
replace_return_for_branch({"tasks", "task-history"}, "return _direct_power_tasks(argv[1:])")
replace_return_for_branch({"fix", "repair"}, "return _direct_power_fix(argv[1:])")
replace_return_for_branch({"task"}, "return _direct_power_task(argv[1:])")

text = "\n".join(lines) + "\n"

# Insert branches that did not already exist.
branch = '''    if argv and argv[0] in {"context", "content"}:
        return _direct_power_context(argv[1:])

    if argv and argv[0] in {"tasks", "task-history"}:
        return _direct_power_tasks(argv[1:])

    if argv and argv[0] in {"fix", "repair"}:
        return _direct_power_fix(argv[1:])

    if argv and argv[0] in {"task"}:
        return _direct_power_task(argv[1:])

'''

if branch not in text:
    markers = [
        '    if argv and argv[0] in {"test", "check"}:\n',
        '    if argv and argv[0] in {"workspace", "where", "pwd", "cd", "shell"}:\n',
        '    if argv and argv[0] in {"audit", "timeline"}:\n',
        '    if argv and argv[0] in {"notes", "memory"}:\n',
        '    if argv and argv[0] in {"research", "lookup"}:\n',
    ]
    for marker in markers:
        if marker in text:
            text = text.replace(marker, branch + marker, 1)
            break
    else:
        raise SystemExit("Could not find direct command section in main().")

# Help/dashboard entries.
if '("max context --for \\"task\\"", "Build a rich model context")' not in text:
    text = text.replace(
        '("max test calc2.py add 5 3", "Run a workspace test command"),',
        '("max test calc2.py add 5 3", "Run a workspace test command"),\n        ("max context --for \\"task\\"", "Build a rich model context"),\n        ("max task \\"request\\"", "Run contextual task loop"),',
    )

text = text.replace(
    '"read", "search", "web", "browser", "research", "notes", "audit", "workspace", "shell", "test", "index"',
    '"read", "search", "web", "browser", "research", "notes", "audit", "workspace", "shell", "test", "tasks", "context", "index"',
)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/audit_flow.py")
if not p.exists():
    raise SystemExit("audit_flow.py not found")

text = p.read_text()

if '"task": "task-history.jsonl",' not in text:
    text = text.replace(
        'HISTORY_FILES = {\n',
        'HISTORY_FILES = {\n    "task": "task-history.jsonl",\n',
        1,
    )

if 'if source == "task":' not in text:
    old = '''    if source == "test":
        command = " ".join(str(part) for part in record.get("command", []))
        exit_code = record.get("exit_code", "")
        return f"test exit={exit_code} {command}".strip()
'''

    new = '''    if source == "task":
        status = record.get("status", "")
        request = record.get("request", "")
        return f"task {status} {request}".strip()

    if source == "test":
        command = " ".join(str(part) for part in record.get("command", []))
        exit_code = record.get("exit_code", "")
        return f"test exit={exit_code} {command}".strip()
'''

    if old in text:
        text = text.replace(old, new, 1)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v26-v29 power loop installed."
echo ""
echo "Try non-model tests first:"
echo "  max context --brief"
echo "  max context --for \"add multiply command\""
echo "  max tasks"
echo "  max task help"
echo "  max fix help"
echo "  max audit search task"
echo ""
echo "Then model-backed tests:"
echo "  max test calc2.py multiply 2 3"
echo "  max fix \"calc2.py is missing multiply command\""
echo "  max task \"add multiply and divide subcommands to calc2.py\""
