#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v07_speed_router.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v07_speed_router_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in cli.py ux.py max_cli.py ask_model.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/local_answer.py <<'EOF'
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .config import load_config
from .sessions import log_event, log_message
from .util import read_json


def _workspace(project: Path) -> Path:
    return project / "workspace"


def _agent(project: Path) -> Path:
    return project / ".agent"


def _file_count(project: Path) -> tuple[int, int]:
    workspace = _workspace(project)
    files = 0
    dirs = 0

    if not workspace.exists():
        return 0, 0

    for p in workspace.rglob("*"):
        rel = p.relative_to(workspace)
        if any(part in {"node_modules", ".git", "__pycache__", ".venv"} for part in rel.parts):
            continue
        if p.is_file():
            files += 1
        elif p.is_dir():
            dirs += 1

    return files, dirs


def files_text(project: Path, max_items: int = 80) -> str:
    workspace = _workspace(project)

    if not workspace.exists():
        return f"The workspace folder does not exist yet:\n{workspace}"

    items: list[str] = []

    for p in sorted(workspace.rglob("*")):
        rel = p.relative_to(workspace)
        if any(part in {"node_modules", ".git", "__pycache__", ".venv"} for part in rel.parts):
            continue

        if p.is_dir():
            continue

        try:
            size = p.stat().st_size
        except Exception:
            size = 0

        items.append(f"- {rel} ({size} bytes)")

        if len(items) >= max_items:
            break

    if not items:
        return (
            f"The workspace is empty.\n\n"
            f"Workspace path:\n{workspace}\n\n"
            "There are no project files yet inside `workspace/`."
        )

    files, dirs = _file_count(project)

    more = ""
    if files > len(items):
        more = f"\n\nShowing {len(items)} of {files} files."

    return (
        f"Workspace path:\n{workspace}\n\n"
        f"Found {files} file(s) and {dirs} folder(s).\n\n"
        "Files:\n"
        + "\n".join(items)
        + more
    )


def last_command_text(project: Path) -> str:
    data = read_json(_agent(project) / "command_history.json", {"commands": []})
    commands = data.get("commands", [])

    if not commands:
        return "No commands have been run through Max yet."

    last = commands[-1]

    return (
        "Last command:\n\n"
        f"Command: {last.get('command')}\n"
        f"OK: {last.get('ok')}\n"
        f"Blocked: {last.get('blocked')}\n"
        f"Exit code: {last.get('exit_code')}\n"
        f"Time: {last.get('timestamp', '')}\n\n"
        f"stdout:\n{(last.get('stdout') or '').strip() or '[empty]'}\n\n"
        f"stderr:\n{(last.get('stderr') or '').strip() or '[empty]'}"
    )


def memory_text(project: Path) -> str:
    agent = _agent(project)

    if not agent.exists():
        return f"No `.agent/` memory folder found at:\n{agent}"

    files = []

    for p in sorted(agent.rglob("*")):
        if p.is_file():
            files.append(f"- {p.relative_to(agent)}")

    if not files:
        return f"The memory folder exists but has no files:\n{agent}"

    return (
        f"Memory folder:\n{agent}\n\n"
        "Memory files:\n"
        + "\n".join(files[:120])
    )


def model_text(project: Path) -> str:
    global_cfg = load_config()
    project_cfg = read_json(project / "agent.config.json", {})

    model = project_cfg.get("model") or global_cfg.get("model")
    context = project_cfg.get("context") or global_cfg.get("default_context")
    temp = project_cfg.get("temperature") or global_cfg.get("temperature")
    ram_limit = project_cfg.get("ram_limit_gb") or global_cfg.get("ram_limit_gb")

    return (
        "Current model settings:\n\n"
        f"Model: {model}\n"
        f"Context: {context}\n"
        f"Temperature: {temp}\n"
        f"RAM limit: {ram_limit} GB\n\n"
        "This is read from the project config first, then the global Max config."
    )


def status_text(project: Path) -> str:
    agent = _agent(project)
    workspace = _workspace(project)

    plan = read_json(agent / "plan.json", {})
    open_issues = read_json(agent / "open_issues.json", {"issues": []})
    completed = read_json(agent / "completed_steps.json", {"steps": []})
    commands = read_json(agent / "command_history.json", {"commands": []}).get("commands", [])
    files, dirs = _file_count(project)

    last = commands[-1] if commands else None

    lines = [
        "Project status:",
        "",
        f"Project: {project}",
        f"Workspace: {workspace}",
        f"Memory: {agent}",
        "",
        f"Workspace files: {files}",
        f"Workspace folders: {dirs}",
        f"Plan goal: {plan.get('goal', 'none')}",
        f"Plan steps: {len(plan.get('steps', []))}",
        f"Open issues: {len(open_issues.get('issues', []))}",
        f"Completed steps: {len(completed.get('steps', []))}",
        f"Commands run: {len(commands)}",
    ]

    if last:
        lines.extend(
            [
                "",
                "Last command:",
                f"  {last.get('command')}",
                f"  OK: {last.get('ok')}",
                f"  Blocked: {last.get('blocked')}",
            ]
        )

    return "\n".join(lines)


def paths_text(project: Path) -> str:
    return (
        "Current Max paths:\n\n"
        f"Project:\n{project}\n\n"
        f"Workspace:\n{_workspace(project)}\n\n"
        f"Memory:\n{_agent(project)}"
    )


def _contains_any(text: str, phrases: list[str]) -> bool:
    return any(p in text for p in phrases)


def local_answer(project: Path, prompt: str) -> dict[str, Any] | None:
    t0 = time.time()
    lower = prompt.strip().lower()

    if not lower:
        return None

    # File/project contents
    if _contains_any(
        lower,
        [
            "what is in this project",
            "what's in this project",
            "what is inside this project",
            "what files",
            "files are here",
            "what is here",
            "list files",
            "show files",
            "workspace empty",
            "anything in this project",
            "what is in the workspace",
            "what's in the workspace",
        ],
    ):
        reply = files_text(project)
        intent = "files"

    # Status
    elif _contains_any(
        lower,
        [
            "status",
            "current state",
            "current status",
            "what is going on",
            "where are we",
            "project state",
            "overview",
        ],
    ):
        reply = status_text(project)
        intent = "status"

    # Last command/history
    elif _contains_any(
        lower,
        [
            "last command",
            "previous command",
            "recent command",
            "what command",
            "command history",
            "last thing",
        ],
    ):
        reply = last_command_text(project)
        intent = "last_command"

    # Model/config
    elif _contains_any(
        lower,
        [
            "what model",
            "which model",
            "model am i using",
            "qwen",
            "context size",
            "temperature",
            "ram limit",
        ],
    ):
        reply = model_text(project)
        intent = "model"

    # Memory
    elif _contains_any(
        lower,
        [
            "memory",
            "agent memory",
            ".agent",
            "memory files",
        ],
    ):
        reply = memory_text(project)
        intent = "memory"

    # Paths
    elif _contains_any(
        lower,
        [
            "where is this project",
            "project path",
            "workspace path",
            "where is workspace",
            "where is the memory",
        ],
    ):
        reply = paths_text(project)
        intent = "paths"

    else:
        return None

    elapsed = round(time.time() - t0, 4)

    return {
        "source": "local",
        "intent": intent,
        "reply": reply,
        "duration_sec": elapsed,
    }


def print_local_answer(result: dict[str, Any]) -> None:
    print("")
    print(f"Max [local, {result.get('duration_sec', 0):.2f}s]")
    print("=" * 72)
    print(result["reply"])
    print("")


def answer_local_and_log(project: Path, prompt: str, result: dict[str, Any], interactive: bool = True) -> dict[str, Any]:
    log_message(project, "user", prompt)
    log_message(project, "assistant", result["reply"])
    log_event(project, "local_answer", result)

    if interactive:
        print_local_answer(result)

    return {
        "reply": result["reply"],
        "source": "local",
        "intent": result.get("intent"),
        "duration_sec": result.get("duration_sec"),
        "need_command": False,
        "suggested_command": "",
        "reason": "Answered locally without model call.",
        "command_result": None,
    }
EOF

cat > src/agent_harness/smart_ask.py <<'EOF'
from __future__ import annotations

from pathlib import Path

from .ask_model import ask_project
from .local_answer import answer_local_and_log, local_answer


def smart_ask_project(
    project: Path,
    user_prompt: str,
    interactive: bool = True,
    no_run: bool = False,
    force_model: bool = False,
) -> dict:
    if not force_model:
        local = local_answer(project, user_prompt)
        if local is not None:
            return answer_local_and_log(project, user_prompt, local, interactive=interactive)

    return ask_project(
        project,
        user_prompt,
        interactive=interactive,
        no_run=no_run,
    )
EOF

cat > src/agent_harness/ask_model.py <<'EOF'
from __future__ import annotations

import json
import time
from pathlib import Path

from .command_runner import run_command
from .config import load_config
from .memory import append_command_history, update_current_state
from .ollama_client import chat, extract_message_text
from .project_context import memory_snapshot, workspace_snapshot
from .schemas import extract_json_object
from .sessions import log_event, log_message


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
EOF

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/ux.py")
text = p.read_text()

# Imports
text = text.replace(
    "from .ask_model import ask_project\n",
    "from .ask_model import ask_project\nfrom .smart_ask import smart_ask_project\nfrom .local_answer import files_text, info_text, last_command_text, memory_text, model_text, paths_text, status_text\n",
)

if "from .sessions import print_sessions" not in text:
    text = text.replace(
        "from .ollama_control import unload_model\n",
        "from .ollama_control import unload_model\nfrom .sessions import print_sessions, print_session\n",
    )

# Add helper import fallback if info_text does not exist yet, this file will now rely on it.
# Replace generic unknown behavior.
text = text.replace(
    "        ask_project(project, line, interactive=True)",
    "        smart_ask_project(project, line, interactive=True)"
)

# Add help lines if not present.
if 'print("/files' not in text:
    text = text.replace(
        'print("/dashboard              Show project dashboard")',
        'print("/dashboard              Show project dashboard")\n            print("/files                  Show workspace files instantly")\n            print("/info                   Show project/model/path info instantly")\n            print("/model                  Show model config instantly")\n            print("/where                  Show project paths instantly")\n            print("/sessions               List saved sessions")\n            print("/think <question>       Force a model call")',
    )

# Add slash handlers before /dashboard.
marker = '        if line == "/dashboard":\n'
handlers = r'''
        if line == "/files":
            print("")
            print("Max [local]")
            print("=" * 72)
            print(files_text(project))
            print("")
            continue

        if line == "/info":
            print("")
            print("Max [local]")
            print("=" * 72)
            print(status_text(project))
            print("")
            print(model_text(project))
            print("")
            continue

        if line == "/model":
            print("")
            print("Max [local]")
            print("=" * 72)
            print(model_text(project))
            print("")
            continue

        if line == "/where":
            print("")
            print("Max [local]")
            print("=" * 72)
            print(paths_text(project))
            print("")
            continue

        if line == "/sessions":
            print_sessions(project)
            continue

        if line.startswith("/think "):
            prompt = line[len("/think "):].strip()
            if not prompt:
                print("Usage: /think <question>")
            else:
                smart_ask_project(project, prompt, interactive=True, force_model=True)
            continue

'''
if handlers.strip() not in text:
    text = text.replace(marker, handlers + marker)

p.write_text(text)
PY

# Add missing info_text by appending to local_answer.py if not present.
python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/local_answer.py")
text = p.read_text()

if "def info_text(" not in text:
    insert = r'''

def info_text(project: Path) -> str:
    return (
        status_text(project)
        + "\n\n"
        + model_text(project)
        + "\n\n"
        + paths_text(project)
    )
'''
    text = text.replace("def _contains_any", insert + "\n\ndef _contains_any")

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/cli.py")
text = p.read_text()

# Imports
if "from .smart_ask import smart_ask_project" not in text:
    text = text.replace(
        "from .ask_model import ask_project\n",
        "from .ask_model import ask_project\nfrom .smart_ask import smart_ask_project\n",
    )

if "from .local_answer import files_text, info_text" not in text:
    text = text.replace(
        "from .long_context_test import run_long_context_test\n",
        "from .long_context_test import run_long_context_test\nfrom .local_answer import files_text, info_text\n",
    )

# Replace cmd_ask internals to use smart_ask_project.
old = '''    result = ask_project(
        root,
        prompt,
        interactive=not args.json,
        no_run=args.no_run,
    )
'''
new = '''    result = smart_ask_project(
        root,
        prompt,
        interactive=not args.json,
        no_run=args.no_run,
        force_model=False,
    )
'''
text = text.replace(old, new)

# Add cmd_think, cmd_files, cmd_info.
functions = r'''

def cmd_think(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    prompt = " ".join(args.prompt).strip()

    if not prompt:
        print("ERROR: Missing prompt.")
        print("Example: agentctl think test-project what should I do next?")
        return

    result = smart_ask_project(
        root,
        prompt,
        interactive=not args.json,
        no_run=args.no_run,
        force_model=True,
    )

    if args.json:
        print(json.dumps(result, indent=2))


def cmd_files(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print(files_text(root))


def cmd_info(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print(info_text(root))

'''

if "def cmd_think(args: argparse.Namespace)" not in text:
    text = text.replace("def cmd_sessions(args: argparse.Namespace) -> None:", functions + "\ndef cmd_sessions(args: argparse.Namespace) -> None:")

# Add parser entries after ask parser block.
parser_entries = r'''
    p = sub.add_parser("think")
    p.add_argument("project_name")
    p.add_argument("--no-run", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("prompt", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_think)

    p = sub.add_parser("files")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_files)

    p = sub.add_parser("info")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_info)

'''

if 'sub.add_parser("think")' not in text:
    text = text.replace('    p = sub.add_parser("sessions")\n', parser_entries + '\n    p = sub.add_parser("sessions")\n')

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

# Add COMMANDS entries after ask block if missing.
if '"think": {' not in text:
    anchor = '''    "ask": {
        "aliases": ["question", "tell", "explain"],
        "summary": "Ask Max a project-aware question.",
        "usage": "max ask <question>",
        "agentctl": ["ask"],
        "needs_project": True,
        "remainder": True,
    },
'''
    additions = '''    "think": {
        "aliases": ["reason", "decide", "plan-next"],
        "summary": "Force a model call for reasoning, planning, or decisions.",
        "usage": "max think <question>",
        "agentctl": ["think"],
        "needs_project": True,
        "remainder": True,
    },
    "files": {
        "aliases": ["file", "tree"],
        "summary": "Show workspace files instantly without using the model.",
        "usage": "max files",
        "agentctl": ["files"],
        "needs_project": True,
    },
    "info": {
        "aliases": ["about"],
        "summary": "Show project, model, memory, and path info instantly.",
        "usage": "max info",
        "agentctl": ["info"],
        "needs_project": True,
    },
'''
    text = text.replace(anchor, anchor + additions)

# Update home rows.
if '("max files", "Show workspace files instantly")' not in text:
    text = text.replace(
        '("max ask \\"what is here?\\"", "Ask a project-aware question"),',
        '("max ask \\"what is here?\\"", "Ask a project-aware question"),\n        ("max think \\"what next?\\"", "Force a model reasoning call"),\n        ("max files", "Show workspace files instantly"),\n        ("max info", "Show project/model info instantly"),',
    )

# Update help daily group.
text = text.replace(
    '("Daily", ["start", "ask", "status", "do", "run", "look", "open"]),',
    '("Daily", ["start", "ask", "think", "files", "info", "status", "do", "run", "look", "open"]),',
)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.7 speed/router patch installed."
echo ""
echo "Try:"
echo "  max files"
echo "  max info"
echo "  max ask \"what is in this project?\""
echo "  max \"what model am I using?\""
echo "  max think \"what should I test next?\""
echo "  max start"
echo ""
echo "Inside max start try:"
echo "  what is in this project?"
echo "  /files"
echo "  /info"
echo "  /think what should I test next?"
