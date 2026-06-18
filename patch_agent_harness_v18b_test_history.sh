#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v18b_test_history.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v18b_test_history_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py chat_actions.py edit_flow.py task_flow.py ux.py test_flow.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/test_flow.py <<'PY'
from __future__ import annotations

import json
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable


MAX_TEST_HISTORY = 100


def _as_path(value: Any) -> Path | None:
    if value is None:
        return None
    try:
        return Path(value).expanduser().resolve()
    except TypeError:
        return None


def _get_from_project(project: Any, names: list[str]) -> Any:
    if isinstance(project, dict):
        for name in names:
            if name in project:
                return project[name]

    for name in names:
        if hasattr(project, name):
            value = getattr(project, name)
            if callable(value):
                try:
                    value = value()
                except TypeError:
                    pass
            return value

    return None


def _project_root(project: Any) -> Path:
    value = _get_from_project(
        project,
        [
            "root",
            "path",
            "project_path",
            "project_dir",
            "base_dir",
            "directory",
        ],
    )
    path = _as_path(value)
    if path is not None:
        return path

    workspace_value = _get_from_project(
        project,
        [
            "workspace",
            "workspace_path",
            "workspace_dir",
            "workdir",
        ],
    )
    workspace = _as_path(workspace_value)
    if workspace is not None and workspace.name == "workspace":
        return workspace.parent.resolve()

    return Path.cwd().resolve()


def _workspace_path(project: Any) -> Path:
    value = _get_from_project(
        project,
        [
            "workspace",
            "workspace_path",
            "workspace_dir",
            "workdir",
        ],
    )
    path = _as_path(value)
    if path is not None:
        return path

    root = _project_root(project)
    candidate = root / "workspace"
    if candidate.exists():
        return candidate.resolve()

    return root.resolve()


def _infer_project_from_cwd() -> dict[str, str]:
    cwd = Path.cwd().resolve()

    if cwd.name == "workspace":
        root = cwd.parent
        return {"root": str(root), "workspace": str(cwd)}

    if (cwd / "workspace").is_dir():
        return {"root": str(cwd), "workspace": str(cwd / "workspace")}

    if (cwd / "test-project" / "workspace").is_dir():
        root = cwd / "test-project"
        return {"root": str(root), "workspace": str(root / "workspace")}

    candidates = []
    for child in cwd.iterdir():
        if child.is_dir() and (child / "workspace").is_dir():
            candidates.append(child)

    if len(candidates) == 1:
        root = candidates[0]
        return {"root": str(root), "workspace": str(root / "workspace")}

    return {"root": str(cwd), "workspace": str(cwd)}


def _max_dir(project: Any) -> Path:
    root = _project_root(project)
    max_dir = root / ".max"
    max_dir.mkdir(parents=True, exist_ok=True)
    return max_dir


def _history_path(project: Any) -> Path:
    return _max_dir(project) / "test-history.jsonl"


def _tail_text(text: str, limit: int = 6000) -> str:
    if len(text) <= limit:
        return text
    return text[-limit:]


def _load_history(project: Any) -> list[dict[str, Any]]:
    path = _history_path(project)
    if not path.exists():
        return []

    records: list[dict[str, Any]] = []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict):
            records.append(item)

    return records


def _save_history(project: Any, records: list[dict[str, Any]]) -> None:
    path = _history_path(project)
    records = records[-MAX_TEST_HISTORY:]
    text = ""
    for record in records:
        text += json.dumps(record, ensure_ascii=False) + "\n"
    path.write_text(text)


def _append_history(project: Any, record: dict[str, Any]) -> None:
    records = _load_history(project)
    records.append(record)
    _save_history(project, records)


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
        p.relative_to(workspace).as_posix()
        for p in workspace.glob("*.py")
        if p.is_file()
    )
    if py_files:
        return ["python3", "-m", "py_compile", *py_files]

    return []


def _normalize_for_test(
    rest: list[str],
    normalizer: Callable[[list[str]], list[str]] | None = None,
) -> list[str]:
    if not rest:
        return []

    if normalizer is not None:
        return normalizer(rest)

    target = rest[0]
    if target.endswith(".py"):
        return ["python3", target] + rest[1:]
    if target.endswith(".sh"):
        return ["bash", target] + rest[1:]
    return rest


def _print_result(record: dict[str, Any]) -> None:
    status = "PASS" if int(record.get("exit_code", 1)) == 0 else "FAIL"
    command = " ".join(record.get("command", []))
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


def _show_last(project: Any) -> int:
    records = _load_history(project)
    if not records:
        print("No test history yet.")
        return 1

    print("Last test")
    _print_result(records[-1])
    return int(records[-1].get("exit_code", 1))


def _show_history(project: Any) -> int:
    records = _load_history(project)
    if not records:
        print("No test history yet.")
        return 1

    print("Recent tests")
    print("")
    recent = records[-10:]
    for idx, record in enumerate(reversed(recent), start=1):
        status = "PASS" if int(record.get("exit_code", 1)) == 0 else "FAIL"
        command = " ".join(record.get("command", []))
        duration = float(record.get("duration_sec", 0))
        print(f"{idx}. {status}  {command}  ({duration:.2f}s)")

    return 0


def test_project(
    project: Any,
    rest: list[str],
    normalizer: Callable[[list[str]], list[str]] | None = None,
) -> int:
    if rest and rest[0] == "last":
        return _show_last(project)

    if rest and rest[0] in {"history", "hist"}:
        return _show_history(project)

    workspace = _workspace_path(project)
    if not workspace.exists():
        print(f"Workspace not found: {workspace}")
        return 1

    original_args = list(rest)

    if rest:
        command = _normalize_for_test(rest, normalizer=normalizer)
    else:
        command = _default_test_command(workspace)

    if not command:
        print("No test command was provided, and Max found no Python files or pytest tests.")
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
    }

    _append_history(project, record)
    _print_result(record)

    return int(proc.returncode)


def test_from_cwd(
    rest: list[str],
    normalizer: Callable[[list[str]], list[str]] | None = None,
) -> int:
    project = _infer_project_from_cwd()
    return test_project(project, rest, normalizer=normalizer)
PY

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()
original_text = text

# Add command registry entry if this CLI uses the COMMANDS dictionary style.
if '"test": {' not in text and '"context": {' in text:
    marker = '    "context": {'
    entry = '''    "test": {
        "aliases": [],
        "help": "Run tests inside the active workspace and save test history.",
    },
'''
    if marker in text:
        text = text.replace(marker, entry + marker, 1)

# Add imports.
if "from .test_flow import test_project, test_from_cwd" not in text:
    lines = text.splitlines()
    insert_at = None

    for i, line in enumerate(lines):
        if line.startswith("from .") or line.startswith("import "):
            insert_at = i + 1

    if insert_at is None:
        for i, line in enumerate(lines):
            if line.startswith("from __future__"):
                insert_at = i + 1

    if insert_at is None:
        insert_at = 0

    lines.insert(insert_at, "from .test_flow import test_project, test_from_cwd")
    text = "\n".join(lines) + "\n"

if "test_project(project" not in text and "test_from_cwd(rest" not in text:
    lines = text.splitlines()

    def find_dispatch_candidate():
        best = None

        for i, line in enumerate(lines):
            stripped = line.lstrip()
            if not (stripped.startswith("if ") or stripped.startswith("elif ")):
                continue

            has_run = '"run"' in stripped or "'run'" in stripped
            has_do = '"do"' in stripped or "'do'" in stripped
            if not (has_run or has_do):
                continue

            window = "\n".join(lines[i:i + 25])
            score = 1
            if "_normalize_safe_command_args" in window:
                score += 10
            if "safe" in window.lower():
                score += 3
            if "workspace" in window.lower():
                score += 2
            if "subprocess" in window.lower():
                score += 2

            if best is None or score > best[0]:
                best = (score, i)

        return None if best is None else best[1]

    insert_idx = find_dispatch_candidate()

    if insert_idx is not None:
        line = lines[insert_idx]
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        keyword = "elif" if stripped.startswith("elif ") else "if"

        cmd_expr = "cmd"
        m = re.match(r"(?:if|elif)\s+([A-Za-z_][A-Za-z0-9_]*)\s+(?:in|==)\s+", stripped)
        if m:
            cmd_expr = m.group(1)

        nearby = "\n".join(lines[max(0, insert_idx - 50): insert_idx + 40])

        rest_expr = "rest"
        m = re.search(r"_normalize_safe_command_args\(([^)]+)\)", nearby)
        if m:
            rest_expr = m.group(1).strip()

        project_expr = "project"
        for candidate in ["project", "active_project", "current_project", "proj"]:
            if re.search(rf"\b{candidate}\b", nearby):
                project_expr = candidate
                break

        block = [
            f'{indent}{keyword} {cmd_expr} == "test":',
            f'{indent}    raise SystemExit(test_project({project_expr}, {rest_expr}, normalizer=_normalize_safe_command_args))',
            "",
        ]

        lines[insert_idx:insert_idx] = block
        text = "\n".join(lines) + "\n"

    else:
        # Fallback hook: insert after cmd/rest are assigned. This path infers
        # the project from cwd, which handles the current ~/agent-harness setup.
        cmd_var = None
        rest_var = None
        insert_after = None

        for i, line in enumerate(lines):
            stripped = line.strip()

            m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:argv|args)\[0\]", stripped)
            if m:
                cmd_var = m.group(1)
                insert_after = i

            m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:argv|args)\[1:\]", stripped)
            if m:
                rest_var = m.group(1)
                insert_after = i

            m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*args\.command", stripped)
            if m:
                cmd_var = m.group(1)
                insert_after = i

            m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*args\.rest", stripped)
            if m:
                rest_var = m.group(1)
                insert_after = i

        if cmd_var and rest_var and insert_after is not None:
            line = lines[insert_after]
            indent = line[: len(line) - len(line.lstrip())]
            block = [
                f'{indent}if {cmd_var} == "test":',
                f'{indent}    raise SystemExit(test_from_cwd({rest_var}, normalizer=_normalize_safe_command_args))',
                "",
            ]
            lines[insert_after + 1:insert_after + 1] = block
            text = "\n".join(lines) + "\n"
        else:
            diag = []
            diag.append("Could not hook max test automatically.")
            diag.append("")
            diag.append("Useful max_cli.py lines:")
            for i, line in enumerate(lines, start=1):
                low = line.lower()
                if (
                    "normalize_safe" in low
                    or "cmd" in low and "run" in low
                    or "command" in low and "run" in low
                    or "def main" in low
                    or "commands" in low
                    or '"context"' in line
                ):
                    diag.append(f"{i}: {line}")
            raise SystemExit("\n".join(diag))

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.18b max test + test history installed."
echo ""
echo "Run these from ~/agent-harness:"
echo "  max test calc2.py add 5 3"
echo "  max test calc2.py subtract 10 4"
echo "  max test last"
echo "  max test history"
echo "  max test"
echo ""
echo "History file:"
echo "  test-project/.max/test-history.jsonl"
