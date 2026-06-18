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
    ok_override: bool | None = None,
    error_override: str | None = None,
) -> dict[str, Any]:
    ok = bool(result.get("ok")) if ok_override is None else bool(ok_override)
    error = str(result.get("error", "")) if error_override is None else error_override

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
        "ok": ok,
        "error": error,
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
        _append_history(
            project,
            config,
            _record("save", result, ok_override=False, error_override="Downloads disabled"),
        )
        print("")
        print("Current setting:")
        print(f"  allow_downloads = {config.get('allow_downloads', False)}")
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

    try:
        saved_rel = out_path.relative_to(project).as_posix()
    except ValueError:
        saved_rel = str(out_path)

    _append_history(project, config, _record("save", result, saved_path=saved_rel))

    print(f"Saved: {saved_rel}")
    print(f"Status: {result.get('status')}")
    print(f"Content-Type: {result.get('content_type') or '(unknown)'}")
    print(f"Bytes: {result.get('bytes', 0)}")
    print(f"Truncated: {result.get('truncated', False)}")

    return 0
