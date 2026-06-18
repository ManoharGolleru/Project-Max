from __future__ import annotations

import subprocess
import time
from pathlib import Path

from .permissions import approval_prompt, validate_command
from .util import now_ts


def run_command(
    command: str,
    cwd: Path,
    workspace_root: Path,
    reason: str,
    ask: bool = True,
) -> dict:
    cwd = cwd.resolve()
    workspace_root = workspace_root.resolve()

    valid, validation_reason = validate_command(command, cwd, workspace_root)

    if not valid:
        return {
            "ok": False,
            "blocked": True,
            "reason": validation_reason,
            "command": command,
            "cwd": str(cwd),
        }

    if ask and not approval_prompt(command, cwd, reason):
        return {
            "ok": False,
            "blocked": True,
            "reason": "user denied approval",
            "command": command,
            "cwd": str(cwd),
        }

    start = time.time()

    try:
        proc = subprocess.run(
            command,
            cwd=str(cwd),
            shell=True,
            text=True,
            capture_output=True,
            timeout=120,
        )

        duration = time.time() - start

        return {
            "ok": proc.returncode == 0,
            "blocked": False,
            "timestamp": now_ts(),
            "command": command,
            "cwd": str(cwd),
            "exit_code": proc.returncode,
            "duration_sec": round(duration, 3),
            "stdout": proc.stdout[-8000:],
            "stderr": proc.stderr[-8000:],
        }

    except subprocess.TimeoutExpired as e:
        duration = time.time() - start

        return {
            "ok": False,
            "blocked": False,
            "timestamp": now_ts(),
            "command": command,
            "cwd": str(cwd),
            "exit_code": None,
            "duration_sec": round(duration, 3),
            "stdout": (e.stdout or "")[-8000:] if isinstance(e.stdout, str) else "",
            "stderr": "Command timed out.",
        }
