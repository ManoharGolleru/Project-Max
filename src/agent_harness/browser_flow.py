from __future__ import annotations

import html
import json
import os
import re
import shutil
import subprocess
import time
import urllib.parse
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

from .project_settings import ensure_project_config, load_project_config, project_max_dir


DEFAULT_TEXT_CHARS = 12000


class BrowserTextParser(HTMLParser):
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


def _history_path(project: Path) -> Path:
    return project_max_dir(project) / "browser-history.jsonl"


def _load_history(project: Path) -> list[dict[str, Any]]:
    path = _history_path(project)
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
    path = _history_path(project)
    records = _load_history(project)
    records.append(record)

    max_items = 100
    history_cfg = config.get("history", {})
    if isinstance(history_cfg, dict):
        try:
            max_items = int(history_cfg.get("max_items", 100))
        except (TypeError, ValueError):
            max_items = 100

    records = records[-max_items:]
    path.write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in records))


def _record(
    op: str,
    url: str | None,
    ok: bool,
    backend: str,
    duration_sec: float = 0,
    saved_path: str | None = None,
    error: str = "",
) -> dict[str, Any]:
    return {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "op": op,
        "url": url,
        "ok": ok,
        "backend": backend,
        "duration_sec": round(duration_sec, 4),
        "saved_path": saved_path,
        "error": error,
    }


def _browser_allowed(config: dict[str, Any]) -> tuple[bool, str]:
    if not bool(config.get("allow_browser", False)):
        return (
            False,
            "Browser access is disabled for this project.\nEnable it with:\n  max config set allow_browser true",
        )
    return True, ""


def _timeout_sec(config: dict[str, Any]) -> int:
    browser_cfg = config.get("browser", {})
    if not isinstance(browser_cfg, dict):
        return 30
    try:
        return int(browser_cfg.get("timeout_sec", 30))
    except (TypeError, ValueError):
        return 30


def _headless(config: dict[str, Any]) -> bool:
    browser_cfg = config.get("browser", {})
    if not isinstance(browser_cfg, dict):
        return True
    return bool(browser_cfg.get("headless", True))


def _valid_url(url: str) -> tuple[bool, str]:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        return False, "Only http and https URLs are supported."
    if not parsed.hostname:
        return False, "URL has no valid host."
    return True, ""


def _playwright_available() -> bool:
    try:
        import playwright.sync_api  # noqa: F401
        return True
    except Exception:
        return False


def _find_chromium() -> str | None:
    env_path = os.environ.get("MAX_CHROMIUM")
    if env_path and Path(env_path).exists():
        return env_path

    for name in [
        "chromium",
        "chromium-browser",
        "google-chrome",
        "google-chrome-stable",
        "microsoft-edge",
        "brave-browser",
    ]:
        found = shutil.which(name)
        if found:
            return found

    return None


def _available_backend() -> tuple[str, str | None]:
    if _playwright_available():
        return "playwright", None

    chromium = _find_chromium()
    if chromium:
        return "chromium-cli", chromium

    return "none", None


def _clean_html(raw_html: str) -> str:
    parser = BrowserTextParser()
    parser.feed(raw_html)
    return parser.text()


def _sanitize_filename(value: str) -> str:
    value = value.strip()
    value = re.sub(r"[^A-Za-z0-9._-]+", "_", value)
    value = value.strip("._")
    return value or "browser-artifact"


def _default_screenshot_name(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or "page"
    path = parsed.path.strip("/").replace("/", "-")
    base = host if not path else f"{host}-{path}"
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return _sanitize_filename(f"{base}-{stamp}.png")


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

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return parent / f"{stem}-{stamp}{suffix}"


def _run_chromium(args: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        args,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    return proc


def _chromium_base_args(binary: str, config: dict[str, Any]) -> list[str]:
    args = [
        binary,
        "--disable-gpu",
        "--no-sandbox",
        "--disable-dev-shm-usage",
    ]

    if _headless(config):
        args.append("--headless=new")

    return args


def _chromium_text(binary: str, config: dict[str, Any], url: str) -> tuple[bool, str, str]:
    timeout = _timeout_sec(config)
    args = _chromium_base_args(binary, config) + [
        "--dump-dom",
        "--virtual-time-budget=5000",
        url,
    ]

    try:
        proc = _run_chromium(args, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "", "Chromium timed out."

    if proc.returncode != 0 and "--headless=new" in args:
        args = [item if item != "--headless=new" else "--headless" for item in args]
        try:
            proc = _run_chromium(args, timeout=timeout)
        except subprocess.TimeoutExpired:
            return False, "", "Chromium timed out."

    if proc.returncode != 0:
        return False, "", proc.stderr.strip() or "Chromium failed."

    return True, _clean_html(proc.stdout), ""


def _chromium_screenshot(
    binary: str,
    config: dict[str, Any],
    url: str,
    out_path: Path,
) -> tuple[bool, str]:
    timeout = _timeout_sec(config)
    args = _chromium_base_args(binary, config) + [
        "--window-size=1280,900",
        "--virtual-time-budget=5000",
        f"--screenshot={out_path}",
        url,
    ]

    try:
        proc = _run_chromium(args, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "Chromium timed out."

    if proc.returncode != 0 and "--headless=new" in args:
        args = [item if item != "--headless=new" else "--headless" for item in args]
        try:
            proc = _run_chromium(args, timeout=timeout)
        except subprocess.TimeoutExpired:
            return False, "Chromium timed out."

    if proc.returncode != 0:
        return False, proc.stderr.strip() or "Chromium screenshot failed."

    if not out_path.exists():
        return False, "Chromium reported success but no screenshot file was created."

    return True, ""


def _playwright_text(config: dict[str, Any], url: str) -> tuple[bool, str, str]:
    try:
        from playwright.sync_api import sync_playwright
    except Exception as exc:
        return False, "", str(exc)

    timeout_ms = _timeout_sec(config) * 1000

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=_headless(config))
            page = browser.new_page(viewport={"width": 1280, "height": 900})
            page.goto(url, wait_until="networkidle", timeout=timeout_ms)
            content = page.content()
            browser.close()
        return True, _clean_html(content), ""
    except Exception as exc:
        return False, "", str(exc)


def _playwright_screenshot(
    config: dict[str, Any],
    url: str,
    out_path: Path,
) -> tuple[bool, str]:
    try:
        from playwright.sync_api import sync_playwright
    except Exception as exc:
        return False, str(exc)

    timeout_ms = _timeout_sec(config) * 1000

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=_headless(config))
            page = browser.new_page(viewport={"width": 1280, "height": 900})
            page.goto(url, wait_until="networkidle", timeout=timeout_ms)
            page.screenshot(path=str(out_path), full_page=True)
            browser.close()
        return True, ""
    except Exception as exc:
        return False, str(exc)


def _check(project: Path, config: dict[str, Any]) -> int:
    backend, binary = _available_backend()

    print("Browser tool check")
    print("")
    print(f"allow_browser: {config.get('allow_browser', False)}")
    print(f"headless: {_headless(config)}")
    print(f"timeout_sec: {_timeout_sec(config)}")
    print("")
    print(f"Playwright installed: {_playwright_available()}")
    print(f"Chromium/Chrome binary: {binary or '(not found)'}")
    print(f"Selected backend: {backend}")

    if backend == "none":
        print("")
        print("Install one backend:")
        print("  python3 -m pip install playwright")
        print("  python3 -m playwright install chromium")
        print("")
        print("Or install Chromium/Chrome for your Ubuntu setup.")
        return 1

    return 0


def _usage() -> None:
    print("Use:")
    print("  max browser check")
    print("  max browser text <url>")
    print("  max browser screenshot <url> [filename.png]")
    print("  max browser history")
    print("")
    print("Enable browser first:")
    print("  max config set allow_browser true")


def _show_history(project: Path) -> int:
    records = _load_history(project)
    if not records:
        print("No browser history yet.")
        return 1

    print("Recent browser activity")
    print("")
    for idx, item in enumerate(reversed(records[-10:]), start=1):
        ok = "OK" if item.get("ok") else "FAIL"
        op = item.get("op", "?")
        backend = item.get("backend", "?")
        url = item.get("url")
        saved = item.get("saved_path")
        line = f"{idx}. {ok} {op} [{backend}] {url}"
        if saved:
            line += f" -> {saved}"
        if item.get("error") and not item.get("ok"):
            line += f" :: {item.get('error')}"
        print(line)

    return 0


def browser_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)

    if not args or args[0] in {"help", "-h", "--help"}:
        _usage()
        return 0

    command = args[0]

    if command == "check":
        return _check(project, config)

    if command in {"history", "hist", "last"}:
        return _show_history(project)

    allowed, message = _browser_allowed(config)
    if not allowed:
        print(message)
        return 1

    if command not in {"text", "read", "screenshot", "shot"}:
        print(f"Unknown browser command: {command}")
        _usage()
        return 2

    if len(args) < 2:
        print("Missing URL.")
        _usage()
        return 2

    url = args[1]
    ok, message = _valid_url(url)
    if not ok:
        print(message)
        return 2

    backend, binary = _available_backend()
    if backend == "none":
        print("No browser backend found.")
        print("")
        print("Install one backend:")
        print("  python3 -m pip install playwright")
        print("  python3 -m playwright install chromium")
        print("")
        print("Or install Chromium/Chrome for your Ubuntu setup.")
        return 1

    if command in {"text", "read"}:
        started = time.time()

        if backend == "playwright":
            ok, text, error = _playwright_text(config, url)
        else:
            assert binary is not None
            ok, text, error = _chromium_text(binary, config, url)

        duration = time.time() - started
        _append_history(project, config, _record("text", url, ok, backend, duration_sec=duration, error=error))

        if not ok:
            print("Browser text failed.")
            print(error)
            return 1

        print(f"URL: {url}")
        print(f"Backend: {backend}")
        print("")
        print("Rendered text:")
        print(text[:DEFAULT_TEXT_CHARS].rstrip())
        return 0

    workspace = _workspace_path(project, config)
    artifacts = workspace / "browser-artifacts"
    artifacts.mkdir(parents=True, exist_ok=True)

    if len(args) >= 3:
        filename = _sanitize_filename(" ".join(args[2:]))
        if not filename.lower().endswith(".png"):
            filename += ".png"
    else:
        filename = _default_screenshot_name(url)

    out_path = _unique_path(artifacts / filename)

    started = time.time()

    if backend == "playwright":
        ok, error = _playwright_screenshot(config, url, out_path)
    else:
        assert binary is not None
        ok, error = _chromium_screenshot(binary, config, url, out_path)

    duration = time.time() - started

    try:
        saved_rel = out_path.relative_to(project).as_posix()
    except ValueError:
        saved_rel = str(out_path)

    _append_history(
        project,
        config,
        _record(
            "screenshot",
            url,
            ok,
            backend,
            duration_sec=duration,
            saved_path=saved_rel if ok else None,
            error=error,
        ),
    )

    if not ok:
        print("Browser screenshot failed.")
        print(error)
        return 1

    print(f"Saved screenshot: {saved_rel}")
    print(f"Backend: {backend}")
    return 0
