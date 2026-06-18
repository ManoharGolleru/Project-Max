from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any


OLLAMA_BASE = "http://localhost:11434"


class OllamaError(RuntimeError):
    pass


def api_get(path: str) -> Any:
    url = OLLAMA_BASE + path
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        raise OllamaError(str(e)) from e


def chat(
    model: str,
    messages: list[dict[str, str]],
    num_ctx: int = 8192,
    temperature: float = 0.2,
) -> dict[str, Any]:
    url = OLLAMA_BASE + "/api/chat"

    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "options": {
            "num_ctx": num_ctx,
            "temperature": temperature,
        },
    }

    data = json.dumps(payload).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise OllamaError(f"HTTP {e.code}: {body}") from e
    except Exception as e:
        raise OllamaError(str(e)) from e


def extract_message_text(response: dict[str, Any]) -> str:
    msg = response.get("message") or {}
    return msg.get("content", "")
