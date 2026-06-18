#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v15_run_files_fix.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v15_run_files_fix_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py chat_actions.py ux.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

# Ensure shlex is imported.
if "import shlex\n" not in text:
    text = text.replace("import os\n", "import os\nimport shlex\n")

# Fix alias conflict: max files should mean workspace files, not memory.
text = text.replace('"aliases": ["mem", "files"],', '"aliases": ["mem"],')
text = text.replace('"aliases": ["files", "mem"],', '"aliases": ["mem"],')

# Replace the old "run means agent next-action" block with user-friendly run.
run_pattern = r'''    "run": \{
        "aliases": \[[^\]]*\],
        "summary": "Ask Max to produce a safe next plan and suggested command\.",
        "usage": "max run \[project\]",
        "agentctl": \["run"\],
        "needs_project": True,
    \},
'''

run_replacement = '''    "run": {
        "aliases": ["execute"],
        "summary": "Run a file or command safely inside the workspace.",
        "usage": "max run <file-or-command>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "next": {
        "aliases": ["plan-next"],
        "summary": "Ask Max to produce a safe next plan and suggested command.",
        "usage": "max next [project]",
        "agentctl": ["run"],
        "needs_project": True,
    },
'''

text, count = re.subn(run_pattern, run_replacement, text)

if count == 0 and '"next": {' not in text:
    print("WARNING: could not replace run block automatically")

# Add direct safe command runner helpers if missing.
helper = r'''

def _normalize_safe_command_args(rest: list[str]) -> list[str]:
    if not rest:
        return []

    # Allow: max run "python3 calc2.py"
    if len(rest) == 1:
        try:
            parts = shlex.split(rest[0])
        except ValueError:
            parts = rest
    else:
        parts = rest

    if len(parts) == 1:
        target = parts[0]

        # Layman shortcut:
        #   max run calc2.py
        # becomes:
        #   python3 calc2.py
        if target.endswith(".py"):
            return ["python3", target]

        if target.endswith(".sh"):
            return ["bash", target]

    return parts


def cmd_direct_safe_command(args: list[str], allow_empty_as_next: bool = False) -> int:
    project_text, rest = project_from_args(args)

    if project_text is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2

    if not rest:
        if allow_empty_as_next:
            return run_agentctl(["run", project_text])
        ui.fail("Missing command.")
        print("Use: max run <file-or-command>")
        print("Examples:")
        print("  max run calc2.py")
        print("  max run python3 calc2.py")
        print("  max do ls -lh .")
        return 2

    command_args = _normalize_safe_command_args(rest)

    return run_agentctl(["safe-run", project_text] + command_args)

'''

if "def _normalize_safe_command_args(rest: list[str])" not in text:
    text = text.replace("def dispatch(canonical: str, args: list[str]) -> int:", helper + "\ndef dispatch(canonical: str, args: list[str]) -> int:")

# Add dispatch cases for run/do before backend fallback.
old = '''    if canonical == "use":
        return cmd_use(args)

'''
new = '''    if canonical == "use":
        return cmd_use(args)

    if canonical == "run":
        return cmd_direct_safe_command(args, allow_empty_as_next=True)

    if canonical == "do":
        return cmd_direct_safe_command(args, allow_empty_as_next=False)

'''
if old in text and "cmd_direct_safe_command(args, allow_empty_as_next=True)" not in text:
    text = text.replace(old, new)

# Make help/home text clearer.
text = text.replace(
    '("max run", "Ask the model for the next safe action"),',
    '("max run calc2.py", "Run a workspace file safely"),\n        ("max next", "Ask model for next safe action"),'
)

text = text.replace(
    '("max files", "Show workspace files instantly"),',
    '("max files", "Show workspace files instantly"),'
)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/chat_actions.py")
text = p.read_text()

# Add smart command normalization inside chat.
helper = r'''

def _smart_command(rest: list[str]) -> str:
    if not rest:
        return ""

    if len(rest) == 1:
        target = rest[0]
        if target.endswith(".py"):
            return "python3 " + target
        if target.endswith(".sh"):
            return "bash " + target

    return " ".join(rest)

'''

if "def _smart_command(rest: list[str])" not in text:
    text = text.replace("def _checkpoint_message(parts: list[str]) -> str:", helper + "\ndef _checkpoint_message(parts: list[str]) -> str:")

# Ensure /run and /do both use the smart command converter.
text = text.replace(
'''        # Layman shortcut: run calculator.py -> python3 calculator.py
        if len(rest) == 1 and rest[0].endswith(".py"):
            command = "python3 " + rest[0]
        else:
            command = " ".join(rest)
''',
'''        command = _smart_command(rest)
'''
)

# Replace /do plain join.
text = text.replace(
'''        command = " ".join(rest)
        workspace = project / "workspace"
''',
'''        command = _smart_command(rest)
        workspace = project / "workspace"
'''
)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/ux.py")
text = p.read_text()

# Dashboard should show max commands, not backend agentctl commands.
old = '''    print(f"agentctl chat {project}")
    print(f"agentctl run {project}")
    print(f"agentctl inspect {project}")
    print(f"agentctl last {project}")
    print(f"agentctl setup-vscode {project}")
    print(f"agentctl open {project}")
'''
new = '''    print(f"max start {project}")
    print(f"max files {project}")
    print(f"max tree {project}")
    print(f"max read <file>")
    print(f"max run <file.py>")
    print(f"max change \\"your request\\"")
    print(f"max diff {project}")
    print(f"max checkpoint -m \\"message\\"")
    print(f"max open {project}")
'''
if old in text:
    text = text.replace(old, new)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.15 run/files routing fix installed."
echo ""
echo "Test:"
echo "  max files"
echo "  max run calc2.py"
echo "  max run calculator.py"
echo "  max do calc2.py"
echo "  max next"
echo ""
echo "Inside chat:"
echo "  run calc2.py"
echo "  max run calculator.py"
echo "  /do calc2.py"
