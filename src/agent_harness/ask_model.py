from __future__ import annotations

import json
import time
from pathlib import Path

from .command_runner import run_command
from .config import load_config
from .memory import append_command_history, update_current_state
from .model_progress import chat_with_progress as chat
from .ollama_client import extract_message_text
from .project_context import memory_snapshot, workspace_snapshot
from .schemas import extract_json_object
from .sessions import log_event, log_message
from .skill_manager import build_skill_context


def ask_project(
    project: Path,
    user_prompt: str,
    interactive: bool = True,
    no_run: bool = False,
) -> dict:
    cfg = load_config()
    workspace = project / "workspace"

    log_message(project, "user", user_prompt)
    log_event(project, "ask_started", {"prompt": user_prompt, "source": "model"})

    skill_context, selected_skills = build_skill_context("ask", user_prompt)

    if selected_skills and interactive:
        print("")
        print("Using skills: " + ", ".join(selected_skills))
        print("")

    context = f"""
PROJECT:
{project}

WORKSPACE:
{workspace}

WORKSPACE FILES:
{workspace_snapshot(project)}

MEMORY:
{memory_snapshot(project)}
"""

    prompt = f"""
You are Max, a local terminal-first agent assistant.

The controller owns tools, permissions, memory, and command execution.
You do not directly run commands.

Answer the user's question using the project context.

Return JSON only. No markdown.

Schema:
{{
  "reply": "string",
  "need_command": boolean,
  "suggested_command": "string",
  "reason": "string",
  "memory_note": "string"
}}

Rules:
- Use clear layman wording.
- If a command is useful, suggest exactly one safe read-only command.
- suggested_command must use relative paths only.
- Prefer commands like: ls -lh ., find . -maxdepth 2 -type f | sort | head -50, cat filename.
- Do not suggest sudo.
- Do not suggest installing packages.
- Do not suggest deleting files.
- If no command is needed, set need_command=false and suggested_command="".
- Do not claim you inspected files unless the context actually shows them.

APPLICABLE WORKFLOW SKILLS:
{skill_context if skill_context else "[no skill loaded]"}

PROJECT CONTEXT:
{context}

USER QUESTION:
{user_prompt}
"""

    model_start = time.time()

    if interactive:
        print("")
        print(f"Max is thinking with the model: {cfg['model']}")
        print("This may take a while on CPU.")
        print("")

    try:
        resp = chat(
            model=cfg["model"],
            num_ctx=int(cfg["default_context"]),
            temperature=float(cfg["temperature"]),
            messages=[
                {"role": "system", "content": "Return valid JSON only. No markdown."},
                {"role": "user", "content": prompt},
            ],
        )

        duration = round(time.time() - model_start, 3)
        text = extract_message_text(resp)
        log_event(project, "model_response_raw", {"duration_sec": duration, "text_preview": text[:2000]})

        obj = extract_json_object(text)

    except KeyboardInterrupt:
        duration = round(time.time() - model_start, 3)
        if interactive:
            print("")
            print("Model call cancelled.")
            print("")
        log_event(project, "ask_cancelled", {"duration_sec": duration})
        return {
            "reply": "Model call cancelled.",
            "source": "model",
            "duration_sec": duration,
            "need_command": False,
            "suggested_command": "",
            "reason": "",
            "memory_note": "",
            "command_result": None,
        }

    except Exception as e:
        duration = round(time.time() - model_start, 3)
        obj = {
            "reply": f"I could not complete that request because the model response failed: {e}",
            "need_command": False,
            "suggested_command": "",
            "reason": "",
            "memory_note": f"Ask failed: {e}",
        }
        log_event(project, "ask_failed", {"duration_sec": duration, "error": str(e)})

    reply = str(obj.get("reply", "")).strip()
    need_command = bool(obj.get("need_command", False))
    suggested_command = str(obj.get("suggested_command", "") or "").strip()
    reason = str(obj.get("reason", "") or "Max suggested this command.").strip()
    memory_note = str(obj.get("memory_note", "") or "").strip()

    if interactive:
        print("")
        print(f"Max [model, {duration:.2f}s]")
        print("=" * 72)
        print(reply)
        print("")

    log_message(project, "assistant", reply)

    if memory_note:
        update_current_state(project, f"Max note:\n\n{memory_note}")
        log_event(project, "memory_note", {"note": memory_note})

    command_result = None

    if need_command and suggested_command:
        if no_run:
            if interactive:
                print("Suggested command, not run because --no-run was used:")
                print(f"  {suggested_command}")
            log_event(project, "command_suggested_not_run", {"command": suggested_command, "reason": reason})
        else:
            if interactive:
                print("Max suggests running:")
                print(f"  {suggested_command}")
                print("")

            command_result = run_command(
                command=suggested_command,
                cwd=workspace,
                workspace_root=workspace,
                reason=reason,
                ask=True,
            )

            append_command_history(project, command_result)
            update_current_state(project, f"Max command result:\n\n{json.dumps(command_result, indent=2)}")
            log_event(project, "command_result", command_result)

            if interactive:
                print("")
                print("Command result")
                print("=" * 72)
                print(json.dumps(command_result, indent=2))
                print("")

    result = {
        "reply": reply,
        "source": "model",
        "duration_sec": duration,
        "need_command": need_command,
        "suggested_command": suggested_command,
        "reason": reason,
        "memory_note": memory_note,
        "command_result": command_result,
    }

    log_event(project, "ask_completed", result)

    return result
