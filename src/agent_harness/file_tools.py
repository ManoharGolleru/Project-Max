from __future__ import annotations

from pathlib import Path


TEXT_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".json", ".md", ".txt", ".html", ".css",
    ".scss", ".yml", ".yaml", ".toml", ".sh", ".csv", ".xml", ".env", ".gitignore",
}


def workspace(project: Path) -> Path:
    return project / "workspace"


def _safe_rel(path_text: str) -> tuple[bool, str]:
    if not path_text or not path_text.strip():
        return False, "empty path"

    p = Path(path_text)

    if p.is_absolute():
        return False, f"absolute paths are blocked: {path_text}"

    if ".." in p.parts:
        return False, f"path traversal is blocked: {path_text}"

    if str(path_text).startswith("~"):
        return False, f"home-relative paths are blocked: {path_text}"

    if any(part in {".git", ".agent", "node_modules", "__pycache__", ".venv"} for part in p.parts):
        return False, f"protected folder is blocked: {path_text}"

    return True, "ok"


def _is_text(path: Path) -> bool:
    if path.name == ".gitignore":
        return True
    return path.suffix.lower() in TEXT_EXTS


def _skip(rel: Path) -> bool:
    return any(part in {".git", ".agent", "node_modules", "__pycache__", ".venv"} for part in rel.parts)


def tree_text(project: Path, max_depth: int = 4, max_items: int = 250) -> str:
    root = workspace(project)

    if not root.exists():
        return f"Workspace does not exist:\n{root}"

    rows: list[str] = []
    count = 0

    rows.append(f"{root}/")

    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root)

        if _skip(rel):
            continue

        depth = len(rel.parts)

        if depth > max_depth:
            continue

        indent = "  " * depth
        suffix = "/" if p.is_dir() else ""

        rows.append(f"{indent}{p.name}{suffix}")
        count += 1

        if count >= max_items:
            rows.append(f"... stopped after {max_items} item(s)")
            break

    if len(rows) == 1:
        return f"The workspace is empty.\n\nWorkspace:\n{root}"

    return "\n".join(rows)


def read_text_file(project: Path, path_text: str, max_chars: int = 20000) -> str:
    ok, why = _safe_rel(path_text)

    if not ok:
        return f"Blocked: {why}"

    root = workspace(project)
    target = (root / path_text).resolve()

    try:
        target.relative_to(root.resolve())
    except Exception:
        return f"Blocked: path escapes workspace: {path_text}"

    if not target.exists():
        return f"File not found: {path_text}"

    if target.is_dir():
        return f"That path is a folder, not a file: {path_text}"

    if not _is_text(target):
        return f"Unsupported or likely binary file type: {path_text}"

    text = target.read_text(errors="replace")

    truncated = ""
    if len(text) > max_chars:
        text = text[:max_chars]
        truncated = f"\n\n[truncated after {max_chars} characters]"

    return f"--- {path_text} ---\n{text}{truncated}"


def search_text(project: Path, term: str, max_matches: int = 80) -> str:
    term = term.strip()

    if not term:
        return "Search term is empty."

    root = workspace(project)

    if not root.exists():
        return f"Workspace does not exist:\n{root}"

    matches: list[str] = []
    low_term = term.lower()

    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue

        rel = p.relative_to(root)

        if _skip(rel):
            continue

        if not _is_text(p):
            continue

        try:
            lines = p.read_text(errors="replace").splitlines()
        except Exception:
            continue

        for i, line in enumerate(lines, start=1):
            if low_term in line.lower():
                matches.append(f"{rel}:{i}: {line}")

                if len(matches) >= max_matches:
                    return "Matches:\n" + "\n".join(matches) + f"\n\n[stopped after {max_matches} match(es)]"

    if not matches:
        return f"No matches found for: {term}"

    return "Matches:\n" + "\n".join(matches)


def print_tree(project: Path, max_depth: int = 4) -> None:
    print("")
    print("Workspace tree")
    print("=" * 72)
    print(tree_text(project, max_depth=max_depth))
    print("")


def print_read(project: Path, path_text: str) -> None:
    print("")
    print("File")
    print("=" * 72)
    print(read_text_file(project, path_text))
    print("")


def print_search(project: Path, term: str) -> None:
    print("")
    print("Search")
    print("=" * 72)
    print(search_text(project, term))
    print("")
