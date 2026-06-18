from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any


APP_HOME = Path.home() / ".agent-harness"
LOG_DIR = APP_HOME / "logs"


def ensure_app_home() -> None:
    APP_HOME.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)


def now_ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))


def append_log(path: Path, line: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(line.rstrip() + "\n")


def meminfo_gb() -> dict[str, float]:
    out: dict[str, float] = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, rest = line.split(":", 1)
            kb = float(rest.strip().split()[0])
            out[key] = kb / 1024 / 1024
    except Exception:
        pass
    return out
