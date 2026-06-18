from __future__ import annotations

import html
import json
import re
import urllib.parse
from datetime import datetime
from pathlib import Path
from typing import Any

from .project_settings import ensure_project_config, load_project_config, project_max_dir
from .web_flow import _fetch_url, _readable_text


DEFAULT_LIMIT = 3
MAX_SOURCE_CHARS = 5000


def _workspace_path(project: Path, config: dict[str, Any]) -> Path:
    workspace_value = str(config.get("workspace") or "workspace")
    workspace = Path(workspace_value).expanduser()

    if workspace.is_absolute():
        return workspace.resolve()

    return (project / workspace).resolve()


def _history_path(project: Path) -> Path:
    return project_max_dir(project) / "research-history.jsonl"


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


def _sanitize_filename(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"[^a-z0-9._-]+", "_", value)
    value = value.strip("._")
    return value[:80] or "research"


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


def _extract_search_urls(raw_html: str) -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()

    for match in re.finditer(r"""href=["']([^"']+)["']""", raw_html):
        href = html.unescape(match.group(1)).strip()

        if not href:
            continue

        if href.startswith("//"):
            href = "https:" + href

        # DuckDuckGo often returns relative redirect links:
        #   /l/?uddg=https%3A%2F%2Fexample.com
        if href.startswith("/l/") or href.startswith("/l?"):
            href = "https://duckduckgo.com" + href

        parsed = urllib.parse.urlparse(href)
        host = parsed.hostname or ""

        final_url = ""

        # DuckDuckGo redirect links store the real page in the uddg query param.
        if "duckduckgo.com" in host and parsed.path.startswith("/l"):
            qs = urllib.parse.parse_qs(parsed.query)
            uddg = qs.get("uddg", [""])[0]
            if uddg:
                final_url = urllib.parse.unquote(uddg)

        # Some search engines use /url?q=<real-url>.
        elif parsed.path == "/url":
            qs = urllib.parse.parse_qs(parsed.query)
            q_value = qs.get("q", [""])[0]
            if q_value:
                final_url = urllib.parse.unquote(q_value)

        elif parsed.scheme in {"http", "https"}:
            final_url = href

        if not final_url:
            continue

        final_parsed = urllib.parse.urlparse(final_url)
        final_host = final_parsed.hostname or ""

        if final_parsed.scheme not in {"http", "https"}:
            continue

        if not final_host:
            continue

        if any(skip in final_host for skip in [
            "duckduckgo.com",
            "google.com",
            "bing.com",
            "yahoo.com",
        ]):
            continue

        if final_url in seen:
            continue

        seen.add(final_url)
        urls.append(final_url)

    return urls


def _search_duckduckgo(project: Path, config: dict[str, Any], query: str, limit: int) -> tuple[list[str], str]:
    encoded = urllib.parse.urlencode({"q": query})
    search_urls = [
        f"https://html.duckduckgo.com/html/?{encoded}",
        f"https://lite.duckduckgo.com/lite/?{encoded}",
    ]

    errors: list[str] = []

    for search_url in search_urls:
        result = _fetch_url(project, config, search_url)
        if not result.get("ok"):
            errors.append(str(result.get("error") or f"Search failed for {search_url}"))
            continue

        urls = _extract_search_urls(str(result.get("text") or ""))
        if urls:
            return urls[:limit], ""

        errors.append(f"No result links parsed from {search_url}")

    if errors:
        return [], "; ".join(errors)

    return [], "Search failed."


def _read_url(project: Path, config: dict[str, Any], url: str) -> dict[str, Any]:
    result = _fetch_url(project, config, url)
    readable = ""

    if result.get("text"):
        readable = _readable_text(
            str(result.get("text") or ""),
            str(result.get("content_type") or ""),
        )

    return {
        "url": url,
        "ok": bool(result.get("ok")),
        "status": result.get("status"),
        "content_type": result.get("content_type"),
        "bytes": result.get("bytes", 0),
        "truncated": result.get("truncated", False),
        "error": result.get("error", ""),
        "text": readable,
    }


def _parse_limit(args: list[str]) -> tuple[list[str], int]:
    cleaned: list[str] = []
    limit = DEFAULT_LIMIT
    idx = 0

    while idx < len(args):
        item = args[idx]

        if item in {"--limit", "-n"} and idx + 1 < len(args):
            try:
                limit = max(1, min(10, int(args[idx + 1])))
            except ValueError:
                limit = DEFAULT_LIMIT
            idx += 2
            continue

        if item.startswith("--limit="):
            raw = item.split("=", 1)[1]
            try:
                limit = max(1, min(10, int(raw)))
            except ValueError:
                limit = DEFAULT_LIMIT
            idx += 1
            continue

        cleaned.append(item)
        idx += 1

    return cleaned, limit


def _make_note(
    project: Path,
    config: dict[str, Any],
    title: str,
    mode: str,
    query_or_urls: str,
    sources: list[dict[str, Any]],
) -> Path:
    workspace = _workspace_path(project, config)
    notes_dir = workspace / "research-notes"
    notes_dir.mkdir(parents=True, exist_ok=True)

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = _sanitize_filename(f"{title}_{stamp}") + ".md"
    path = _unique_path(notes_dir / filename)

    lines: list[str] = []
    lines.append(f"# Research note: {title}")
    lines.append("")
    lines.append(f"Created: {datetime.now().isoformat(timespec='seconds')}")
    lines.append(f"Mode: {mode}")
    lines.append(f"Input: {query_or_urls}")
    lines.append("")
    lines.append("## Sources")
    lines.append("")

    for idx, source in enumerate(sources, start=1):
        status = source.get("status")
        ok = "OK" if source.get("ok") else "FAIL"
        lines.append(f"{idx}. {ok} {status} {source.get('url')}")

    lines.append("")
    lines.append("## Extracted text")
    lines.append("")

    for idx, source in enumerate(sources, start=1):
        lines.append(f"### Source {idx}")
        lines.append("")
        lines.append(f"URL: {source.get('url')}")
        lines.append(f"Status: {source.get('status')}")
        lines.append(f"Content-Type: {source.get('content_type')}")
        lines.append(f"Bytes: {source.get('bytes')}")
        lines.append("")

        if source.get("error"):
            lines.append(f"Error: {source.get('error')}")
            lines.append("")

        text = str(source.get("text") or "").strip()
        if text:
            lines.append(text[:MAX_SOURCE_CHARS].rstrip())
        else:
            lines.append("(No readable text extracted.)")

        lines.append("")
        lines.append("---")
        lines.append("")

    path.write_text("\n".join(lines) + "\n")

    return path


def _show_history(project: Path) -> int:
    records = _load_history(project)
    if not records:
        print("No research history yet.")
        return 1

    print("Recent research activity")
    print("")
    for idx, item in enumerate(reversed(records[-10:]), start=1):
        ok = "OK" if item.get("ok") else "FAIL"
        mode = item.get("mode", "?")
        title = item.get("title", "?")
        saved = item.get("saved_path", "")
        line = f"{idx}. {ok} {mode} {title}"
        if saved:
            line += f" -> {saved}"
        print(line)

    return 0


def _usage() -> None:
    print("Use:")
    print("  max research \"query text\"")
    print("  max research search \"query text\" --limit 3")
    print("  max research url https://example.com")
    print("  max research urls https://example.com https://www.python.org")
    print("  max research history")
    print("")
    print("Network must be enabled:")
    print("  max config set allow_network true")


def research_project(project: Path, args: list[str]) -> int:
    project = project.expanduser().resolve()
    ensure_project_config(project)
    config = load_project_config(project)

    if not args or args[0] in {"help", "-h", "--help"}:
        _usage()
        return 0

    if args[0] in {"history", "hist", "last"}:
        return _show_history(project)

    args, limit = _parse_limit(args)

    mode = "search"
    title = ""
    urls: list[str] = []
    query_or_urls = ""

    if args and args[0] in {"url", "read", "source"}:
        if len(args) < 2:
            print("Missing URL.")
            _usage()
            return 2
        mode = "url"
        urls = [args[1]]
        title = urllib.parse.urlparse(args[1]).hostname or "url"
        query_or_urls = args[1]

    elif args and args[0] in {"urls", "sources"}:
        if len(args) < 2:
            print("Missing URLs.")
            _usage()
            return 2
        mode = "urls"
        urls = args[1:]
        title = "multiple_sources"
        query_or_urls = " ".join(urls)

    else:
        if args and args[0] == "search":
            query = " ".join(args[1:]).strip()
        else:
            query = " ".join(args).strip()

        if not query:
            print("Missing search query.")
            _usage()
            return 2

        mode = "search"
        title = query
        query_or_urls = query

        print(f"Searching: {query}")
        urls, error = _search_duckduckgo(project, config, query, limit)

        if error:
            print("Search failed.")
            print(error)
            _append_history(project, config, {
                "timestamp": datetime.now().isoformat(timespec="seconds"),
                "mode": mode,
                "title": title,
                "input": query_or_urls,
                "ok": False,
                "saved_path": None,
                "source_count": 0,
                "error": error,
            })
            return 1

        if not urls:
            print("No search results found.")
            return 1

        print("")
        print("Sources found:")
        for idx, url in enumerate(urls, start=1):
            print(f"{idx}. {url}")

    print("")
    print("Reading sources...")

    sources: list[dict[str, Any]] = []
    for url in urls[:limit if mode == "search" else len(urls)]:
        print(f"- {url}")
        sources.append(_read_url(project, config, url))

    ok_count = sum(1 for source in sources if source.get("ok"))

    note_path = _make_note(
        project,
        config,
        title=title,
        mode=mode,
        query_or_urls=query_or_urls,
        sources=sources,
    )

    try:
        saved_rel = note_path.relative_to(project).as_posix()
    except ValueError:
        saved_rel = str(note_path)

    record = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "mode": mode,
        "title": title,
        "input": query_or_urls,
        "ok": ok_count > 0,
        "saved_path": saved_rel,
        "source_count": len(sources),
        "ok_source_count": ok_count,
        "error": "" if ok_count > 0 else "No sources were read successfully.",
    }

    _append_history(project, config, record)

    print("")
    print(f"Research note saved: {saved_rel}")
    print(f"Sources read: {ok_count}/{len(sources)}")

    if ok_count == 0:
        return 1

    return 0
