from __future__ import annotations

import difflib
import json
import time
from pathlib import Path
from typing import Any

from .command_runner import run_command
from .config import load_config
from .git_tools import checkpoint, ensure_git_repo, git_diff, rollback
from .index_tools import build_file_index, relevant_context
from .memory import append_command_history, update_current_state
from .model_progress import chat_with_progress as chat
from .ollama_client import extract_message_text
from .schemas import extract_json_object
from .sessions import log_event, log_message
from .skill_manager import build_skill_context
from .util import APP_HOME, now_ts, write_json


TEXT_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".json", ".md", ".txt", ".html", ".css",
    ".scss", ".yml", ".yaml", ".toml", ".sh", ".csv", ".xml", ".env", ".gitignore",
}


def safe_rel_path(path_text: str) -> tuple[bool, str]:
    if not path_text or not path_text.strip():
        return False, "empty path"

    p = Path(path_text)

    if p.is_absolute():
        return False, f"absolute paths are blocked: {path_text}"

    parts = p.parts
    if ".." in parts:
        return False, f"path traversal is blocked: {path_text}"

    if str(path_text).startswith("~"):
        return False, f"home-relative paths are blocked: {path_text}"

    if any(part in {".git", ".agent", "node_modules", "__pycache__", ".venv"} for part in parts):
        return False, f"protected folder is blocked: {path_text}"

    return True, "ok"


def is_text_file(path: Path) -> bool:
    if path.name in {".gitignore"}:
        return True
    return path.suffix.lower() in TEXT_EXTS


def workspace_context(workspace: Path, max_files: int = 18, max_total_chars: int = 26000) -> str:
    if not workspace.exists():
        return "Workspace missing."

    chunks: list[str] = []
    total = 0
    count = 0

    files = []
    for p in sorted(workspace.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(workspace)
        if any(part in {".git", "node_modules", "__pycache__", ".venv"} for part in rel.parts):
            continue
        if not is_text_file(p):
            continue
        files.append(p)

    if not files:
        return "Workspace has no readable text files yet."

    for p in files:
        if count >= max_files or total >= max_total_chars:
            break

        rel = p.relative_to(workspace)
        try:
            text = p.read_text(errors="replace")
        except Exception:
            continue

        text = text[:6000]
        chunk = f"\n--- FILE: {rel} ---\n{text}\n"
        chunks.append(chunk)
        total += len(chunk)
        count += 1

    return "".join(chunks) if chunks else "No readable text file content collected."


def parse_change_response(text: str) -> dict[str, Any]:
    obj = extract_json_object(text)

    if "summary" not in obj or not isinstance(obj["summary"], str):
        raise ValueError("Missing string field: summary")

    if "files" not in obj or not isinstance(obj["files"], list):
        raise ValueError("Missing list field: files")

    for i, item in enumerate(obj["files"]):
        if not isinstance(item, dict):
            raise ValueError(f"files[{i}] must be an object")
        if "path" not in item or not isinstance(item["path"], str):
            raise ValueError(f"files[{i}] missing string field: path")
        if "content" not in item or not isinstance(item["content"], str):
            raise ValueError(f"files[{i}] missing string field: content")

    obj.setdefault("test_command", "")
    obj.setdefault("notes", "")
    obj.setdefault("skill_usage", "")
    obj.setdefault("selected_skills", [])

    return obj


def build_diff(workspace: Path, files: list[dict[str, Any]]) -> str:
    out: list[str] = []

    for item in files:
        rel = item["path"]
        new_text = item["content"]

        old_path = workspace / rel
        old_text = ""

        if old_path.exists():
            old_text = old_path.read_text(errors="replace")

        diff = difflib.unified_diff(
            old_text.splitlines(keepends=True),
            new_text.splitlines(keepends=True),
            fromfile=f"a/{rel}",
            tofile=f"b/{rel}",
        )

        out.append("".join(diff) or f"No textual diff for {rel}\n")

    return "\n".join(out)


def request_change(project: Path, user_request: str) -> dict[str, Any]:
    cfg = load_config()
    workspace = project / "workspace"

    try:
        context = relevant_context(project, user_request)
    except Exception:
        context = workspace_context(workspace)

    skill_context, selected_skills = build_skill_context("change", user_request)

    if selected_skills:
        print("Using skills: " + ", ".join(selected_skills))
        print("")

    prompt = f"""
You are Max, a local coding agent running on the user's Linux laptop.

The controller will validate paths, show a diff, ask approval, and apply files.
You do not run commands directly.

User request:
{user_request}

Applicable workflow skills:
{skill_context if skill_context else "[no skill loaded]"}

Workspace context:
{context}

Return JSON only. No markdown.

Required schema:
{{
  "summary": "short explanation of the change",
  "files": [
    {{
      "path": "relative/path/inside/workspace",
      "content": "complete full file content",
      "reason": "why this file is created or changed"
    }}
  ],
  "test_command": "optional safe relative command, or empty string",
  "notes": "anything the user should know"
}}

Rules:
- Follow the user's requested scope exactly.
- Do not add extra features, functions, files, dependencies, or behavior unless the user explicitly asked for them.
- If you think an extra feature would be useful, mention it in notes instead of implementing it.
- For example, if the user asks for add and subtract, do not implement multiply or divide.
- Use only relative paths inside the workspace.
- Do not use absolute paths.
- Do not use ../
- Do not modify .agent, .git, node_modules, .venv, or system files.
- For each changed file, provide the complete final file content.
- Keep the first patch small and easy to review.
- If creating a Python file, a safe test command can be: python3 filename.py
- If creating or modifying a Python file, include a safe test_command whenever possible.
- If the user requests a CLI, include a test_command that exercises the CLI, not only --help.
- If no test command is needed, set test_command to "".
"""

    log_message(project, "user", f"change: {user_request}")
    log_event(project, "change_started", {"request": user_request, "selected_skills": selected_skills})

    t0 = time.time()

    resp = chat(
        model=cfg["model"],
        num_ctx=int(cfg["default_context"]),
        temperature=float(cfg["temperature"]),
        messages=[
            {"role": "system", "content": "Return valid JSON only. No markdown."},
            {"role": "user", "content": prompt},
        ],
    )

    duration = round(time.time() - t0, 3)
    text = extract_message_text(resp)
    log_event(project, "change_model_raw", {"duration_sec": duration, "text_preview": text[:2000]})

    obj = parse_change_response(text)
    obj["model_duration_sec"] = duration
    obj["model_metrics"] = resp.get("_max_metrics", {}) if isinstance(resp, dict) else {}
    obj["selected_skills"] = selected_skills
    obj["skill_context_chars"] = len(skill_context or "")

    return obj


def validate_change(workspace: Path, change: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    files = change.get("files", [])

    if not files:
        errors.append("No files were proposed.")

    for item in files:
        rel = item.get("path", "")
        ok, why = safe_rel_path(rel)
        if not ok:
            errors.append(why)
            continue

        target = (workspace / rel).resolve()
        try:
            target.relative_to(workspace.resolve())
        except Exception:
            errors.append(f"path escapes workspace: {rel}")

        content = item.get("content", "")
        if len(content) > 250000:
            errors.append(f"file too large: {rel}")

    test_command = str(change.get("test_command") or "").strip()
    if test_command:
        blocked_words = ["sudo", "rm -rf", "apt ", "pip install", "npm install", "curl ", "wget "]
        low = test_command.lower()
        for w in blocked_words:
            if w in low:
                errors.append(f"test_command contains blocked pattern: {w}")

    return errors


def apply_change(project: Path, change: dict[str, Any], yes: bool = False, dry_run: bool = False, run_test: bool = False) -> dict[str, Any]:
    workspace = project / "workspace"
    ensure_git_repo(workspace)

    errors = validate_change(workspace, change)
    diff_text = build_diff(workspace, change["files"])

    print("")
    print("Max change proposal")
    print("=" * 72)
    print(change["summary"])
    selected_skills = change.get("selected_skills") or []
    if selected_skills:
        print("")
        print("Skills loaded:")
        print(", ".join(selected_skills))
    if change.get("skill_usage"):
        print("")
        print("Skill usage:")
        print(change["skill_usage"])

    print("")
    print("Files:")
    for item in change["files"]:
        print(f"- {item['path']}: {item.get('reason', '')}")
    if change.get("notes"):
        print("")
        print("Notes:")
        print(change["notes"])
    if change.get("test_command"):
        print("")
        print(f"Suggested test command: {change['test_command']}")
    print("")
    print("Diff preview")
    print("=" * 72)
    print(diff_text if diff_text.strip() else "[empty diff]")
    print("")

    if errors:
        print("Blocked change because validation failed:")
        for e in errors:
            print(f"- {e}")
        return {"ok": False, "blocked": True, "errors": errors, "diff": diff_text}

    if dry_run:
        print("Dry run only. No files changed.")
        return {"ok": True, "dry_run": True, "applied": False, "diff": diff_text}

    if not yes:
        ans = input("Apply this change? [y/N]: ").strip().lower()
        if ans not in {"y", "yes"}:
            return {"ok": False, "blocked": True, "reason": "user denied approval", "diff": diff_text}

    before_checkpoint = checkpoint(workspace, "checkpoint before Max change")

    written = []
    for item in change["files"]:
        rel = item["path"]
        target = workspace / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(item["content"])
        written.append(rel)

    result: dict[str, Any] = {
        "ok": True,
        "applied": True,
        "written": written,
        "before_checkpoint": before_checkpoint,
        "diff": diff_text,
        "test_result": None,
    }

    update_current_state(project, f"Max applied change:\n\n{json.dumps({'summary': change['summary'], 'files': written}, indent=2)}")
    log_event(project, "change_applied", result)
    log_message(project, "assistant", f"Applied change: {change['summary']}")

    test_command = str(change.get("test_command") or "").strip()

    if run_test and not test_command:
        py_files = [
            item.get("path", "")
            for item in change.get("files", [])
            if str(item.get("path", "")).endswith(".py")
        ]
        if py_files:
            test_command = "python3 " + py_files[0]
            change["test_command"] = test_command
            print("")
            print(f"No model test command was provided, so Max inferred: {test_command}")

    if run_test and test_command:
        test_result = run_command(
            command=test_command,
            cwd=workspace,
            workspace_root=workspace,
            reason="Run suggested test command after applying Max change.",
            ask=not yes,
        )
        append_command_history(project, test_result)
        update_current_state(project, f"Max post-change test result:\n\n{json.dumps(test_result, indent=2)}")
        result["test_result"] = test_result

    report_path = APP_HOME / "last_change_report.json"
    write_json(
        report_path,
        {
            "created_at": now_ts(),
            "project": str(project),
            "change": change,
            "result": result,
        },
    )

    try:
        build_file_index(project)
    except Exception:
        pass

    print("")
    print("Change applied.")
    print(f"Report saved to: {report_path}")
    print("")
    print("Next useful commands:")
    print("  max diff                         or /diff inside chat")
    print("  max checkpoint -m \"message\"     or /checkpoint message")
    print("  max rollback                     or /rollback inside chat")
    print("")

    return result


def change_project(project: Path, user_request: str, yes: bool = False, dry_run: bool = False, run_test: bool = False) -> dict[str, Any]:
    print("")
    print("Max is preparing a change proposal.")
    print("")

    try:
        change = request_change(project, user_request)
    except KeyboardInterrupt:
        print("")
        print("Change generation cancelled.")
        print("")
        return {"ok": False, "cancelled": True}
    except Exception as e:
        print(f"Change generation failed: {e}")
        return {"ok": False, "error": str(e)}

    return apply_change(project, change, yes=yes, dry_run=dry_run, run_test=run_test)


def diff_project(project: Path) -> dict[str, Any]:
    workspace = project / "workspace"
    result = git_diff(workspace)

    print("")
    print("Workspace Git status")
    print("=" * 72)
    print(result.get("status") or "[clean]")
    print("")
    print("Workspace diff")
    print("=" * 72)
    print(result.get("diff") or "[no tracked-file diff]")
    print("")

    return result


def checkpoint_project(project: Path, message: str) -> dict[str, Any]:
    workspace = project / "workspace"
    result = checkpoint(workspace, message)

    print("")
    print("Checkpoint")
    print("=" * 72)
    print(json.dumps(result, indent=2))
    print("")

    return result


def rollback_project(project: Path, yes: bool = False) -> dict[str, Any]:
    workspace = project / "workspace"

    print("")
    print("Rollback will discard uncommitted workspace changes.")
    print("This affects only the workspace folder, not .agent memory.")
    print("")

    if not yes:
        ans = input("Rollback uncommitted workspace changes? [y/N]: ").strip().lower()
        if ans not in {"y", "yes"}:
            return {"ok": False, "blocked": True, "reason": "user denied rollback"}

    result = rollback(workspace)

    print("")
    print("Rollback result")
    print("=" * 72)
    print(json.dumps(result, indent=2))
    print("")

    return result
