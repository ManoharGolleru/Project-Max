from __future__ import annotations

import shlex
from pathlib import Path


BLOCKED_PATTERNS = [
    "sudo",
    "su ",
    "rm -rf",
    "mkfs",
    "dd if=",
    ":(){",
    "chmod -R 777 /",
    "chmod -R 777",
    "chown -R",
    "shutdown",
    "reboot",
    "systemctl",
    "passwd",
    "usermod",
    "mount ",
    "umount ",
    "> /dev/",
    "$HOME",
    "${HOME}",
    "~",
]


READ_ONLY_COMMANDS = {
    "ls",
    "pwd",
    "find",
    "cat",
    "head",
    "tail",
    "wc",
    "du",
    "df",
    "tree",
    "grep",
    "rg",
    "sed",
    "awk",
    "git",
    "python",
    "python3",
}


def is_inside(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except Exception:
        return False


def is_dangerous(command: str) -> tuple[bool, str]:
    lowered = command.lower().strip()

    for pat in BLOCKED_PATTERNS:
        if pat in lowered:
            return True, f"Blocked dangerous pattern: {pat}"

    if "../" in command or "/.." in command:
        return True, "Blocked path traversal pattern: .."

    return False, ""


def tokenize_command(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except Exception:
        return command.split()


def command_name(command: str) -> str:
    tokens = tokenize_command(command)
    if not tokens:
        return ""
    return Path(tokens[0]).name


def validate_paths_in_command(command: str, workspace_root: Path) -> tuple[bool, str]:
    tokens = tokenize_command(command)
    workspace_root = workspace_root.resolve()

    for token in tokens:
        cleaned = token.strip().strip("'\"")

        if not cleaned:
            continue

        if cleaned.startswith("-"):
            continue

        if cleaned in {"|", ">", ">>", "<", "&&", "||", ";"}:
            continue

        # Absolute paths must stay inside the workspace.
        if cleaned.startswith("/"):
            p = Path(cleaned).resolve()
            if not is_inside(p, workspace_root):
                return False, f"Absolute path outside workspace is blocked: {cleaned}"

        # Home-relative paths are blocked for now.
        if cleaned.startswith("~/"):
            return False, f"Home-relative path is blocked: {cleaned}"

    return True, ""


def validate_command(command: str, cwd: Path, workspace_root: Path) -> tuple[bool, str]:
    cwd = cwd.resolve()
    workspace_root = workspace_root.resolve()

    if not is_inside(cwd, workspace_root):
        return False, "cwd outside workspace"

    dangerous, why = is_dangerous(command)
    if dangerous:
        return False, why

    paths_ok, path_reason = validate_paths_in_command(command, workspace_root)
    if not paths_ok:
        return False, path_reason

    return True, "ok"


def approval_prompt(command: str, cwd: Path, reason: str) -> bool:
    print("")
    print("The agent wants to run this command:")
    print(f"  {command}")
    print(f"Working directory: {cwd}")
    print(f"Reason: {reason}")
    print("")
    ans = input("Approve? [y/N/details]: ").strip().lower()

    if ans == "details":
        print("")
        print("v0.2 blocks obvious dangerous commands, blocks home paths,")
        print("blocks absolute paths outside the workspace, and blocks path traversal.")
        print("This is still not a full Docker sandbox yet.")
        print("")
        ans = input("Approve now? [y/N]: ").strip().lower()

    return ans in {"y", "yes"}
