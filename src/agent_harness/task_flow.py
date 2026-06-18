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

    print("")
    print("Run workspace files through Max from anywhere:")
    print("  max run calc2.py add 5 3")
    print("  max run calc2.py --help")
    print("")

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
