#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v19_web_tools.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v19_web_tools_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py project_settings.py web_flow.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

# If v18 config somehow was not installed, create the config foundation.
if [ ! -f "src/agent_harness/project_settings.py" ]; then
cat > src/agent_harness/project_settings.py <<'PY'
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


def config_project(project: Path, args: list[str]) -> int:
    path = ensure_project_config(project)
    config = load_project_config(project)
    print(f"Project config: {path}")
    print(json.dumps(config, indent=2, sort_keys=True))
    return 0
PY
fi

cat > src/agent_harness/web_flow.py <<'PY'
from __future__ import annotations

import html
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

from .project_settings import ensure_project_config, load_project_config, project_max_dir


USER_AGENT = "MaxLocalAgent/0.19 terminal web reader"
DEFAULT_PREVIEW_CHARS = 8000


class ReadableHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self.skip_depth = 0
        self.block_tags = {
            "p",
            "div",
            "section",
            "article",
            "header",
            "footer",
            "main",
            "li",
            "ul",
            "ol",
            "h1",
            "h2",
            "h3",
            "h4",
            "h5",
            "h6",
            "br",
            "tr",
            "td",
            "th",
            "blockquote",
            "pre",
            "code",
        }
        self.skip_tags = {"script", "style", "noscript", "svg", "canvas"}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag in self.skip_tags:
            self.skip_depth += 1
            return
        if tag in self.block_tags:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in self.skip_tags and self.skip_depth > 0:
            self.skip_depth -= 1
            return
        if tag in self.block_tags:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self.skip_depth > 0:
            return
        text = data.strip()
        if text:
            self.parts.append(text + " ")

    def text(self) -> str:
        raw = "".join(self.parts)
        raw = html.unescape(raw)
        raw = re.sub(r"[ \t]+", " ", raw)
        raw = re.sub(r"\n\s*\n\s*\n+", "\n\n", raw)
        raw = re.sub(r" *\n *", "\n", raw)
        return raw.strip()


def _workspace_path(project: Path, config: dict[str, Any]) -> Path:
    workspace_value = str(config.get("workspace") or "workspace")
    workspace = Path(workspace_value).expanduser()

    if workspace.is_absolute():
        return workspace.resolve()

    return (project / workspace).resolve()


def _web_history_path(project: Path) -> Path:
    return project_max_dir(project) / "web-history.jsonl"


def _load_history(project: Path) -> list[dict[str, Any]]:
    path = _web_history_path(project)
    if not path.exists():
        return []

    records: list[dict[str, Any]] = []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)

    return records


def _append_history(project: Path, config: dict[str, Any], record: dict[str, Any]) -> None:
    path = _web_history_path(project)
    records = _load_history(project)
    records.append(record)

    history_cfg = config.get("history", {})
    max_items = 100
    if isinstance(history_cfg, dict):
        try:
            max_items = int(history_cfg.get("max_items", 100))
        except (TypeError, ValueError):
            max_items = 100

    records = records[-max_items:]

    text = ""
    for item in records:
        text += json.dumps(item, ensure_ascii=False) + "\n"

    path.write_text(text)


def _domain_matches(host: str, domain: str) -> bool:
    domain = domain.strip().lower()
    if not domain:
        return False
    return host == domain or host.endswith("." + domain)


def _check_network_allowed(project: Path, config: dict[str, Any], url: str) -> tuple[bool, str]:
    if not bool(config.get("allow_network", False)):
        return (
            False,
            "Network access is disabled for this project.\nEnable it with:\n  max config set allow_network true",
        )

    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        return False, "Only http and https URLs are supported."

    host = (parsed.hostname or "").lower()
    if not host:
        return False, "URL has no valid host."

    internet_cfg = config.get("internet", {})
    if not isinstance(internet_cfg, dict):
        internet_cfg = {}

    blocked = internet_cfg.get("blocked_domains", [])
    if isinstance(blocked, list):
        for domain in blocked:
            if isinstance(domain, str) and _domain_matches(host, domain):
                return False, f"Domain is blocked by project config: {host}"

    allowed = internet_cfg.get("allowed_domains", [])
    if isinstance(allowed, list) and allowed:
        matched = False
        for domain in allowed:
            if isinstance(domain, str) and _domain_matches(host, domain):
                matched = True
                break
        if not matched:
            return False, f"Domain is not in internet.allowed_domains: {host}"

    return True, ""


def _check_download_allowed(config: dict[str, Any]) -> tuple[bool, str]:
    if not bool(config.get("allow_downloads", False)):
        return (
            False,
            "Downloads are disabled for this project.\nEnable them with:\n  max config set allow_downloads true",
        )
    return True, ""


def _max_bytes(config: dict[str, Any]) -> int:
    internet_cfg = config.get("internet", {})
    if not isinstance(internet_cfg, dict):
        return 1000000

    try:
        return int(internet_cfg.get("max_bytes", 1000000))
    except (TypeError, ValueError):
        return 1000000


def _decode_bytes(data: bytes, content_type: str) -> str:
    charset = "utf-8"
    match = re.search(r"charset=([^;\s]+)", content_type, flags=re.I)
    if match:
        charset = match.group(1).strip("\"'")

    try:
        return data.decode(charset, errors="replace")
    except LookupError:
        return data.decode("utf-8", errors="replace")


def _fetch_url(project: Path, config: dict[str, Any], url: str) -> dict[str, Any]:
    allowed, message = _check_network_allowed(project, config, url)
    if not allowed:
        return {
            "ok": False,
            "url": url,
            "status": None,
            "content_type": "",
            "data": b"",
            "text": "",
            "bytes": 0,
            "truncated": False,
            "error": message,
        }

    limit = _max_bytes(config)
    started = time.time()

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,text/plain,application/json,*/*",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            content_type = response.headers.get("Content-Type", "")
            status = getattr(response, "status", 200)
            data = response.read(limit + 1)
    except urllib.error.HTTPError as exc:
        content_type = exc.headers.get("Content-Type", "") if exc.headers else ""
        status = exc.code
        data = exc.read(limit + 1)
    except Exception as exc:
        return {
            "ok": False,
            "url": url,
            "status": None,
            "content_type": "",
            "data": b"",
            "text": "",
            "bytes": 0,
            "truncated": False,
            "duration_sec": round(time.time() - started, 4),
            "error": str(exc),
        }

    truncated = len(data) > limit
    if truncated:
        data = data[:limit]

    text = _decode_bytes(data, content_type)

    return {
        "ok": 200 <= int(status) < 400,
        "url": url,
        "status": int(status),
        "content_type": content_type,
        "data": data,
        "text": text,
        "bytes": len(data),
        "truncated": truncated,
        "duration_sec": round(time.time() - started, 4),
        "error": "" if 200 <= int(status) < 400 else f"HTTP {status}",
    }


def _readable_text(raw: str, content_type: str) -> str:
    lowered = content_type.lower()
    if "html" not in lowered and "<html" not in raw.lower():
        return raw.strip()

    parser = ReadableHTMLParser()
    parser.feed(raw)
    return parser.text()


def _sanitize_filename(name: str) -> str:
    name = name.strip()
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
    name = name.strip("._")
    return name or "download"


def _filename_from_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    raw_name = Path(parsed.path).name
    if not raw_name:
        raw_name = "index.html"
    return _sanitize_filename(raw_name)


def _unique_path(path: Path) -> Path:
    if not path.exists():
        return path

    stem = path.stem
    suffix = path.suffix
    parent = path.parent

    for idx in range(2, 1000):
        candidate = parent / f"{stem}-{idx}{suffix}"
        if not candidate.exists():
            return candidate

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return parent / f"{stem}-{timestamp}{suffix}"


def _record(
    op: str,
    result: dict[str, Any],
    saved_path: str | None = None,
) -> dict[str, Any]:
    return {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "op": op,
        "url": result.get("url"),
        "status": result.get("status"),
        "content_type": result.get("content_type"),
        "bytes": result.get("bytes", 0),
        "truncated": result.get("truncated", False),
        "duration_sec": result.get("duration_sec", 0),
        "saved_path": saved_path,
        "ok": bool(result.get("ok")),
        "error": result.get("error", ""),
    }


def _usage() -> None:
    print("Use:")
    print("  max web fetch <url>")
    print("  max web read <url>")
    print("  max web save <url> [filename]")
    print("  max web history")
    print("")
    print("Enable network first:")
    print("  max config set allow_network true")
    print("")
    print("Enable downloads for save:")
    print("  max config set allow_downloads true")


def _print_fetch(result: dict[str, Any]) -> None:
    print(f"URL: {result.get('url')}")
    print(f"Status: {result.get('status')}")
    print(f"Content-Type: {result.get('content_type') or '(unknown)'}")
    print(f"Bytes: {result.get('bytes', 0)}")
    print(f"Truncated: {result.get('truncated', False)}")

    if result.get("error"):
        print("")
        print("Error:")
        print(result.get("error"))

    text = str(result.get("text") or "")
    if text:
        print("")
        print("Preview:")
        print(text[:DEFAULT_PREVIEW_CHARS].rstrip())


def _print_read(result: dict[str, Any]) -> None:
    print(f"URL: {result.get('url')}")
    print(f"Status: {result.get('status')}")
    print(f"Content-Type: {result.get('content_type') or '(unknown)'}")
    print(f"Bytes: {result.get('bytes', 0)}")
    print(f"Truncated: {result.get('truncated', False)}")

    if result.get("error"):
        print("")
        print("Error:")
        print(result.get("error"))

    readable = _readable_text(str(result.get("text") or ""), str(result.get("content_type") or ""))

    if readable:
        print("")
        print("Readable text:")
        print(readable[:DEFAULT_PREVIEW_CHARS].rstrip())
    else:
        print("")
        print("No readable text found.")


def _show_history(project: Path) -> int:
    records = _load_history(project)
    if not records:
        print("No web history yet.")
        return 1

    print("Recent web activity")
    print("")
    for idx, item in enumerate(reversed(records[-10:]), start=1):
        ok = "OK" if item.get("ok") else "FAIL"
        op = item.get("op", "?")
        status = item.get("status")
        url = item.get("url")
        saved = item.get("saved_path")
        line = f"{idx}. {ok} {op} {status} {url}"
        if saved:
            line += f" -> {saved}"
        print(line)

    return 0


def web_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)

    if not args or args[0] in {"help", "-h", "--help"}:
        _usage()
        return 0

    command = args[0]

    if command in {"history", "hist", "last"}:
        return _show_history(project)

    if command not in {"fetch", "read", "save", "download"}:
        print(f"Unknown web command: {command}")
        _usage()
        return 2

    if len(args) < 2:
        print("Missing URL.")
        _usage()
        return 2

    url = args[1]
    result = _fetch_url(project, config, url)

    if command == "fetch":
        _append_history(project, config, _record("fetch", result))
        _print_fetch(result)
        return 0 if result.get("ok") else 1

    if command == "read":
        _append_history(project, config, _record("read", result))
        _print_read(result)
        return 0 if result.get("ok") else 1

    allowed, message = _check_download_allowed(config)
    if not allowed:
        print(message)
        _append_history(project, config, _record("save", result))
        return 1

    if not result.get("ok"):
        _append_history(project, config, _record("save", result))
        _print_fetch(result)
        return 1

    workspace = _workspace_path(project, config)
    downloads = workspace / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)

    if len(args) >= 3:
        filename = _sanitize_filename(" ".join(args[2:]))
    else:
        filename = _filename_from_url(url)

    out_path = _unique_path(downloads / filename)
    out_path.write_bytes(result.get("data", b""))

    saved_rel = out_path.relative_to(project).as_posix() if out_path.is_relative_to(project) else str(out_path)

    _append_history(project, config, _record("save", result, saved_path=saved_rel))

    print(f"Saved: {saved_rel}")
    print(f"Status: {result.get('status')}")
    print(f"Content-Type: {result.get('content_type') or '(unknown)'}")
    print(f"Bytes: {result.get('bytes', 0)}")
    print(f"Truncated: {result.get('truncated', False)}")

    return 0
PY

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

# Remove old experimental v18 test-history leftovers if they exist.
lines = []
for line in text.splitlines():
    if line.strip() in {
        "from .test_flow import test_project, test_from_cwd",
        "from .test_flow import test_project",
        "from .test_flow import test_from_cwd",
    }:
        continue
    lines.append(line)
text = "\n".join(lines) + "\n"

text = re.sub(
    r'\n\s*if canonical == ["\']test["\']:\n\s*raise SystemExit\(test_project\(project, rest, normalizer=_normalize_safe_command_args\)\)\n',
    "\n",
    text,
)

text = re.sub(
    r'\n\s*if canonical == ["\']test["\']:\n\s*raise SystemExit\(test_from_cwd\(rest, normalizer=_normalize_safe_command_args\)\)\n',
    "\n",
    text,
)

# Add web import safely.
import_line = "from .web_flow import web_project as direct_web_project"

if import_line not in text:
    marker = "from .project_settings import config_project as direct_config_project\n"
    if marker in text:
        text = text.replace(marker, marker + import_line + "\n", 1)
    else:
        marker = "from .skill_manager import skills_command as max_skills_command\n"
        if marker in text:
            text = text.replace(marker, marker + import_line + "\n", 1)
        else:
            future = "from __future__ import annotations\n"
            text = text.replace(future, future + import_line + "\n", 1)

# Add command table entry.
if '"web": {' not in text:
    marker = '    "read": {'
    entry = '''    "web": {
        "aliases": ["internet", "url"],
        "summary": "Fetch, read, or save URLs using project permissions.",
        "usage": "max web [fetch|read|save|history] <url>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
'''
    if marker not in text:
        raise SystemExit("Could not find COMMANDS insertion point before read.")
    text = text.replace(marker, entry + marker, 1)

# Add direct web function.
if "def _direct_web(" not in text:
    marker = "def main(argv: list[str] | None = None) -> int:\n"
    func = '''\n\ndef _direct_web(args: list[str]) -> int:\n    project, rest = _direct_project_and_rest(args)\n    if project is None:\n        ui.fail("No project selected.")\n        print("Use: max use <project> or max new <project>")\n        return 2\n    return direct_web_project(project, rest)\n\n\n'''
    if marker not in text:
        raise SystemExit("Could not find main() in max_cli.py")
    text = text.replace(marker, func + marker, 1)

# Route max web before generic dispatch.
branch = '''    if argv and argv[0] in {"web", "internet", "url"}:\n        return _direct_web(argv[1:])\n\n'''

if branch not in text:
    markers = [
        '    if argv and argv[0] in {"config", "settings", "set"}:\n',
        '    if argv and argv[0] in {"plan", "outline"}:\n',
    ]
    for marker in markers:
        if marker in text:
            text = text.replace(marker, branch + marker, 1)
            break
    else:
        raise SystemExit("Could not find direct command section in main().")

# Update help dashboard.
if '("max web read https://example.com", "Read a URL with project permissions")' not in text:
    text = text.replace(
        '("max search Max", "Search workspace files"),',
        '("max search Max", "Search workspace files"),\n        ("max web read https://example.com", "Read a URL with project permissions"),',
    )

# Add web to detailed help Daily group.
text = text.replace(
    '"read", "search", "index"',
    '"read", "search", "web", "index"',
)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.19 max web tools installed."
echo ""
echo "Enable permissions:"
echo "  max config set allow_network true"
echo "  max config set allow_downloads true"
echo ""
echo "Try:"
echo "  max web fetch https://example.com"
echo "  max web read https://example.com"
echo "  max web save https://example.com example.html"
echo "  max web history"
