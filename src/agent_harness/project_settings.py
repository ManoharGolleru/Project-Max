from __future__ import annotations

import json
from pathlib import Path
from typing import Any


DEFAULT_PROJECT_CONFIG: dict[str, Any] = {
    "workspace": "workspace",
    "allow_network": False,
    "allow_browser": False,
    "allow_downloads": False,
    "browser": {
        "headless": True,
        "timeout_sec": 30,
    },
    "internet": {
        "max_bytes": 1000000,
        "allowed_domains": [],
        "blocked_domains": [],
    },
    "history": {
        "max_items": 100,
    },
}

ALIASES = {
    "network": "allow_network",
    "internet": "allow_network",
    "web": "allow_network",
    "browser": "allow_browser",
    "chromium": "allow_browser",
    "downloads": "allow_downloads",
    "download": "allow_downloads",
}


def project_max_dir(project: Path) -> Path:
    path = project / ".max"
    path.mkdir(parents=True, exist_ok=True)
    return path


def project_config_path(project: Path) -> Path:
    return project_max_dir(project) / "config.json"


def _deep_merge(defaults: dict[str, Any], existing: dict[str, Any]) -> dict[str, Any]:
    merged: dict[str, Any] = {}
    for key, value in defaults.items():
        if isinstance(value, dict):
            incoming = existing.get(key, {})
            if isinstance(incoming, dict):
                merged[key] = _deep_merge(value, incoming)
            else:
                merged[key] = dict(value)
        else:
            merged[key] = existing.get(key, value)

    for key, value in existing.items():
        if key not in merged:
            merged[key] = value

    return merged


def load_project_config(project: Path) -> dict[str, Any]:
    path = project_config_path(project)
    if not path.exists():
        return _deep_merge(DEFAULT_PROJECT_CONFIG, {})

    try:
        existing = json.loads(path.read_text())
    except json.JSONDecodeError:
        existing = {}

    if not isinstance(existing, dict):
        existing = {}

    return _deep_merge(DEFAULT_PROJECT_CONFIG, existing)


def save_project_config(project: Path, config: dict[str, Any]) -> Path:
    path = project_config_path(project)
    path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
    return path


def ensure_project_config(project: Path) -> Path:
    config = load_project_config(project)
    return save_project_config(project, config)


def _coerce_value(raw: str) -> Any:
    lowered = raw.strip().lower()

    if lowered in {"true", "yes", "on", "1"}:
        return True

    if lowered in {"false", "no", "off", "0"}:
        return False

    if lowered in {"none", "null"}:
        return None

    try:
        return int(raw)
    except ValueError:
        pass

    try:
        return float(raw)
    except ValueError:
        pass

    if raw.startswith("[") or raw.startswith("{"):
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass

    return raw


def _resolve_key(key: str) -> str:
    return ALIASES.get(key, key)


def _set_nested(config: dict[str, Any], dotted_key: str, value: Any) -> None:
    parts = dotted_key.split(".")
    target = config

    for part in parts[:-1]:
        next_value = target.get(part)
        if not isinstance(next_value, dict):
            next_value = {}
            target[part] = next_value
        target = next_value

    target[parts[-1]] = value


def _get_nested(config: dict[str, Any], dotted_key: str) -> Any:
    parts = dotted_key.split(".")
    value: Any = config

    for part in parts:
        if not isinstance(value, dict) or part not in value:
            raise KeyError(dotted_key)
        value = value[part]

    return value


def _print_config(config: dict[str, Any]) -> None:
    print(json.dumps(config, indent=2, sort_keys=True))


def _print_usage() -> None:
    print("Use:")
    print("  max config show")
    print("  max config path")
    print("  max config set allow_network true")
    print("  max config set allow_browser true")
    print("  max config set allow_downloads true")
    print("  max config get allow_network")
    print("  max config enable network")
    print("  max config disable browser")


def config_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    path = ensure_project_config(project)
    config = load_project_config(project)

    if not args or args[0] in {"show", "json", "list"}:
        print(f"Project config: {path}")
        _print_config(config)
        return 0

    command = args[0]

    if command == "path":
        print(path)
        return 0

    if command == "help":
        _print_usage()
        return 0

    if command == "init":
        save_project_config(project, config)
        print(f"Project config initialized: {path}")
        return 0

    if command == "get":
        if len(args) < 2:
            print("Missing config key.")
            print("Example: max config get allow_network")
            return 2

        key = _resolve_key(args[1])

        try:
            value = _get_nested(config, key)
        except KeyError:
            print(f"Config key not found: {key}")
            return 1

        if isinstance(value, (dict, list)):
            print(json.dumps(value, indent=2, sort_keys=True))
        else:
            print(value)

        return 0

    if command == "set":
        if len(args) < 3:
            print("Missing config key or value.")
            print("Example: max config set allow_network true")
            return 2

        key = _resolve_key(args[1])
        value = _coerce_value(" ".join(args[2:]))

        _set_nested(config, key, value)
        save_project_config(project, config)

        print(f"Updated {key} = {value}")
        print(f"Project config: {path}")
        return 0

    if command in {"enable", "allow"}:
        if len(args) < 2:
            print("Missing feature name.")
            print("Example: max config enable network")
            return 2

        key = _resolve_key(args[1])
        _set_nested(config, key, True)
        save_project_config(project, config)

        print(f"Enabled {key}")
        return 0

    if command in {"disable", "deny"}:
        if len(args) < 2:
            print("Missing feature name.")
            print("Example: max config disable browser")
            return 2

        key = _resolve_key(args[1])
        _set_nested(config, key, False)
        save_project_config(project, config)

        print(f"Disabled {key}")
        return 0

    print(f"Unknown config command: {command}")
    _print_usage()
    return 2
