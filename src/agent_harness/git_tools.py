from __future__ import annotations

import difflib
import shutil
import subprocess
from pathlib import Path


TEXT_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".json", ".md", ".txt", ".html", ".css",
    ".scss", ".yml", ".yaml", ".toml", ".sh", ".csv", ".xml", ".env", ".gitignore",
}


def have_git() -> bool:
    return shutil.which("git") is not None


def run_git(workspace: Path, args: list[str], timeout: int = 60) -> dict:
    if not have_git():
        return {
            "ok": False,
            "stdout": "",
            "stderr": "git is not installed",
            "exit_code": None,
        }

    proc = subprocess.run(
        ["git"] + args,
        cwd=str(workspace),
        text=True,
        capture_output=True,
        timeout=timeout,
    )

    return {
        "ok": proc.returncode == 0,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "exit_code": proc.returncode,
    }


def ensure_git_repo(workspace: Path) -> dict:
    if not have_git():
        return {"ok": False, "message": "git is not installed"}

    if not (workspace / ".git").exists():
        init = run_git(workspace, ["init"])
        if not init["ok"]:
            return {"ok": False, "message": init["stderr"]}

    run_git(workspace, ["config", "user.email", "max@local"])
    run_git(workspace, ["config", "user.name", "Max Local Agent"])

    return {"ok": True, "message": "git repo ready"}


def _safe_rel(path_text: str) -> bool:
    p = Path(path_text)
    if p.is_absolute():
        return False
    if ".." in p.parts:
        return False
    if any(part in {".git", ".agent", "node_modules", "__pycache__", ".venv"} for part in p.parts):
        return False
    return True


def _is_text_file(path: Path) -> bool:
    if path.name == ".gitignore":
        return True
    return path.suffix.lower() in TEXT_EXTS


def _untracked_file_diff(workspace: Path, status_text: str) -> str:
    out: list[str] = []

    for line in status_text.splitlines():
        if not line.startswith("?? "):
            continue

        rel = line[3:].strip()

        if not _safe_rel(rel):
            continue

        p = workspace / rel

        if not p.exists() or not p.is_file():
            continue

        if not _is_text_file(p):
            out.append(f"\n--- untracked binary or unsupported file: {rel} ---\n")
            continue

        try:
            content = p.read_text(errors="replace")
        except Exception as e:
            out.append(f"\n--- could not read untracked file: {rel}: {e} ---\n")
            continue

        if len(content) > 200000:
            out.append(f"\n--- untracked file too large to preview: {rel} ---\n")
            continue

        diff = difflib.unified_diff(
            [],
            content.splitlines(keepends=True),
            fromfile="/dev/null",
            tofile=f"b/{rel}",
        )

        out.append("".join(diff))

    return "\n".join(part for part in out if part)


def git_status(workspace: Path) -> dict:
    ensure_git_repo(workspace)
    return run_git(workspace, ["status", "--short"])


def git_diff(workspace: Path) -> dict:
    ensure_git_repo(workspace)

    status = run_git(workspace, ["status", "--short"])
    tracked = run_git(workspace, ["diff", "--", "."])

    tracked_diff = tracked["stdout"] or ""
    untracked_diff = _untracked_file_diff(workspace, status["stdout"] or "")
    combined_diff = "\n".join(part for part in [tracked_diff, untracked_diff] if part.strip())

    return {
        "ok": status["ok"] and tracked["ok"],
        "status": status["stdout"],
        "diff": combined_diff,
        "tracked_diff": tracked_diff,
        "untracked_diff": untracked_diff,
        "stderr": (status["stderr"] or "") + (tracked["stderr"] or ""),
    }


def checkpoint(workspace: Path, message: str) -> dict:
    ready = ensure_git_repo(workspace)
    if not ready["ok"]:
        return {"ok": False, "message": ready["message"]}

    add = run_git(workspace, ["add", "-A"])
    if not add["ok"]:
        return {"ok": False, "message": add["stderr"]}

    status = run_git(workspace, ["status", "--short"])
    if not status["stdout"].strip():
        return {"ok": True, "message": "Nothing to checkpoint.", "committed": False}

    commit = run_git(workspace, ["commit", "-m", message])

    return {
        "ok": commit["ok"],
        "message": commit["stdout"] or commit["stderr"],
        "committed": commit["ok"],
    }


def rollback(workspace: Path) -> dict:
    ready = ensure_git_repo(workspace)
    if not ready["ok"]:
        return {"ok": False, "message": ready["message"]}

    restore = run_git(workspace, ["restore", "."])
    clean = run_git(workspace, ["clean", "-fd"])

    return {
        "ok": restore["ok"] and clean["ok"],
        "message": (restore["stdout"] + restore["stderr"] + clean["stdout"] + clean["stderr"]).strip(),
    }
