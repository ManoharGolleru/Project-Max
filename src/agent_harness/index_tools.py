from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from .util import now_ts, write_json


TEXT_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".json", ".md", ".txt", ".html", ".css",
    ".scss", ".yml", ".yaml", ".toml", ".sh", ".csv", ".xml", ".env", ".gitignore",
}


def workspace(project: Path) -> Path:
    return project / "workspace"


def index_path(project: Path) -> Path:
    return project / ".agent" / "file_index.json"


def _skip(rel: Path) -> bool:
    return any(part in {".git", ".agent", "node_modules", "__pycache__", ".venv"} for part in rel.parts)


def _is_text(path: Path) -> bool:
    if path.name == ".gitignore":
        return True
    return path.suffix.lower() in TEXT_EXTS


def _sha1(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", errors="replace")).hexdigest()


def _symbols_for_python(text: str) -> list[str]:
    out: list[str] = []
    for line in text.splitlines():
        m = re.match(r"^\s*(def|class)\s+([A-Za-z_][A-Za-z0-9_]*)", line)
        if m:
            out.append(f"{m.group(1)} {m.group(2)}")
    return out[:30]


def _keywords(text: str, limit: int = 40) -> list[str]:
    words = re.findall(r"[A-Za-z_][A-Za-z0-9_]{2,}", text.lower())
    stop = {
        "the", "and", "for", "with", "this", "that", "from", "return", "print",
        "import", "true", "false", "none", "self", "class", "def", "assert",
    }
    counts: dict[str, int] = {}
    for w in words:
        if w in stop:
            continue
        counts[w] = counts.get(w, 0) + 1
    return [w for w, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:limit]]


def build_file_index(project: Path) -> dict[str, Any]:
    root = workspace(project)
    entries: list[dict[str, Any]] = []

    if root.exists():
        for p in sorted(root.rglob("*")):
            if not p.is_file():
                continue

            rel = p.relative_to(root)

            if _skip(rel):
                continue

            try:
                size = p.stat().st_size
            except Exception:
                size = 0

            entry: dict[str, Any] = {
                "path": str(rel),
                "size": size,
                "ext": p.suffix.lower(),
                "is_text": _is_text(p),
            }

            if _is_text(p) and size <= 500000:
                try:
                    text = p.read_text(errors="replace")
                    entry.update(
                        {
                            "sha1": _sha1(text),
                            "lines": len(text.splitlines()),
                            "symbols": _symbols_for_python(text) if p.suffix.lower() == ".py" else [],
                            "keywords": _keywords(text),
                            "preview": text[:500],
                        }
                    )
                except Exception as e:
                    entry["read_error"] = str(e)

            entries.append(entry)

    report = {
        "created_at": now_ts(),
        "project": str(project),
        "workspace": str(root),
        "file_count": len(entries),
        "entries": entries,
    }

    write_json(index_path(project), report)
    return report


def load_or_build_index(project: Path) -> dict[str, Any]:
    p = index_path(project)
    if p.exists():
        try:
            return json.loads(p.read_text())
        except Exception:
            pass
    return build_file_index(project)


def _query_terms(query: str) -> set[str]:
    return set(re.findall(r"[A-Za-z_][A-Za-z0-9_]{2,}", query.lower()))


def select_relevant_files(project: Path, query: str, limit: int = 8) -> list[dict[str, Any]]:
    idx = load_or_build_index(project)
    terms = _query_terms(query)
    scored: list[tuple[int, dict[str, Any]]] = []

    for entry in idx.get("entries", []):
        path = entry.get("path", "")
        hay = " ".join(
            [
                path.lower(),
                " ".join(entry.get("symbols", [])),
                " ".join(entry.get("keywords", [])),
                entry.get("preview", "").lower(),
            ]
        )

        score = 0
        for term in terms:
            if term in path.lower():
                score += 8
            if term in hay:
                score += 2

        # Prefer source files when score ties.
        if entry.get("ext") in {".py", ".js", ".ts", ".tsx", ".jsx"}:
            score += 1

        if score > 0:
            scored.append((score, entry))

    if not scored:
        # Fallback: small text files first.
        candidates = [
            e for e in idx.get("entries", [])
            if e.get("is_text") and int(e.get("size") or 0) <= 80000
        ]
        return candidates[: min(limit, 5)]

    scored.sort(key=lambda item: (-item[0], item[1].get("path", "")))
    return [entry for _, entry in scored[:limit]]


def relevant_context(project: Path, query: str, max_files: int = 8, max_chars_total: int = 28000) -> str:
    root = workspace(project)
    selected = select_relevant_files(project, query, limit=max_files)

    if not selected:
        return "No relevant files selected."

    parts: list[str] = []
    remaining = max_chars_total

    for entry in selected:
        rel = entry.get("path", "")
        p = root / rel
        if not p.exists() or not p.is_file():
            continue
        if not entry.get("is_text"):
            continue

        try:
            text = p.read_text(errors="replace")
        except Exception as e:
            parts.append(f"\n--- FILE: {rel} ---\n[read failed: {e}]\n")
            continue

        if len(text) > min(9000, remaining):
            text = text[: min(9000, remaining)] + "\n\n[file truncated]\n"

        block = (
            f"\n--- FILE: {rel} ---\n"
            f"size={entry.get('size')} lines={entry.get('lines')} symbols={entry.get('symbols', [])}\n"
            f"{text}\n"
        )

        if len(block) > remaining:
            break

        parts.append(block)
        remaining -= len(block)

        if remaining <= 1000:
            break

    if not parts:
        return "Relevant files were selected, but no readable text content was available."

    return "\n".join(parts)


def print_index(project: Path) -> None:
    report = build_file_index(project)

    print("")
    print("Workspace index")
    print("=" * 72)
    print(f"Project: {project}")
    print(f"Workspace: {report['workspace']}")
    print(f"Files indexed: {report['file_count']}")
    print(f"Index: {index_path(project)}")
    print("")

    for entry in report.get("entries", [])[:80]:
        kind = "text" if entry.get("is_text") else "binary"
        symbols = entry.get("symbols") or []
        symbol_text = f" symbols={symbols[:5]}" if symbols else ""
        print(f"- {entry.get('path')} ({kind}, {entry.get('size')} bytes){symbol_text}")

    print("")


def print_context(project: Path, query: str) -> None:
    selected = select_relevant_files(project, query)

    print("")
    print("Selected context")
    print("=" * 72)
    print(f"Task/query: {query}")
    print("")

    if not selected:
        print("No relevant files selected.")
        print("")
        return

    print("Relevant files:")
    for entry in selected:
        print(f"- {entry.get('path')} ({entry.get('size')} bytes)")

    print("")
    print("Context preview")
    print("=" * 72)
    print(relevant_context(project, query, max_files=5, max_chars_total=12000))
    print("")
