from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from .config import load_config
from .ollama_client import api_get
from .util import APP_HOME, ensure_app_home, meminfo_gb, write_json


def cmd_version(cmd: str, args: list[str]) -> str:
    if not shutil.which(cmd):
        return "missing"

    try:
        out = subprocess.run(
            [cmd] + args,
            text=True,
            capture_output=True,
            timeout=8,
        )
        text = (out.stdout or out.stderr).strip()
        return text.splitlines()[0] if text else "found"
    except Exception as e:
        return f"error: {e}"


def disk_free_gb(path: Path) -> float:
    try:
        usage = shutil.disk_usage(path)
        return round(usage.free / 1024 / 1024 / 1024, 2)
    except Exception:
        return 0.0


def run_doctor(json_only: bool = False) -> dict:
    ensure_app_home()
    cfg = load_config()
    mem = meminfo_gb()

    report = {
        "config_path": str(APP_HOME / "config.json"),
        "configured_model": cfg["model"],
        "configured_default_context": cfg["default_context"],
        "configured_ram_limit_gb": cfg["ram_limit_gb"],
        "python": cmd_version("python3", ["--version"]),
        "git": cmd_version("git", ["--version"]),
        "docker": cmd_version("docker", ["--version"]),
        "node": cmd_version("node", ["--version"]),
        "npm": cmd_version("npm", ["--version"]),
        "ollama": cmd_version("ollama", ["--version"]),
        "ram_total_gb": round(mem.get("MemTotal", 0), 2),
        "ram_available_gb": round(mem.get("MemAvailable", 0), 2),
        "swap_total_gb": round(mem.get("SwapTotal", 0), 2),
        "swap_free_gb": round(mem.get("SwapFree", 0), 2),
        "disk_free_home_gb": disk_free_gb(Path.home()),
        "ollama_api": "unknown",
        "ollama_models": [],
    }

    try:
        tags = api_get("/api/tags")
        report["ollama_api"] = "ok"
        report["ollama_models"] = [m.get("name", "") for m in tags.get("models", [])]
    except Exception as e:
        report["ollama_api"] = f"error: {e}"

    write_json(APP_HOME / "doctor_report.json", report)

    if not json_only:
        print("agentctl doctor")
        print("")

        for k, v in report.items():
            if k == "ollama_models":
                print(f"{k}: {len(v)} model(s)")
                for name in v[:20]:
                    print(f"  - {name}")
            else:
                print(f"{k}: {v}")

        print("")
        print(f"Report saved to: {APP_HOME / 'doctor_report.json'}")

    return report
