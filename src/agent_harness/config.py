from __future__ import annotations

from pathlib import Path
from typing import Any

from .util import APP_HOME, read_json, write_json


DEFAULT_CONFIG = {
    "model": "hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M",
    "default_context": 8192,
    "stress_contexts": [4096, 8192, 16384, 32768],
    "temperature": 0.2,
    "ram_limit_gb": 10,
    "approval_mode": "prompt",
}


def config_path() -> Path:
    return APP_HOME / "config.json"


def load_config() -> dict[str, Any]:
    cfg = dict(DEFAULT_CONFIG)
    existing = read_json(config_path(), {})
    if isinstance(existing, dict):
        cfg.update(existing)
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    merged = dict(DEFAULT_CONFIG)
    merged.update(cfg)
    write_json(config_path(), merged)
