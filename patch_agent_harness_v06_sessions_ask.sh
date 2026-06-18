#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v06_sessions_ask.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v06_sessions_ask_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp src/agent_harness/cli.py "$BACKUP_DIR/cli.py.bak"
cp src/agent_harness/ux.py "$BACKUP_DIR/ux.py.bak"
cp src/agent_harness/max_cli.py "$BACKUP_DIR/max_cli.py.bak"

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/sessions.py <<'EOF'
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .util import now_ts, write_json


def sessions_root(project: Path) -> Path:
    root = project / ".agent" / "sessions"
    root.mkdir(parents=True, exist_ok=True)
    return root


def make_session_id() -> str:
    return "session_" + time.strftime("%Y%m%d_%H%M%S")


def latest_file(project: Path) -> Path:
    return sessions_root(project) / "latest"


def create_session(project: Path, title: str = "Max session") -> str:
    sid = make_session_id()
    sdir = sessions_root(project) / sid
    sdir.mkdir(parents=True, exist_ok=True)

    meta = {
        "session_id": sid,
        "title": title,
        "created_at": now_ts(),
        "updated_at": now_ts(),
        "project": str(project),
    }

    write_json(sdir / "meta.json", meta)
    (sdir / "transcript.jsonl").touch()
    (sdir / "events.jsonl").touch()
    (sdir / "summary.md").write_text(f"# {title}\n\nCreated: {meta['created_at']}\n")
    latest_file(project).write_text(sid)

    return sid


def get_latest_session_id(project: Path) -> str | None:
    lf = latest_file(project)
    if not lf.exists():
        return None

    sid = lf.read_text().strip()
    if not sid:
        return None

    if not (sessions_root(project) / sid).exists():
        return None

    return sid


def ensure_session(project: Path, title: str = "Max session", session_id: str | None = None) -> str:
    root = sessions_root(project)

    if session_id:
        if (root / session_id).exists():
            latest_file(project).write_text(session_id)
            return session_id
        return create_session(project, title=title)

    latest = get_latest_session_id(project)
    if latest:
        return latest

    return create_session(project, title=title)


def session_dir(project: Path, session_id: str | None = None) -> Path:
    sid = ensure_session(project, session_id=session_id)
    return sessions_root(project) / sid


def append_jsonl(path: Path, obj: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def log_event(project: Path, event_type: str, data: dict[str, Any], session_id: str | None = None) -> str:
    sid = ensure_session(project, session_id=session_id)
    sdir = sessions_root(project) / sid

    event = {
        "timestamp": now_ts(),
        "type": event_type,
        "data": data,
    }

    append_jsonl(sdir / "events.jsonl", event)

    meta_path = sdir / "meta.json"
    try:
        meta = json.loads(meta_path.read_text())
    except Exception:
        meta = {"session_id": sid}
    meta["updated_at"] = now_ts()
    write_json(meta_path, meta)

    return sid


def log_message(project: Path, role: str, content: str, session_id: str | None = None) -> str:
    sid = ensure_session(project, session_id=session_id)
    sdir = sessions_root(project) / sid

    msg = {
        "timestamp": now_ts(),
        "role": role,
        "content": content,
    }

    append_jsonl(sdir / "transcript.jsonl", msg)

    return sid


def list_sessions(project: Path) -> list[dict[str, Any]]:
    root = sessions_root(project)
    items: list[dict[str, Any]] = []

    for sdir in sorted(root.glob("session_*"), reverse=True):
        meta_path = sdir / "meta.json"
        try:
            meta = json.loads(meta_path.read_text())
        except Exception:
            meta = {
                "session_id": sdir.name,
                "title": sdir.name,
                "created_at": "",
                "updated_at": "",
            }

        transcript = sdir / "transcript.jsonl"
        count = 0
        if transcript.exists():
            count = len(transcript.read_text(errors="replace").splitlines())

        meta["message_count"] = count
        items.append(meta)

    return items


def print_sessions(project: Path) -> None:
    items = list_sessions(project)

    if not items:
        print("No sessions yet.")
        return

    latest = get_latest_session_id(project)

    print("")
    print("Max sessions")
    print("=" * 72)

    for item in items:
        marker = "*" if item.get("session_id") == latest else " "
        print(
            f"{marker} {item.get('session_id')}  "
            f"{item.get('updated_at', '')}  "
            f"{item.get('message_count', 0)} message(s)"
        )

    print("")
    print("* = latest session")
    print("")


def print_session(project: Path, session_id: str | None = None, tail: int = 40) -> None:
    sid = session_id or get_latest_session_id(project)

    if not sid:
        print("No session found.")
        return

    sdir = sessions_root(project) / sid

    if not sdir.exists():
        print(f"Session not found: {sid}")
        return

    print("")
    print(f"Session: {sid}")
    print("=" * 72)

    transcript = sdir / "transcript.jsonl"

    if not transcript.exists():
        print("No transcript found.")
        return

    lines = transcript.read_text(errors="replace").splitlines()
    lines = lines[-tail:]

    for line in lines:
        try:
            item = json.loads(line)
            role = item.get("role", "")
            content = item.get("content", "")
            ts = item.get("timestamp", "")
            print("")
            print(f"[{role}] {ts}")
            print(content)
        except Exception:
            print(line)

    print("")
EOF

cat > src/agent_harness/project_context.py <<'EOF'
from __future__ import annotations

import json
from pathlib import Path

from .util import read_json


def workspace_snapshot(project: Path, max_files: int = 80) -> str:
    workspace = project / "workspace"

    if not workspace.exists():
        return "Workspace folder is missing."

    files = []

    for p in sorted(workspace.rglob("*")):
        if p.is_dir():
            continue
        rel = p.relative_to(workspace)
        if any(part in {"node_modules", ".git", "__pycache__", ".venv"} for part in rel.parts):
            continue
        files.append(str(rel))
        if len(files) >= max_files:
            break

    if not files:
        return "Workspace is empty."

    return "\n".join(f"- {f}" for f in files)


def memory_snapshot(project: Path) -> str:
    agent = project / ".agent"

    current_state = agent / "current_state.md"
    current_tail = ""
    if current_state.exists():
        current_tail = current_state.read_text(errors="replace")[-3000:]

    plan = read_json(agent / "plan.json", {})
    open_issues = read_json(agent / "open_issues.json", {"issues": []})
    commands = read_json(agent / "command_history.json", {"commands": []}).get("commands", [])
    last_commands = commands[-3:]

    return (
        "CURRENT STATE TAIL:\n"
        f"{current_tail}\n\n"
        "PLAN JSON:\n"
        f"{json.dumps(plan, indent=2)[:2000]}\n\n"
        "OPEN ISSUES:\n"
        f"{json.dumps(open_issues, indent=2)[:1200]}\n\n"
        "LAST COMMANDS:\n"
        f"{json.dumps(last_commands, indent=2)[:3000]}\n"
    )
EOF

cat > src/agent_harness/ask_model.py <<'EOF'
from __future__ import annotations

import json
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
    log_event(project, "ask_started", {"prompt": user_prompt})

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

        text = extract_message_text(resp)
        log_event(project, "model_response_raw", {"text_preview": text[:2000]})

        obj = extract_json_object(text)

    except Exception as e:
        obj = {
            "reply": f"I could not complete that request because the model response failed: {e}",
            "need_command": False,
            "suggested_command": "",
            "reason": "",
            "memory_note": f"Ask failed: {e}",
        }
        log_event(project, "ask_failed", {"error": str(e)})

    reply = str(obj.get("reply", "")).strip()
    need_command = bool(obj.get("need_command", False))
    suggested_command = str(obj.get("suggested_command", "") or "").strip()
    reason = str(obj.get("reason", "") or "Max suggested this command.").strip()
    memory_note = str(obj.get("memory_note", "") or "").strip()

    if interactive:
        print("")
        print("Max")
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

if "from .ask_model import ask_project" not in text:
    text = text.replace(
        "from .command_runner import run_command\n",
        "from .command_runner import run_command\nfrom .ask_model import ask_project\n",
    )

text = text.replace(
    'print("Type /help for commands. Type /exit to leave.")',
    'print("Type /help for commands. Type /exit to leave.")\n    print("You can also type normal questions, for example: what is in this project?")',
)

text = text.replace(
    'print("/exit                   Leave interactive session")',
    'print("/exit                   Leave interactive session")\n            print("")\n            print("You can also type a normal question without a slash.")',
)

text = text.replace(
    '        print("Unknown command. Type /help.")',
    '        ask_project(project, line, interactive=True)',
)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/cli.py")
text = p.read_text()

for line, marker in [
    ("from .ask_model import ask_project\n", "from .command_runner import run_command\n"),
    ("from .sessions import print_session, print_sessions\n", "from .schemas import extract_json_object, validate_plan\n"),
]:
    if line not in text:
        text = text.replace(marker, marker + line)

functions = r'''

def cmd_ask(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    prompt = " ".join(args.prompt).strip()

    if not prompt:
        print("ERROR: Missing prompt.")
        print("Example: agentctl ask test-project what is in this project?")
        return

    result = ask_project(
        root,
        prompt,
        interactive=not args.json,
        no_run=args.no_run,
    )

    if args.json:
        print(json.dumps(result, indent=2))


def cmd_sessions(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print_sessions(root)


def cmd_session(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print_session(root, session_id=args.session_id, tail=args.tail)

'''

if "def cmd_ask(args: argparse.Namespace)" not in text:
    text = text.replace("def cmd_benchmark(args: argparse.Namespace) -> None:", functions + "\ndef cmd_benchmark(args: argparse.Namespace) -> None:")

parser_entries = r'''
    p = sub.add_parser("ask")
    p.add_argument("project_name")
    p.add_argument("--no-run", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("prompt", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_ask)

    p = sub.add_parser("sessions")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_sessions)

    p = sub.add_parser("session")
    p.add_argument("project_name")
    p.add_argument("session_id", nargs="?")
    p.add_argument("--tail", type=int, default=40)
    p.set_defaults(func=cmd_session)

'''

if 'sub.add_parser("ask")' not in text:
    text = text.replace('    p = sub.add_parser("benchmark")\n', parser_entries + '\n    p = sub.add_parser("benchmark")\n')

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

# Insert command metadata after start command block.
if '"ask": {' not in text:
    insert_after = '''    "start": {
        "aliases": ["chat", "talk", "open-session", "session"],
        "summary": "Start the interactive Max session.",
        "usage": "max start [project]",
        "agentctl": ["chat"],
        "needs_project": True,
    },
'''
    ask_block = '''    "ask": {
        "aliases": ["question", "tell", "explain"],
        "summary": "Ask Max a project-aware question.",
        "usage": "max ask <question>",
        "agentctl": ["ask"],
        "needs_project": True,
        "remainder": True,
    },
    "sessions": {
        "aliases": ["session-list"],
        "summary": "List saved Max sessions.",
        "usage": "max sessions [project]",
        "agentctl": ["sessions"],
        "needs_project": True,
    },
    "session": {
        "aliases": ["show-session"],
        "summary": "Show latest or selected session transcript.",
        "usage": "max session [project] [session-id]",
        "agentctl": ["session"],
        "needs_project": True,
        "pass_args": True,
    },
'''
    text = text.replace(insert_after, insert_after + ask_block)

# Add ask to home screen.
text = text.replace(
    '("max start", "Open interactive Max session"),',
    '("max start", "Open interactive Max session"),\n        ("max ask \\"what is here?\\"", "Ask a project-aware question"),',
)

# Add ask/sessions to help groups.
text = text.replace(
    '("Daily", ["start", "status", "do", "run", "look", "open"]),',
    '("Daily", ["start", "ask", "status", "do", "run", "look", "open"]),',
)

text = text.replace(
    '("Memory", ["memory", "last"]),',
    '("Memory", ["memory", "last", "sessions", "session"]),',
)

# Replace natural-language one-shot behavior.
old = '''    # Friendly prompt-like behavior. Full natural language one-shot is later.
    if len(argv) == 1 and " " in argv[0]:
        ui.warn("Natural-language one-shot mode is not implemented yet.")
        print("For now use:")
        print("  max start")
        print("  max run")
        return 2
'''
new = '''    # Friendly prompt-like behavior.
    # Example: max "what is in this project?"
    if len(argv) == 1 and " " in argv[0]:
        return dispatch("ask", [argv[0]])
'''
text = text.replace(old, new)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.6 sessions + ask patch installed."
echo ""
echo "Try:"
echo "  max ask \"what is in this project?\""
echo "  max \"what is in this project?\""
echo "  max start"
echo "  max sessions"
echo "  max session"
echo ""
