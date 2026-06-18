from __future__ import annotations

import json
import shlex
import subprocess
import time
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


def _history_path(project: Path) -> Path:
    return project_max_dir(project) / "test-history.jsonl"


def _load_history(project: Path) -> list[dict[str, Any]]:
    path = _history_path(project)
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


def _save_history(project: Path, config: dict[str, Any], records: list[dict[str, Any]]) -> None:
    max_items = 100
    history_cfg = config.get("history", {})
    if isinstance(history_cfg, dict):
        try:
            max_items = int(history_cfg.get("max_items", 100))
        except (TypeError, ValueError):
            max_items = 100

    path = _history_path(project)
    path.write_text(
        "".join(json.dumps(item, ensure_ascii=False) + "\n" for item in records[-max_items:])
    )


def _append_history(project: Path, config: dict[str, Any], record: dict[str, Any]) -> None:
    records = _load_history(project)
    records.append(record)
    _save_history(project, config, records)


def _tail_text(text: str, limit: int = 6000) -> str:
    if len(text) <= limit:
        return text
    return text[-limit:]


def _normalize_command(args: list[str]) -> list[str]:
    if not args:
        return []

    if len(args) == 1:
        try:
            parts = shlex.split(args[0])
        except ValueError:
            parts = args
    else:
        parts = args

    if not parts:
        return []

    target = parts[0]

    if target.endswith(".py"):
        return ["python3", target] + parts[1:]

    if target.endswith(".sh"):
        return ["bash", target] + parts[1:]

    return parts


def _has_pytest_tests(workspace: Path) -> bool:
    tests_dir = workspace / "tests"
    if tests_dir.exists() and any(tests_dir.rglob("test_*.py")):
        return True

    if any(workspace.glob("test_*.py")):
        return True

    if any(workspace.glob("*_test.py")):
        return True

    return False


def _default_test_command(workspace: Path) -> list[str]:
    if _has_pytest_tests(workspace):
        return ["python3", "-m", "pytest"]

    py_files = sorted(
        path.relative_to(workspace).as_posix()
        for path in workspace.glob("*.py")
        if path.is_file()
    )

    if py_files:
        return ["python3", "-m", "py_compile", *py_files]

    return []


def _print_record(record: dict[str, Any]) -> None:
    status = "PASS" if int(record.get("exit_code", 1)) == 0 else "FAIL"
    command = " ".join(str(part) for part in record.get("command", []))
    duration = float(record.get("duration_sec", 0))

    print("")
    print(f"Test {status}")
    print(f"Command: {command}")
    print(f"Exit code: {record.get('exit_code')}")
    print(f"Duration: {duration:.2f}s")

    stdout = str(record.get("stdout_tail") or "")
    stderr = str(record.get("stderr_tail") or "")

    if stdout:
        print("")
        print("stdout:")
        print(stdout.rstrip())

    if stderr:
        print("")
        print("stderr:")
        print(stderr.rstrip())


def _show_last(project: Path) -> int:
    records = _load_history(project)
    if not records:
        print("No test history yet.")
        return 1

    print("Last test")
    _print_record(records[-1])
    return int(records[-1].get("exit_code", 1))


def _show_history(project: Path) -> int:
    records = _load_history(project)
    if not records:
        print("No test history yet.")
        return 1

    print("Recent tests")
    print("")

    for idx, record in enumerate(reversed(records[-10:]), start=1):
        status = "PASS" if int(record.get("exit_code", 1)) == 0 else "FAIL"
        command = " ".join(str(part) for part in record.get("command", []))
        duration = float(record.get("duration_sec", 0))
        print(f"{idx}. {status}  {command}  ({duration:.2f}s)")

    return 0


def _usage() -> None:
    print("Use:")
    print("  max test")
    print("  max test calc2.py add 5 3")
    print("  max test calc2.py subtract 10 4")
    print("  max test last")
    print("  max test history")


def test_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)
    workspace = _workspace_path(project, config)

    if args and args[0] in {"help", "-h", "--help"}:
        _usage()
        return 0

    if args and args[0] == "last":
        return _show_last(project)

    if args and args[0] in {"history", "hist"}:
        return _show_history(project)

    if not workspace.exists():
        print(f"Workspace not found: {workspace}")
        return 1

    original_args = list(args)

    if args:
        command = _normalize_command(args)
    else:
        command = _default_test_command(workspace)

    if not command:
        print("No test command was provided, and no pytest tests or workspace Python files were found.")
        return 1

    print("")
    print("Running test inside workspace:")
    print(f"  {workspace}")
    print("")
    print("Command:")
    print("  " + " ".join(command))
    print("")

    started = time.time()

    proc = subprocess.run(
        command,
        cwd=str(workspace),
        text=True,
        capture_output=True,
    )

    duration = time.time() - started

    record = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "workspace": str(workspace),
        "command": command,
        "original_args": original_args,
        "exit_code": proc.returncode,
        "duration_sec": round(duration, 4),
        "stdout_tail": _tail_text(proc.stdout),
        "stderr_tail": _tail_text(proc.stderr),
        "ok": proc.returncode == 0,
    }

    _append_history(project, config, record)
    _print_record(record)

    return int(proc.returncode)
