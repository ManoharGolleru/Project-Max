from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .util import APP_HOME, ensure_app_home


SKILLS_ROOT = APP_HOME / "skills"
AGENT_SKILLS_REPO = SKILLS_ROOT / "agent-skills"
AGENT_SKILLS_URL = "https://github.com/addyosmani/agent-skills.git"


def _run(cmd: list[str], cwd: Path | None = None) -> dict[str, Any]:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        capture_output=True,
    )
    return {
        "ok": proc.returncode == 0,
        "exit_code": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "command": " ".join(cmd),
    }


def install_agent_skills(update: bool = True) -> int:
    ensure_app_home()
    SKILLS_ROOT.mkdir(parents=True, exist_ok=True)

    if shutil.which("git") is None:
        print("git is not installed, so Max cannot clone skills.")
        return 2

    if AGENT_SKILLS_REPO.exists():
        if update:
            print(f"Updating skills repo: {AGENT_SKILLS_REPO}")
            result = _run(["git", "pull", "--ff-only"], cwd=AGENT_SKILLS_REPO)
        else:
            result = {"ok": True, "stdout": "Already installed.", "stderr": ""}
    else:
        print(f"Installing skills repo into: {AGENT_SKILLS_REPO}")
        result = _run(["git", "clone", AGENT_SKILLS_URL, str(AGENT_SKILLS_REPO)])

    print(result.get("stdout", "").strip())
    if result.get("stderr"):
        print(result["stderr"].strip())

    if not result["ok"]:
        return 2

    print("")
    print("Skills installed.")
    print("Max will only read SKILL.md files. It will not execute third-party scripts from the repo.")
    print("")
    print("Try:")
    print("  max skills list")
    print("  max skills search test")
    print("  max skills show test-driven-development")

    return 0


def skills_dir() -> Path:
    return AGENT_SKILLS_REPO / "skills"


def skills_installed() -> bool:
    return skills_dir().exists()


def _parse_frontmatter(text: str) -> dict[str, str]:
    if not text.startswith("---"):
        return {}

    m = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, flags=re.S)
    if not m:
        return {}

    out: dict[str, str] = {}

    for line in m.group(1).splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")

    return out


def list_skills() -> list[dict[str, str]]:
    if not skills_installed():
        return []

    out: list[dict[str, str]] = []

    for skill_md in sorted(skills_dir().glob("*/SKILL.md")):
        name = skill_md.parent.name

        try:
            text = skill_md.read_text(errors="replace")
        except Exception:
            continue

        meta = _parse_frontmatter(text)
        desc = meta.get("description", "")

        out.append(
            {
                "name": meta.get("name", name),
                "folder": name,
                "description": desc,
                "path": str(skill_md),
            }
        )

    return out


def print_skills() -> int:
    items = list_skills()

    print("")
    print("Max skills")
    print("=" * 72)

    if not items:
        print("No skills installed yet.")
        print("")
        print("Install them with:")
        print("  max skills install")
        print("")
        return 0

    for item in items:
        name = item["folder"]
        desc = item.get("description") or ""
        print(f"{name:34} {desc[:90]}")

    print("")
    print("Useful commands:")
    print("  max skills search testing")
    print("  max skills show test-driven-development")
    print("")

    return 0


def search_skills(query: str) -> list[dict[str, str]]:
    q = query.lower().strip()
    if not q:
        return list_skills()

    out = []
    for item in list_skills():
        hay = f"{item.get('folder','')} {item.get('name','')} {item.get('description','')}".lower()
        if q in hay:
            out.append(item)

    return out


def print_skill_search(query: str) -> int:
    results = search_skills(query)

    print("")
    print(f"Skill search: {query}")
    print("=" * 72)

    if not results:
        print("No matching skills found.")
        return 0

    for item in results:
        print(f"{item['folder']:34} {item.get('description','')[:90]}")

    print("")
    return 0


def read_skill(skill_name: str, max_chars: int = 8000) -> tuple[str | None, str | None]:
    if not skills_installed():
        return None, "Skills are not installed. Run: max skills install"

    wanted = skill_name.strip()

    candidates = [
        skills_dir() / wanted / "SKILL.md",
    ]

    for item in list_skills():
        if item["folder"] == wanted or item["name"] == wanted:
            candidates.append(Path(item["path"]))

    for p in candidates:
        if p.exists():
            text = p.read_text(errors="replace")
            if len(text) > max_chars:
                text = text[:max_chars] + f"\n\n[truncated after {max_chars} characters]"
            return text, None

    return None, f"Skill not found: {skill_name}"


def print_skill(skill_name: str) -> int:
    text, err = read_skill(skill_name, max_chars=20000)

    print("")
    print(f"Skill: {skill_name}")
    print("=" * 72)

    if err:
        print(err)
        return 2

    print(text)
    print("")
    return 0


def _available_names() -> set[str]:
    return {item["folder"] for item in list_skills()}


def _choose_existing(names: list[str]) -> list[str]:
    available = _available_names()
    out = []
    for name in names:
        if name in available and name not in out:
            out.append(name)
    return out


def select_skill_names(task_kind: str, prompt: str, limit: int = 3) -> list[str]:
    if not skills_installed():
        return []

    low = f"{task_kind} {prompt}".lower()
    selected: list[str] = []

    def add(*names: str) -> None:
        for n in names:
            if n not in selected:
                selected.append(n)

    # Meta-skill only when we are unsure or doing broad routing.
    if any(w in low for w in ["which skill", "what skill", "workflow", "process"]):
        add("using-agent-skills")

    if any(w in low for w in ["spec", "requirements", "prd", "define"]):
        add("spec-driven-development", "planning-and-task-breakdown")

    if any(w in low for w in ["plan", "breakdown", "tasks", "roadmap"]):
        add("planning-and-task-breakdown")

    if any(w in low for w in ["create", "build", "implement", "feature", "change", "edit", "modify", "script", "app"]):
        add("incremental-implementation", "test-driven-development")

    if any(w in low for w in ["test", "verify", "unit test", "pytest", "coverage"]):
        add("test-driven-development")

    if any(w in low for w in ["bug", "fix", "error", "failed", "traceback", "exception", "crash", "debug"]):
        add("debugging-and-error-recovery", "test-driven-development")

    if any(w in low for w in ["review", "quality", "clean", "maintainability"]):
        add("code-review-and-quality")

    if any(w in low for w in ["simplify", "refactor", "cleanup", "too complex"]):
        add("code-simplification", "code-review-and-quality")

    if any(w in low for w in ["ui", "frontend", "react", "css", "html", "accessibility", "component"]):
        add("frontend-ui-engineering")

    if any(w in low for w in ["api", "interface", "endpoint", "contract"]):
        add("api-and-interface-design")

    if any(w in low for w in ["security", "auth", "permission", "secret", "injection"]):
        add("security-and-hardening")

    if any(w in low for w in ["performance", "slow", "latency", "optimize"]):
        add("performance-optimization")

    if any(w in low for w in ["documentation", "docs", "readme", "adr"]):
        add("documentation-and-adrs")

    if any(w in low for w in ["git", "commit", "branch", "version", "checkpoint"]):
        add("git-workflow-and-versioning")

    existing = _choose_existing(selected)
    return existing[:limit]


def build_skill_context(task_kind: str, prompt: str, max_chars_total: int = 14000) -> tuple[str, list[str]]:
    names = select_skill_names(task_kind, prompt)

    if not names:
        return "", []

    parts: list[str] = []
    used: list[str] = []
    remaining = max_chars_total

    for name in names:
        text, err = read_skill(name, max_chars=min(6000, remaining))

        if err or not text:
            continue

        block = f"\n\n--- SKILL: {name} ---\n{text}\n"

        if len(block) > remaining:
            block = block[:remaining] + "\n\n[skill context truncated]\n"

        parts.append(block)
        used.append(name)
        remaining -= len(block)

        if remaining <= 1000:
            break

    if not parts:
        return "", []

    header = (
        "The following selected skills are workflow rules. Follow their process, "
        "verification gates, and exit criteria when relevant. Do not mention skills unless useful to the user.\n"
    )

    return header + "\n".join(parts), used


def skills_command(args: list[str]) -> int:
    sub = args[0] if args else "list"

    if sub in {"install", "add"}:
        return install_agent_skills(update=True)

    if sub in {"update", "pull"}:
        return install_agent_skills(update=True)

    if sub in {"list", "ls"}:
        return print_skills()

    if sub in {"search", "find"}:
        query = " ".join(args[1:]).strip()
        if not query:
            print("Usage: max skills search <query>")
            return 2
        return print_skill_search(query)

    if sub in {"show", "read", "cat"}:
        if len(args) < 2:
            print("Usage: max skills show <skill-name>")
            return 2
        return print_skill(args[1])

    print(f"Unknown skills command: {sub}")
    print("")
    print("Use:")
    print("  max skills install")
    print("  max skills list")
    print("  max skills search <query>")
    print("  max skills show <skill-name>")

    return 2
