from __future__ import annotations

import json
import shutil
import subprocess
import urllib.request

from .config import load_config


def unload_model(model: str | None = None) -> dict:
    cfg = load_config()

    if model is None:
        model = cfg["model"]

    result = {
        "model": model,
        "ok": False,
        "method": None,
        "stdout": "",
        "stderr": "",
        "error": "",
    }

    if shutil.which("ollama"):
        try:
            proc = subprocess.run(
                ["ollama", "stop", model],
                text=True,
                capture_output=True,
                timeout=60,
            )
            result["method"] = "ollama stop"
            result["stdout"] = proc.stdout
            result["stderr"] = proc.stderr

            if proc.returncode == 0:
                result["ok"] = True
                return result

        except Exception as e:
            result["error"] = str(e)

    # Fallback: ask Ollama API to unload with keep_alive=0.
    try:
        payload = {
            "model": model,
            "prompt": "",
            "stream": False,
            "keep_alive": 0,
        }

        data = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(
            "http://localhost:11434/api/generate",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8", errors="replace")

        result["method"] = "api keep_alive=0"
        result["stdout"] = body
        result["ok"] = True

    except Exception as e:
        result["error"] = str(e)

    return result
