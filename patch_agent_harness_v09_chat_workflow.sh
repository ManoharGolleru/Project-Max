#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v09_chat_workflow.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v09_chat_workflow_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in ux.py ask_model.py git_tools.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/git_tools.py <<'EOF'
from __future__ import annotations

import difflib
import shutil
import subprocess
from pathlib import Path


TEXT_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".json", ".md", ".txt", ".html", ".css",
    ".scss", ".yml", ".yaml", ".toml", ".sh", ".csv", ".xml", ".env", ".gitignore",
}


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


def _safe_rel(path_text: str) -> bool:
    p = Path(path_text)
    if p.is_absolute():
        return False
    if ".." in p.parts:
        return False
    if any(part in {".git", ".agent", "node_modules", "__pycache__", ".venv"} for part in p.parts):
        return False
    return True


def _is_text_file(path: Path) -> bool:
    if path.name == ".gitignore":
        return True
    return path.suffix.lower() in TEXT_EXTS


def _untracked_file_diff(workspace: Path, status_text: str) -> str:
    out: list[str] = []

    for line in status_text.splitlines():
        if not line.startswith("?? "):
            continue

        rel = line[3:].strip()

        if not _safe_rel(rel):
            continue

        p = workspace / rel

        if not p.exists() or not p.is_file():
            continue

        if not _is_text_file(p):
            out.append(f"\n--- untracked binary or unsupported file: {rel} ---\n")
            continue

        try:
            content = p.read_text(errors="replace")
        except Exception as e:
            out.append(f"\n--- could not read untracked file: {rel}: {e} ---\n")
            continue

        if len(content) > 200000:
            out.append(f"\n--- untracked file too large to preview: {rel} ---\n")
            continue

        diff = difflib.unified_diff(
            [],
            content.splitlines(keepends=True),
            fromfile="/dev/null",
            tofile=f"b/{rel}",
        )

        out.append("".join(diff))

    return "\n".join(part for part in out if part)


def git_status(workspace: Path) -> dict:
    ensure_git_repo(workspace)
    return run_git(workspace, ["status", "--short"])


def git_diff(workspace: Path) -> dict:
    ensure_git_repo(workspace)

    status = run_git(workspace, ["status", "--short"])
    tracked = run_git(workspace, ["diff", "--", "."])

    tracked_diff = tracked["stdout"] or ""
    untracked_diff = _untracked_file_diff(workspace, status["stdout"] or "")
    combined_diff = "\n".join(part for part in [tracked_diff, untracked_diff] if part.strip())

    return {
        "ok": status["ok"] and tracked["ok"],
        "status": status["stdout"],
        "diff": combined_diff,
        "tracked_diff": tracked_diff,
        "untracked_diff": untracked_diff,
        "stderr": (status["stderr"] or "") + (tracked["stderr"] or ""),
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

cat > src/agent_harness/chat_actions.py <<'EOF'
from __future__ import annotations

import json
import shlex
from pathlib import Path

from .command_runner import run_command
from .edit_flow import change_project, checkpoint_project, diff_project, rollback_project
from .local_answer import answer_local_and_log, files_text, local_answer, status_text
from .memory import append_command_history, update_current_state
from .sessions import print_session, print_sessions


def _print_local(title: str, text: str) -> None:
    print("")
    print(f"Max [local: {title}]")
    print("=" * 72)
    print(text)
    print("")


def _usage() -> None:
    print("")
    print("Max did not call the model automatically.")
    print("")
    print("Useful options:")
    print('  /think what should I build next        slow model reasoning')
    print('  /change create hello.py               generate file changes with diff + approval')
    print('  /do python3 hello.py                  run a safe command')
    print('  /diff                                 show workspace changes')
    print('  /checkpoint add hello script          save a Git checkpoint')
    print("")
    print('You can also type the same commands with max, for example:')
    print('  max change "create a small hello.py script"')
    print("")


def _parse(text: str) -> list[str] | None:
    try:
        return shlex.split(text)
    except ValueError as e:
        print(f"Could not parse command: {e}")
        return None


def _checkpoint_message(parts: list[str]) -> str:
    if not parts:
        return "Max checkpoint"

    if parts[0] in {"-m", "--message"} and len(parts) > 1:
        return " ".join(parts[1:])

    return " ".join(parts)


def handle_chat_fallback(project: Path, line: str) -> None:
    raw = line.strip()

    if not raw:
        return

    local = local_answer(project, raw)
    if local is not None:
        answer_local_and_log(project, raw, local, interactive=True)
        return

    cmd_text = raw

    if cmd_text.startswith("max "):
        cmd_text = cmd_text[4:].strip()

    if cmd_text.startswith("/"):
        cmd_text = cmd_text[1:].strip()

    parts = _parse(cmd_text)
    if not parts:
        return

    cmd = parts[0].lower()
    rest = parts[1:]

    if cmd in {"project", "projects", "files", "file", "tree"}:
        _print_local("files", files_text(project))
        return

    if cmd in {"status", "dashboard", "overview"}:
        _print_local("status", status_text(project))
        return

    if cmd in {"sessions", "session-list"}:
        print_sessions(project)
        return

    if cmd in {"session", "show-session"}:
        session_id = rest[0] if rest else None
        print_session(project, session_id=session_id)
        return

    if cmd in {"change", "edit", "write", "modify", "patch"}:
        request = " ".join(rest).strip()
        if not request:
            print('Usage: /change create a small hello.py script')
            return

        change_project(project, request)
        return

    if cmd in {"diff", "changes"}:
        diff_project(project)
        return

    if cmd in {"checkpoint", "save", "commit"}:
        checkpoint_project(project, _checkpoint_message(rest))
        return

    if cmd in {"rollback", "undo", "revert"}:
        rollback_project(project)
        return

    if cmd in {"do", "safe", "safe-run", "cmd", "command"}:
        if not rest:
            print("Usage: /do <safe command>")
            return

        command = " ".join(rest)
        workspace = project / "workspace"

        result = run_command(
            command=command,
            cwd=workspace,
            workspace_root=workspace,
            reason="User requested a safe command from chat.",
            ask=True,
        )

        append_command_history(project, result)
        update_current_state(project, f"Chat command result:\n\n{json.dumps(result, indent=2)}")
        print(json.dumps(result, indent=2))
        return

    if any(word in raw.lower() for word in ["build", "next", "plan", "fix", "create", "make"]):
        print("")
        print("Max did not call the model automatically.")
        print("")
        print("For advice/reasoning:")
        print(f"  /think {raw}")
        print("")
        print("For actual file changes:")
        print(f"  /change {raw}")
        print("")
        return

    _usage()
EOF

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/agent_harness/ask_model.py")
text = p.read_text()

target = "    except Exception as e:\n        duration = round(time.time() - model_start, 3)\n"

insert = '''    except KeyboardInterrupt:
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

'''

if "ask_cancelled" not in text and target in text:
    text = text.replace(target, insert + target, 1)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/agent_harness/ux.py")
text = p.read_text()

if "from .chat_actions import handle_chat_fallback" not in text:
    text = text.replace(
        "from .command_runner import run_command\n",
        "from .command_runner import run_command\nfrom .chat_actions import handle_chat_fallback\n",
    )

text = text.replace("agent-harness interactive session", "Max interactive session")
text = text.replace('line = input("agent> ").strip()', 'line = input("max> ").strip()')

text = text.replace(
    'print("You can also type normal questions, for example: what is in this project?")',
    'print("Plain text is handled locally or gives suggestions.")\n    print("Use /think for slow model reasoning. Use /change or max change for file edits.")',
)

text = text.replace(
    'print("You can also type a normal question without a slash.")',
    'print("Plain text will not call the model automatically.")',
)

# Make /think reasoning-only inside chat.
text = text.replace(
    "smart_ask_project(project, prompt, interactive=True, force_model=True)",
    "smart_ask_project(project, prompt, interactive=True, no_run=True, force_model=True)",
)

# Clean awkward help line if present.
text = text.replace(
    'print("/change is outside chat  Use: max change \\"your request\\"")',
    'print("/change <request>      Generate file changes with diff + approval")',
)
text = text.replace(
    'print("/change is outside chat  Use: max change \\"your request\\"")',
    'print("/change <request>      Generate file changes with diff + approval")',
)

# Add clearer chat help lines if missing.
if 'print("/do <command>' not in text:
    text = text.replace(
        'print("/safe <command>         Run a command through safety checks")',
        'print("/safe <command>         Run a command through safety checks")\n            print("/do <command>           Same as /safe, shorter")\n            print("/diff                   Show workspace diff")\n            print("/checkpoint <message>   Save a Git checkpoint")\n            print("/rollback               Discard uncommitted workspace changes")',
    )

# Replace final generic fallback block from v0.8.
pattern = r'''        local = local_answer\(project, line\)
        if local is not None:
            answer_local_and_log\(project, line, local, interactive=True\)
        else:
            print\(""\)
            print\("Max did not call the model automatically\."\)
            print\("Use /think <question> when you want the slow model path\."\)
            print\([^\n]*file edits\.[^\n]*\)
            print\(""\)
'''

replacement = '''        handle_chat_fallback(project, line)
'''

text2, count = re.subn(pattern, replacement, text)

if count == 0:
    # Older fallback from v0.6, just in case.
    text2 = text.replace(
        "        smart_ask_project(project, line, interactive=True)\n",
        "        handle_chat_fallback(project, line)\n",
    )

p.write_text(text2)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.9 chat workflow patch installed."
echo ""
echo "Test:"
echo "  max start"
echo ""
echo "Inside chat:"
echo "  projects"
echo "  what should i build next"
echo "  /change create a small hello2.py script that prints hello again from Max"
echo "  /do python3 hello2.py"
echo "  /diff"
echo "  /checkpoint add hello2 script"
echo "  /exit"
echo ""
echo "Also test:"
echo "  max diff"
