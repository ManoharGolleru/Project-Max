#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v16_index_task_fix.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v16_index_task_fix_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py chat_actions.py edit_flow.py ux.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/index_tools.py <<'EOF'
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
EOF

cat > src/agent_harness/task_flow.py <<'EOF'
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .config import load_config
from .edit_flow import change_project
from .index_tools import relevant_context
from .memory import update_current_state
from .model_progress import chat_with_progress as chat
from .ollama_client import extract_message_text
from .project_context import memory_snapshot, workspace_snapshot
from .schemas import extract_json_object
from .sessions import log_event, log_message
from .skill_manager import build_skill_context
from .util import read_json


def _last_command(project: Path) -> dict[str, Any] | None:
    data = read_json(project / ".agent" / "command_history.json", {"commands": []})
    commands = data.get("commands", [])
    if not commands:
        return None
    return commands[-1]


def plan_project(project: Path, user_request: str, json_only: bool = False) -> dict[str, Any]:
    cfg = load_config()
    workspace = project / "workspace"
    skill_context, selected_skills = build_skill_context("plan", user_request)
    rel_context = relevant_context(project, user_request)

    if selected_skills and not json_only:
        print("")
        print("Using skills: " + ", ".join(selected_skills))

    prompt = f"""
You are Max, a local project agent.

Create a practical short implementation plan for the user's task.

Return JSON only. No markdown.

Schema:
{{
  "goal": "string",
  "steps": ["string"],
  "relevant_files": ["relative/path"],
  "risks": ["string"],
  "first_change_request": "string",
  "test_strategy": "string",
  "done_when": ["string"]
}}

Rules:
- Keep the plan practical and short.
- Do not overbuild.
- Respect the exact user scope.
- first_change_request should be a single small request that can be passed to max change.
- If no file change is needed, first_change_request should be "".
- Prefer testable steps.

PROJECT:
{project}

WORKSPACE:
{workspace}

APPLICABLE WORKFLOW SKILLS:
{skill_context if skill_context else "[no skill loaded]"}

RELEVANT FILE CONTEXT:
{rel_context}

MEMORY SNAPSHOT:
{memory_snapshot(project)}

USER TASK:
{user_request}
"""

    log_message(project, "user", f"plan: {user_request}")
    log_event(project, "plan_started", {"request": user_request, "selected_skills": selected_skills})

    t0 = time.time()

    try:
        resp = chat(
            model=cfg["model"],
            num_ctx=int(cfg["default_context"]),
            temperature=float(cfg["temperature"]),
            task_label="planning the task",
            task_steps=[
                "selecting relevant files",
                "applying workflow skills",
                "building implementation plan",
                "checking plan",
            ],
            messages=[
                {"role": "system", "content": "Return valid JSON only. No markdown."},
                {"role": "user", "content": prompt},
            ],
        )

        duration = round(time.time() - t0, 3)
        text = extract_message_text(resp)
        obj = extract_json_object(text)
        obj["duration_sec"] = duration
        obj["metrics"] = resp.get("_max_metrics", {}) if isinstance(resp, dict) else {}
        obj["selected_skills"] = selected_skills

    except KeyboardInterrupt:
        print("")
        print("Planning cancelled.")
        print("")
        return {"ok": False, "cancelled": True}

    except Exception as e:
        return {"ok": False, "error": str(e)}

    update_current_state(project, f"Max plan:\n\n{json.dumps(obj, indent=2)}")
    log_event(project, "plan_completed", obj)

    if json_only:
        print(json.dumps(obj, indent=2))
        return obj

    print("")
    print("Max plan")
    print("=" * 72)
    print(f"Goal: {obj.get('goal', '')}")

    if selected_skills:
        print("")
        print("Skills loaded:")
        print(", ".join(selected_skills))

    print("")
    print("Steps:")
    for i, step in enumerate(obj.get("steps", []), start=1):
        print(f"{i}. {step}")

    if obj.get("relevant_files"):
        print("")
        print("Relevant files:")
        for f in obj.get("relevant_files", []):
            print(f"- {f}")

    risks = obj.get("risks", [])
    if risks:
        print("")
        print("Risks:")
        for risk in risks:
            print(f"- {risk}")

    if obj.get("first_change_request"):
        print("")
        print("First change Max can try:")
        print(obj["first_change_request"])

    if obj.get("test_strategy"):
        print("")
        print("Test strategy:")
        print(obj["test_strategy"])

    if obj.get("done_when"):
        print("")
        print("Done when:")
        for d in obj.get("done_when", []):
            print(f"- {d}")

    print("")
    return obj


def task_project(project: Path, user_request: str, yes: bool = False, run_test: bool = True) -> dict[str, Any]:
    print("")
    print("Max task mode")
    print("=" * 72)
    print("Max will plan first, then offer the first patch.")
    print("")

    plan = plan_project(project, user_request, json_only=False)

    if not plan or plan.get("ok") is False:
        return {"ok": False, "stage": "plan", "plan": plan}

    first_change = str(plan.get("first_change_request") or "").strip()

    if not first_change:
        print("No file change was recommended by the plan.")
        return {"ok": True, "stage": "plan_only", "plan": plan}

    if not yes:
        ans = input("Generate the first patch from this plan? [y/N]: ").strip().lower()
        if ans not in {"y", "yes"}:
            return {"ok": False, "blocked": True, "reason": "user stopped after plan", "plan": plan}

    result = change_project(project, first_change, yes=False, dry_run=False, run_test=run_test)

    return {
        "ok": bool(result.get("ok")),
        "stage": "change",
        "plan": plan,
        "change_result": result,
    }


def fix_project(project: Path, yes: bool = False) -> dict[str, Any]:
    last = _last_command(project)

    if not last:
        print("No command history found. Run a command first, then use max fix.")
        return {"ok": False, "reason": "no command history"}

    if last.get("ok") is True and last.get("exit_code") == 0:
        print("")
        print("The last command passed, so there is no failure to fix.")
        print("")
        print(f"Last command: {last.get('command')}")
        print(f"stdout: {(last.get('stdout') or '').strip() or '[empty]'}")
        print("")
        return {"ok": True, "nothing_to_fix": True, "last_command": last}

    request = f"""
Fix the project based on this failed command.

Command:
{last.get('command')}

Exit code:
{last.get('exit_code')}

stdout:
{last.get('stdout')}

stderr:
{last.get('stderr')}

Make the smallest safe file change that is likely to fix the failure.
"""

    print("")
    print("Max fix mode")
    print("=" * 72)
    print("Using the last failed command to propose a patch.")
    print("")

    return change_project(project, request, yes=yes, dry_run=False, run_test=True)
EOF

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/edit_flow.py")
text = p.read_text()

if "from .index_tools import build_file_index, relevant_context" not in text:
    text = text.replace(
        "from .git_tools import checkpoint, ensure_git_repo, git_diff, rollback\n",
        "from .git_tools import checkpoint, ensure_git_repo, git_diff, rollback\n"
        "from .index_tools import build_file_index, relevant_context\n",
    )

old = '''    context = workspace_context(workspace)
    skill_context, selected_skills = build_skill_context("change", user_request)
'''
new = '''    try:
        context = relevant_context(project, user_request)
    except Exception:
        context = workspace_context(workspace)

    skill_context, selected_skills = build_skill_context("change", user_request)
'''
if old in text:
    text = text.replace(old, new)

old2 = '''    print("")
    print("Change applied.")
'''
new2 = '''    try:
        build_file_index(project)
    except Exception:
        pass

    print("")
    print("Change applied.")
'''
if old2 in text and "build_file_index(project)" not in text:
    text = text.replace(old2, new2)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

# Add imports.
if "from .index_tools import print_context as direct_print_context, print_index as direct_print_index" not in text:
    text = text.replace(
        "from .util import APP_HOME, ensure_app_home\n",
        "from .util import APP_HOME, ensure_app_home\n"
        "from .index_tools import print_context as direct_print_context, print_index as direct_print_index\n"
        "from .task_flow import fix_project as direct_fix_project, plan_project as direct_plan_project, task_project as direct_task_project\n",
    )

# Add direct workflow functions before main if missing.
helper = r'''

def _direct_project_and_rest(args: list[str]) -> tuple[Path | None, list[str]]:
    project_text, rest = project_from_args(args)
    if project_text is None:
        return None, args
    return Path(project_text), rest


def _direct_plan(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    prompt = " ".join(rest).strip()
    if not prompt:
        ui.fail("Missing task.")
        print('Use: max plan "your task"')
        return 2
    direct_plan_project(project, prompt)
    return 0


def _direct_task(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    prompt = " ".join(rest).strip()
    if not prompt:
        ui.fail("Missing task.")
        print('Use: max task "your task"')
        return 2
    direct_task_project(project, prompt)
    return 0


def _direct_fix(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    direct_fix_project(project)
    return 0


def _direct_index(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    direct_print_index(project)
    return 0


def _direct_context(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    query = " ".join(rest).strip()
    if not query:
        query = "project overview"
    direct_print_context(project, query)
    return 0

'''

if "def _direct_plan(args: list[str]) -> int:" not in text:
    text = text.replace("def main(argv: list[str] | None = None) -> int:", helper + "\ndef main(argv: list[str] | None = None) -> int:")

# Intercept workflow commands in main, early.
needle = '''    if not argv:
        print_home()
        return 0
'''
insert = '''    if argv and argv[0] in {"plan", "outline"}:
        return _direct_plan(argv[1:])

    if argv and argv[0] in {"task", "build", "work"}:
        return _direct_task(argv[1:])

    if argv and argv[0] in {"fix", "repair"}:
        return _direct_fix(argv[1:])

    if argv and argv[0] in {"index"}:
        return _direct_index(argv[1:])

    if argv and argv[0] in {"context"}:
        return _direct_context(argv[1:])

'''
if needle in text and "_direct_task(argv[1:])" not in text:
    text = text.replace(needle, needle + "\n" + insert)

# Add COMMANDS metadata for help/suggestions if missing.
if '"task": {' not in text:
    anchor = '''    "change": {
        "aliases": ["edit", "write", "modify", "patch"],
        "summary": "Ask Max to propose file changes, show a diff, and apply after approval.",
        "usage": "max change <request>",
        "agentctl": ["change"],
        "needs_project": True,
        "remainder": True,
    },
'''
    additions = '''    "plan": {
        "aliases": ["outline"],
        "summary": "Create a skill-guided implementation plan.",
        "usage": "max plan <task>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "task": {
        "aliases": ["build", "work"],
        "summary": "Plan a task, then offer the first patch.",
        "usage": "max task <task>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "fix": {
        "aliases": ["repair"],
        "summary": "Use the last failed command to propose a fix.",
        "usage": "max fix",
        "agentctl": None,
        "needs_project": True,
    },
    "index": {
        "aliases": [],
        "summary": "Build a workspace file index for smarter context.",
        "usage": "max index",
        "agentctl": None,
        "needs_project": True,
    },
    "context": {
        "aliases": [],
        "summary": "Show files/context Max would use for a task.",
        "usage": "max context <task>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
'''
    text = text.replace(anchor, anchor + additions)

# Add to home/help lightly.
if '("max index", "Build file index for smarter context")' not in text:
    text = text.replace(
        '("max change \\"create hello.py\\"", "Propose file changes with diff + approval"),',
        '("max index", "Build file index for smarter context"),\n        ("max context \\"task\\"", "Preview selected task context"),\n        ("max plan \\"task\\"", "Create a skill-guided plan"),\n        ("max task \\"task\\"", "Plan, then offer first patch"),\n        ("max fix", "Fix the last failed command"),\n        ("max change \\"create hello.py\\"", "Propose file changes with diff + approval"),',
    )

text = text.replace(
    '("Daily", ["start", "ask", "think", "files", "tree", "read", "search", "info", "status", "do", "run", "change", "diff", "checkpoint", "look", "open"]),',
    '("Daily", ["start", "ask", "think", "files", "tree", "read", "search", "index", "context", "plan", "task", "fix", "info", "status", "do", "run", "change", "diff", "checkpoint", "look", "open"]),',
)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/chat_actions.py")
text = p.read_text()

if "from .index_tools import print_context as direct_print_context, print_index as direct_print_index" not in text:
    text = text.replace(
        "from .file_tools import print_read, print_search, print_tree\n",
        "from .file_tools import print_read, print_search, print_tree\n"
        "from .index_tools import print_context as direct_print_context, print_index as direct_print_index\n"
        "from .task_flow import fix_project, plan_project, task_project\n",
    )

anchor = '''    if cmd in {"change", "edit", "write", "modify", "patch"}:
        request = " ".join(rest).strip()
'''
handlers = '''    if cmd in {"index"}:
        direct_print_index(project)
        return

    if cmd in {"context"}:
        query = " ".join(rest).strip() or "project overview"
        direct_print_context(project, query)
        return

    if cmd in {"plan", "outline"}:
        prompt = " ".join(rest).strip()
        if not prompt:
            print("Usage: /plan <task>")
            return
        plan_project(project, prompt)
        return

    if cmd in {"task", "build", "work"}:
        prompt = " ".join(rest).strip()
        if not prompt:
            print("Usage: /task <task>")
            return
        task_project(project, prompt)
        return

    if cmd in {"fix", "repair"}:
        fix_project(project)
        return

'''
if handlers.strip() not in text:
    text = text.replace(anchor, handlers + anchor)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/ux.py")
text = p.read_text()

if 'print("/index' not in text:
    text = text.replace(
        'print("/tree                   Show workspace tree")',
        'print("/tree                   Show workspace tree")\n            print("/index                  Build workspace file index")\n            print("/context <task>         Preview selected context for a task")\n            print("/plan <task>            Create a skill-guided plan")\n            print("/task <task>            Plan, then offer first patch")\n            print("/fix                    Fix the last failed command")',
    )

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.16 index + task/fix agent workflows installed."
echo ""
echo "Fast tests:"
echo "  max index"
echo "  max context \"improve calculator add subtract tests\""
echo ""
echo "Model tests:"
echo "  max plan \"add a command line interface to calc2.py\""
echo "  max task \"add a command line interface to calc2.py\""
echo ""
echo "Fix test:"
echo "  max run missing.py"
echo "  max fix"
echo ""
echo "Inside chat:"
echo "  /index"
echo "  /context improve calculator"
echo "  /plan add CLI to calc2.py"
echo "  /task add CLI to calc2.py"
echo "  /fix"
