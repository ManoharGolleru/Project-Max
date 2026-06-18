#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v24_workspace_shell.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v24_workspace_shell_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py workspace_flow.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/workspace_flow.py <<'PY'
from __future__ import annotations

import os
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .project_settings import ensure_project_config, load_project_config


def _workspace_path(project: Path, config: dict[str, Any]) -> Path:
    workspace_value = str(config.get("workspace") or "workspace")
    workspace = Path(workspace_value).expanduser()

    if workspace.is_absolute():
        return workspace.resolve()

    return (project / workspace).resolve()


def _project_name(project: Path) -> str:
    return project.expanduser().resolve().name


def _print_usage() -> None:
    print("Use:")
    print("  max workspace")
    print("  max workspace path")
    print("  max workspace files")
    print("  max workspace tree")
    print("  max pwd")
    print("  max cd")
    print("  max cd --path")
    print("  max shell")


def _safe_rel(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return str(path)


def _list_files(workspace: Path) -> int:
    if not workspace.exists():
        print(f"Workspace not found: {workspace}")
        return 1

    files = []
    for path in sorted(workspace.rglob("*")):
        if path.is_dir():
            continue

        parts = path.relative_to(workspace).parts
        if any(part in {"__pycache__", ".pytest_cache", ".git"} for part in parts):
            continue

        files.append(path)

    if not files:
        print("No workspace files found.")
        return 1

    print("Workspace files")
    print("")
    for path in files[:200]:
        print(_safe_rel(path, workspace))

    if len(files) > 200:
        print(f"... {len(files) - 200} more files")

    return 0


def _print_tree(workspace: Path, max_depth: int = 3) -> int:
    if not workspace.exists():
        print(f"Workspace not found: {workspace}")
        return 1

    print(workspace.name + "/")

    def walk(path: Path, prefix: str, depth: int) -> None:
        if depth > max_depth:
            return

        children = [
            child
            for child in sorted(path.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
            if child.name not in {"__pycache__", ".pytest_cache", ".git"}
        ]

        for idx, child in enumerate(children):
            last = idx == len(children) - 1
            branch = "└── " if last else "├── "
            print(prefix + branch + child.name + ("/" if child.is_dir() else ""))

            if child.is_dir():
                next_prefix = prefix + ("    " if last else "│   ")
                walk(child, next_prefix, depth + 1)

    walk(workspace, "", 1)
    return 0


def _open_shell(project: Path, workspace: Path) -> int:
    if not workspace.exists():
        print(f"Workspace not found: {workspace}")
        return 1

    shell = os.environ.get("SHELL") or shutil.which("bash") or shutil.which("sh")
    if not shell:
        print("No shell found. Set SHELL or install bash/sh.")
        return 1

    env = os.environ.copy()
    project_name = _project_name(project)
    env["MAX_PROJECT"] = project_name
    env["MAX_WORKSPACE"] = str(workspace)

    if Path(shell).name in {"bash", "sh"}:
        env["PS1"] = f"(max:{project_name}) workspace $ "

    print(f"Opening shell inside workspace: {workspace}")
    print("Type exit to return to Max.")
    print("")

    try:
        return subprocess.call([shell], cwd=str(workspace), env=env)
    except KeyboardInterrupt:
        print("")
        return 130


def workspace_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)
    workspace = _workspace_path(project, config)

    if not args:
        args = ["workspace"]

    command = args[0]
    rest = args[1:]

    if command in {"help", "-h", "--help"}:
        _print_usage()
        return 0

    if command == "pwd":
        print(workspace)
        return 0

    if command == "cd":
        if rest and rest[0] == "--path":
            print(workspace)
        else:
            print(f"cd {shlex.quote(str(workspace))}")
        return 0

    if command == "shell":
        return _open_shell(project, workspace)

    if command == "workspace":
        subcommand = rest[0] if rest else "show"

        if subcommand in {"show", "info"}:
            print("Workspace")
            print("")
            print(f"Project: {_project_name(project)}")
            print(f"Project path: {project}")
            print(f"Workspace path: {workspace}")
            print(f"Exists: {workspace.exists()}")
            print("")
            print("Useful commands:")
            print("  max shell")
            print("  max pwd")
            print("  max cd")
            print("  max run calc2.py add 5 3")
            return 0

        if subcommand in {"path", "pwd"}:
            print(workspace)
            return 0

        if subcommand in {"files", "ls"}:
            return _list_files(workspace)

        if subcommand == "tree":
            return _print_tree(workspace)

        print(f"Unknown workspace command: {subcommand}")
        _print_usage()
        return 2

    print(f"Unknown workspace command: {command}")
    _print_usage()
    return 2
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

import_line = "from .workspace_flow import workspace_project as direct_workspace_project"

if import_line not in text:
    markers = [
        "from .audit_flow import audit_project as direct_audit_project\n",
        "from .notes_flow import notes_project as direct_notes_project\n",
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

for name, entry in {
    "workspace": '''    "workspace": {
        "aliases": ["where"],
        "summary": "Show workspace info, path, files, or tree.",
        "usage": "max workspace [path|files|tree]",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
''',
    "shell": '''    "shell": {
        "aliases": [],
        "summary": "Open a shell inside the active workspace.",
        "usage": "max shell",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
''',
    "pwd": '''    "pwd": {
        "aliases": [],
        "summary": "Print the active workspace path.",
        "usage": "max pwd",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
''',
    "cd": '''    "cd": {
        "aliases": [],
        "summary": "Print a cd command for the active workspace.",
        "usage": "max cd",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
''',
}.items():
    if f'"{name}": {{' not in text:
        marker = '    "audit": {'
        if marker not in text:
            marker = '    "notes": {'
        if marker not in text:
            marker = '    "research": {'
        if marker not in text:
            raise SystemExit(f"Could not find COMMANDS insertion point for {name}.")
        text = text.replace(marker, entry + marker, 1)

if "def _direct_workspace(" not in text:
    marker = "def main(argv: list[str] | None = None) -> int:\n"
    func = '''\n\ndef _direct_workspace(args: list[str]) -> int:\n    if not args:\n        args = ["workspace"]\n    command = args[0]\n    project, rest = _direct_project_and_rest(args[1:])\n    if project is None:\n        ui.fail("No project selected.")\n        print("Use: max use <project> or max new <project>")\n        return 2\n    return direct_workspace_project(project, [command] + rest)\n\n\n'''
    if marker not in text:
        raise SystemExit("Could not find main() in max_cli.py")
    text = text.replace(marker, func + marker, 1)

branch = '''    if argv and argv[0] in {"workspace", "where", "pwd", "cd", "shell"}:\n        return _direct_workspace(argv)\n\n'''

if branch not in text:
    markers = [
        '    if argv and argv[0] in {"audit", "timeline"}:\n',
        '    if argv and argv[0] in {"notes", "memory"}:\n',
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

if '("max shell", "Open a shell inside the active workspace")' not in text:
    text = text.replace(
        '("max audit", "Show unified project timeline"),',
        '("max audit", "Show unified project timeline"),\n        ("max shell", "Open a shell inside the active workspace"),',
    )

text = text.replace(
    '"read", "search", "web", "browser", "research", "notes", "audit", "index"',
    '"read", "search", "web", "browser", "research", "notes", "audit", "workspace", "shell", "index"',
)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.24 workspace + shell ergonomics installed."
echo ""
echo "Try:"
echo "  max workspace"
echo "  max workspace path"
echo "  max workspace files"
echo "  max workspace tree"
echo "  max pwd"
echo "  max cd"
echo "  max cd --path"
echo "  max shell"
