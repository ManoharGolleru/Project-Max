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
