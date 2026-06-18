from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any

from .util import APP_HOME, ensure_app_home


REGISTRY_FILE = APP_HOME / "projects.json"
CURRENT_PROJECT_FILE = APP_HOME / "current_project"


def is_project(path: Path) -> bool:
    return (path / ".agent").exists() and (path / "workspace").exists()


def _load_registry() -> dict[str, Any]:
    ensure_app_home()

    if not REGISTRY_FILE.exists():
        return {"projects": []}

    try:
        data = json.loads(REGISTRY_FILE.read_text())
    except Exception:
        return {"projects": []}

    if not isinstance(data, dict):
        return {"projects": []}

    if "projects" not in data or not isinstance(data["projects"], list):
        data["projects"] = []

    return data


def _save_registry(data: dict[str, Any]) -> None:
    ensure_app_home()
    REGISTRY_FILE.write_text(json.dumps(data, indent=2))


def _norm(path: Path) -> str:
    return str(path.expanduser().resolve())


def current_project() -> Path | None:
    if not CURRENT_PROJECT_FILE.exists():
        return None

    raw = CURRENT_PROJECT_FILE.read_text().strip()

    if not raw:
        return None

    p = Path(raw).expanduser().resolve()

    if is_project(p):
        return p

    return None


def set_current_project(path: Path) -> None:
    ensure_app_home()
    CURRENT_PROJECT_FILE.write_text(_norm(path))


def register_project(path: Path) -> bool:
    path = path.expanduser().resolve()

    if not is_project(path):
        return False

    data = _load_registry()
    paths = [_norm(Path(p)) for p in data.get("projects", []) if str(p).strip()]

    p_text = _norm(path)

    if p_text not in paths:
        paths.append(p_text)

    data["projects"] = sorted(paths)
    _save_registry(data)

    return True


def unregister_project(path: Path) -> None:
    path = path.expanduser().resolve()
    p_text = _norm(path)

    data = _load_registry()
    data["projects"] = [
        _norm(Path(p))
        for p in data.get("projects", [])
        if _norm(Path(p)) != p_text
    ]

    _save_registry(data)

    cur = current_project()
    if cur and _norm(cur) == p_text:
        CURRENT_PROJECT_FILE.unlink(missing_ok=True)


def _registered_projects() -> list[Path]:
    data = _load_registry()
    out: list[Path] = []

    for raw in data.get("projects", []):
        try:
            p = Path(raw).expanduser().resolve()
        except Exception:
            continue

        if p not in out:
            out.append(p)

    return out


def _scan_roots() -> list[Path]:
    roots: list[Path] = []

    for p in [
        Path.cwd(),
        Path.cwd().parent,
        Path.home() / "agent-harness",
    ]:
        try:
            p = p.expanduser().resolve()
        except Exception:
            continue

        if p.exists() and p not in roots:
            roots.append(p)

    return roots


def discover_projects() -> list[Path]:
    found: list[Path] = []

    def add(p: Path) -> None:
        try:
            p = p.expanduser().resolve()
        except Exception:
            return

        if p not in found:
            found.append(p)

    for p in _registered_projects():
        add(p)

    cur = current_project()
    if cur:
        add(cur)

    for root in _scan_roots():
        if is_project(root):
            add(root)

        try:
            children = list(root.iterdir())
        except Exception:
            continue

        for child in children:
            if child.is_dir() and is_project(child):
                add(child)

    return sorted(found, key=lambda x: (x.name.lower(), str(x)))


def resolve_project_ref(ref: str | None) -> tuple[Path | None, str | None]:
    if not ref or ref.strip() in {"", "."}:
        cur = current_project()
        if cur:
            return cur, None

        cwd = Path.cwd().resolve()
        if is_project(cwd):
            return cwd, None

        return None, "No current project is selected."

    raw = ref.strip()
    p = Path(raw).expanduser()

    if p.exists():
        p = p.resolve()
        if is_project(p):
            return p, None
        return None, f"Path exists, but it is not a Max project: {p}"

    projects = discover_projects()

    matches = []
    for item in projects:
        if item.name == raw or str(item) == raw:
            matches.append(item)

    if len(matches) == 1:
        return matches[0], None

    if len(matches) > 1:
        lines = "\n".join(f"  - {m}" for m in matches)
        return None, f"Multiple projects matched '{raw}':\n{lines}"

    return None, f"Project not found: {raw}"


def print_projects() -> int:
    projects = discover_projects()
    cur = current_project()
    registered = {_norm(p) for p in _registered_projects()}

    print("")
    print("Max projects")
    print("=" * 72)

    if not projects:
        print("No Max projects found yet.")
        print("")
        print("Create one:")
        print("  max new my-project")
        print("")
        return 0

    for p in projects:
        marker = "*" if cur and _norm(cur) == _norm(p) else " "
        reg = "registered" if _norm(p) in registered else "discovered"
        status = "ok" if is_project(p) else "missing"
        print(f"{marker} {p.name:24} {status:8} {reg:11} {p}")

    print("")
    print("* = current project")
    print("")
    print("Useful commands:")
    print("  max use <project-name-or-path>")
    print("  max new <project-name>")
    print("  max delete <project-name-or-path>")
    print("  max forget <project-name-or-path>")
    print("")

    return 0


def forget_project(ref: str) -> int:
    p, err = resolve_project_ref(ref)

    if err:
        print(err)
        return 2

    assert p is not None
    unregister_project(p)

    print(f"Forgot project registration: {p}")
    print("The files were not deleted.")

    return 0


def _safe_delete_target(path: Path) -> tuple[bool, str]:
    path = path.expanduser().resolve()

    if not is_project(path):
        return False, f"Not a Max project: {path}"

    if path == Path.home().resolve():
        return False, "Refusing to delete your home directory."

    if path == Path("/"):
        return False, "Refusing to delete root."

    if len(path.parts) < 4:
        return False, f"Refusing to delete a high-level folder: {path}"

    return True, "ok"


def delete_project(ref: str, yes: bool = False) -> int:
    p, err = resolve_project_ref(ref)

    if err:
        print(err)
        return 2

    assert p is not None
    ok, why = _safe_delete_target(p)

    if not ok:
        print(f"Delete blocked: {why}")
        return 2

    print("")
    print("Delete Max project")
    print("=" * 72)
    print(f"Project: {p}")
    print("")
    print("This will delete the whole project folder, including:")
    print("  - workspace/")
    print("  - .agent/")
    print("  - .vscode/")
    print("")

    if not yes:
        ans = input("Type DELETE to confirm: ").strip()
        if ans != "DELETE":
            print("Delete cancelled.")
            return 1

    shutil.rmtree(p)
    unregister_project(p)

    print(f"Deleted project: {p}")

    return 0


def rename_project(ref: str, new_name: str) -> int:
    p, err = resolve_project_ref(ref)

    if err:
        print(err)
        return 2

    assert p is not None

    if not new_name or "/" in new_name or "\\" in new_name:
        print("New name must be a simple folder name.")
        return 2

    target = p.parent / new_name

    if target.exists():
        print(f"Target already exists: {target}")
        return 2

    p.rename(target)

    unregister_project(p)
    register_project(target)

    cur = current_project()
    if cur is None or _norm(cur) == _norm(p):
        set_current_project(target)

    print(f"Renamed project:")
    print(f"  old: {p}")
    print(f"  new: {target}")

    return 0
