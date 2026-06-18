#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v08_editing.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v08_editing_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in cli.py ux.py max_cli.py local_answer.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/git_tools.py <<'EOF'
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


def have_git() -> bool:
    return shutil.which("git") is not None


def run_git(workspace: Path, args: list[str], timeout: int = 60) -> dict:
    if not have_git():
        return {
            "ok": False,
            "stdout": "",
            "stderr": "git is not installed",
            "exit_code": None,
        }

    proc = subprocess.run(
        ["git"] + args,
        cwd=str(workspace),
        text=True,
        capture_output=True,
        timeout=timeout,
    )

    return {
        "ok": proc.returncode == 0,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "exit_code": proc.returncode,
    }


def ensure_git_repo(workspace: Path) -> dict:
    if not have_git():
        return {"ok": False, "message": "git is not installed"}

    if not (workspace / ".git").exists():
        init = run_git(workspace, ["init"])
        if not init["ok"]:
            return {"ok": False, "message": init["stderr"]}

    run_git(workspace, ["config", "user.email", "max@local"])
    run_git(workspace, ["config", "user.name", "Max Local Agent"])

    return {"ok": True, "message": "git repo ready"}


def git_status(workspace: Path) -> dict:
    ensure_git_repo(workspace)
    return run_git(workspace, ["status", "--short"])


def git_diff(workspace: Path) -> dict:
    ensure_git_repo(workspace)
    status = run_git(workspace, ["status", "--short"])
    diff = run_git(workspace, ["diff", "--", "."])

    return {
        "ok": status["ok"] and diff["ok"],
        "status": status["stdout"],
        "diff": diff["stdout"],
        "stderr": (status["stderr"] or "") + (diff["stderr"] or ""),
    }


def checkpoint(workspace: Path, message: str) -> dict:
    ready = ensure_git_repo(workspace)
    if not ready["ok"]:
        return {"ok": False, "message": ready["message"]}

    add = run_git(workspace, ["add", "-A"])
    if not add["ok"]:
        return {"ok": False, "message": add["stderr"]}

    status = run_git(workspace, ["status", "--short"])
    if not status["stdout"].strip():
        return {"ok": True, "message": "Nothing to checkpoint.", "committed": False}

    commit = run_git(workspace, ["commit", "-m", message])
    return {
        "ok": commit["ok"],
        "message": commit["stdout"] or commit["stderr"],
        "committed": commit["ok"],
    }


def rollback(workspace: Path) -> dict:
    ready = ensure_git_repo(workspace)
    if not ready["ok"]:
        return {"ok": False, "message": ready["message"]}

    restore = run_git(workspace, ["restore", "."])
    clean = run_git(workspace, ["clean", "-fd"])

    return {
        "ok": restore["ok"] and clean["ok"],
        "message": (restore["stdout"] + restore["stderr"] + clean["stdout"] + clean["stderr"]).strip(),
    }
EOF

cat > src/agent_harness/edit_flow.py <<'EOF'
from __future__ import annotations

import difflib
import json
import time
from pathlib import Path
from typing import Any

from .command_runner import run_command
from .config import load_config
from .git_tools import checkpoint, ensure_git_repo, git_diff, rollback
from .memory import append_command_history, update_current_state
from .ollama_client import chat, extract_message_text
from .schemas import extract_json_object
from .sessions import log_event, log_message
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

    context = workspace_context(workspace)

    prompt = f"""
You are Max, a local coding agent running on the user's Linux laptop.

The controller will validate paths, show a diff, ask approval, and apply files.
You do not run commands directly.

User request:
{user_request}

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
- Use only relative paths inside the workspace.
- Do not use absolute paths.
- Do not use ../
- Do not modify .agent, .git, node_modules, .venv, or system files.
- For each changed file, provide the complete final file content.
- Keep the first patch small and easy to review.
- If creating a Python file, a safe test command can be: python3 filename.py
- If no test command is needed, set test_command to "".
"""

    log_message(project, "user", f"change: {user_request}")
    log_event(project, "change_started", {"request": user_request})

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

    print("")
    print("Change applied.")
    print(f"Report saved to: {report_path}")
    print("")
    print("Next useful commands:")
    print("  max diff")
    print("  max checkpoint -m \"describe this change\"")
    print("  max rollback")
    print("")

    return result


def change_project(project: Path, user_request: str, yes: bool = False, dry_run: bool = False, run_test: bool = False) -> dict[str, Any]:
    print("")
    print("Max is generating a file change with the model.")
    print("This is an important operation, so it may take a while on CPU.")
    print("")

    try:
        change = request_change(project, user_request)
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
EOF

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/cli.py")
text = p.read_text()

if "from .edit_flow import change_project, checkpoint_project, diff_project, rollback_project" not in text:
    text = text.replace(
        "from .doctor import run_doctor\n",
        "from .doctor import run_doctor\nfrom .edit_flow import change_project, checkpoint_project, diff_project, rollback_project\n",
    )

functions = r'''

def cmd_change(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    prompt = " ".join(args.prompt).strip()

    if not prompt:
        print("ERROR: Missing change request.")
        print("Example: agentctl change test-project create a hello.py script")
        return

    result = change_project(
        root,
        prompt,
        yes=args.yes,
        dry_run=args.dry_run,
        run_test=args.run_test,
    )

    if args.json:
        print(json.dumps(result, indent=2))


def cmd_diff(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    result = diff_project(root)

    if args.json:
        print(json.dumps(result, indent=2))


def cmd_checkpoint(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    msg = args.message or "Max checkpoint"
    checkpoint_project(root, msg)


def cmd_rollback(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    rollback_project(root, yes=args.yes)

'''

if "def cmd_change(args: argparse.Namespace)" not in text:
    text = text.replace("def cmd_benchmark(args: argparse.Namespace) -> None:", functions + "\ndef cmd_benchmark(args: argparse.Namespace) -> None:")

parser_entries = r'''
    p = sub.add_parser("change")
    p.add_argument("project_name")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--run-test", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("prompt", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_change)

    p = sub.add_parser("diff")
    p.add_argument("project_name")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_diff)

    p = sub.add_parser("checkpoint")
    p.add_argument("project_name")
    p.add_argument("-m", "--message", default=None)
    p.set_defaults(func=cmd_checkpoint)

    p = sub.add_parser("rollback")
    p.add_argument("project_name")
    p.add_argument("--yes", action="store_true")
    p.set_defaults(func=cmd_rollback)

'''

if 'sub.add_parser("change")' not in text:
    text = text.replace('    p = sub.add_parser("benchmark")\n', parser_entries + '\n    p = sub.add_parser("benchmark")\n')

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

if '"change": {' not in text:
    anchor = '''    "run": {
        "aliases": ["think", "plan"],
        "summary": "Ask Max to produce a safe next plan and suggested command.",
        "usage": "max run [project]",
        "agentctl": ["run"],
        "needs_project": True,
    },
'''
    additions = '''    "change": {
        "aliases": ["edit", "write", "modify", "patch"],
        "summary": "Ask Max to propose file changes, show a diff, and apply after approval.",
        "usage": "max change <request>",
        "agentctl": ["change"],
        "needs_project": True,
        "remainder": True,
    },
    "diff": {
        "aliases": ["changes"],
        "summary": "Show workspace Git status and diff.",
        "usage": "max diff",
        "agentctl": ["diff"],
        "needs_project": True,
    },
    "checkpoint": {
        "aliases": ["save", "commit"],
        "summary": "Commit current workspace changes as a checkpoint.",
        "usage": "max checkpoint -m <message>",
        "agentctl": ["checkpoint"],
        "needs_project": True,
        "pass_args": True,
    },
    "rollback": {
        "aliases": ["undo", "revert"],
        "summary": "Discard uncommitted workspace changes.",
        "usage": "max rollback",
        "agentctl": ["rollback"],
        "needs_project": True,
        "pass_args": True,
    },
'''
    text = text.replace(anchor, anchor + additions)

text = text.replace(
    '("max run", "Ask the model for the next safe action"),',
    '("max run", "Ask the model for the next safe action"),\n        ("max change \\"create hello.py\\"", "Propose file changes with diff + approval"),\n        ("max diff", "Show workspace changes"),\n        ("max checkpoint -m \\"msg\\"", "Save a Git checkpoint"),',
)

text = text.replace(
    '("Daily", ["start", "ask", "think", "files", "info", "status", "do", "run", "look", "open"]),',
    '("Daily", ["start", "ask", "think", "files", "info", "status", "do", "run", "change", "diff", "checkpoint", "look", "open"]),',
)

text = text.replace(
    '("Advanced", ["raw", "help"]),',
    '("Advanced", ["rollback", "raw", "help"]),',
)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/ux.py")
text = p.read_text()

# Stop accidental model calls in chat. Unknown normal text should not call Qwen.
old = '''        smart_ask_project(project, line, interactive=True)
'''
new = '''        local = local_answer(project, line)
        if local is not None:
            answer_local_and_log(project, line, local, interactive=True)
        else:
            print("")
            print("Max did not call the model automatically.")
            print("Use /think <question> when you want the slow model path.")
            print("Use max change \"...\" outside chat when you want file edits.")
            print("")
'''

if old in text:
    text = text.replace(old, new)

if "from .local_answer import local_answer, answer_local_and_log" not in text:
    text = text.replace(
        "from .local_answer import files_text, info_text, last_command_text, memory_text, model_text, paths_text, status_text\n",
        "from .local_answer import answer_local_and_log, files_text, info_text, last_command_text, local_answer, memory_text, model_text, paths_text, status_text\n",
    )

# Help text additions
if 'print("/change is outside chat' not in text:
    text = text.replace(
        'print("/think <question>       Force a model call")',
        'print("/think <question>       Force a model call")\n            print("/change is outside chat  Use: max change \\"your request\\"")',
    )

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/local_answer.py")
text = p.read_text()

# Add phrase that previously missed local routing.
text = text.replace(
    '"what is in this project",',
    '"what is in this project",\n            "what is in the project",',
)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.8 editing patch installed."
echo ""
echo "Try these:"
echo "  max start"
echo "  max change \"create a small hello.py script that prints hello from Max\""
echo "  max diff"
echo "  max checkpoint -m \"add hello script\""
echo "  max rollback"
echo ""
echo "Inside max start, normal unknown text will NOT call the model automatically anymore."
