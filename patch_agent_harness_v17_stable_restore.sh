#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v17_stable_restore.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v17_stable_restore_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py chat_actions.py edit_flow.py task_flow.py ux.py test_flow.py; do
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

# v18/v18b/v18c repair: remove the experimental test_flow import wherever it landed.
lines = []
for line in text.splitlines():
    if line.strip() in {
        "from .test_flow import test_project, test_from_cwd",
        "from .test_flow import test_project",
        "from .test_flow import test_from_cwd",
    }:
        continue
    lines.append(line)
text = "\n".join(lines) + "\n"

# v18 repair: remove the broken max test dispatch that referenced undefined project/rest.
text = re.sub(
    r'\n\s*if canonical == ["\']test["\']:\n\s*raise SystemExit\(test_project\(project, rest, normalizer=_normalize_safe_command_args\)\)\n',
    "\n",
    text,
)
text = re.sub(
    r'\n\s*if canonical == ["\']test["\']:\n\s*raise SystemExit\(test_from_cwd\(rest, normalizer=_normalize_safe_command_args\)\)\n',
    "\n",
    text,
)

# Restore the v17 run/do argument normalizer.
normalizer = '''def _normalize_safe_command_args(rest: list[str]) -> list[str]:
    if not rest:
        return []

    # Allow both:
    #   max run "python3 calc2.py add 5 3"
    #   max run calc2.py add 5 3
    if len(rest) == 1:
        try:
            parts = shlex.split(rest[0])
        except ValueError:
            parts = rest
    else:
        parts = rest

    if not parts:
        return []

    target = parts[0]

    # Layman shortcuts:
    #   max run calc2.py
    #   max run calc2.py add 5 3
    # become:
    #   python3 calc2.py
    #   python3 calc2.py add 5 3
    if target.endswith(".py"):
        return ["python3", target] + parts[1:]

    if target.endswith(".sh"):
        return ["bash", target] + parts[1:]

    return parts

'''
text = re.sub(
    r'def _normalize_safe_command_args\(rest: list\[str\]\) -> list\[str\]:\n.*?\n(?=def cmd_direct_safe_command)',
    normalizer,
    text,
    flags=re.S,
)

# Make max content go through the direct context path, not the generic agentctl/meta path.
text = text.replace(
    'if argv and argv[0] in {"context"}:',
    'if argv and argv[0] in {"context", "content"}:',
)
text = text.replace(
    "if argv and argv[0] in {'context'}:",
    "if argv and argv[0] in {'context', 'content'}:",
)

# Ensure the command table still documents content as a context alias.
text = re.sub(
    r'("context": \{\n\s*"aliases": )\[[^\]]*\]',
    r'\1["content"]',
    text,
    count=1,
)

# Keep v17 dashboard wording for run args.
text = text.replace(
    '("max run calc2.py", "Run a workspace file safely")',
    '("max run calc2.py [args]", "Run a workspace file safely")',
)
text = text.replace(
    'print(f"max run <file.py>")',
    'print(f"max run <file.py> [args]")',
)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/agent_harness/chat_actions.py")
text = p.read_text()

smart = '''def _smart_command(rest: list[str]) -> str:
    if not rest:
        return ""

    target = rest[0]

    if target.endswith(".py"):
        return "python3 " + " ".join(rest)

    if target.endswith(".sh"):
        return "bash " + " ".join(rest)

    return " ".join(rest)

'''
text = re.sub(
    r'def _smart_command\(rest: list\[str\]\) -> str:\n.*?\n(?=def _checkpoint_message)',
    smart,
    text,
    flags=re.S,
)

text = text.replace('if cmd in {"context"}:', 'if cmd in {"context", "content"}:')
text = text.replace("if cmd in {'context'}:", "if cmd in {'context', 'content'}:")

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/edit_flow.py")
text = p.read_text()

# v17 prompt rule: Python changes should include a useful test command.
needle = '- If no test command is needed, set test_command to "".\n'
replacement = (
    '- If creating or modifying a Python file, include a safe test_command whenever possible.\n'
    '- If the user requests a CLI, include a test_command that exercises the CLI, not only --help.\n'
    '- If no test command is needed, set test_command to "".\n'
)
if needle in text and "include a safe test_command whenever possible" not in text:
    text = text.replace(needle, replacement)

# v17 fallback: infer python3 firstfile.py when the model omits test_command.
if "No model test command was provided, so Max inferred:" not in text:
    old = '''    test_command = str(change.get("test_command") or "").strip()

    if run_test and test_command:
'''
    new = '''    test_command = str(change.get("test_command") or "").strip()

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
'''
    if old in text:
        text = text.replace(old, new)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/task_flow.py")
text = p.read_text()

old = '''    result = change_project(project, first_change, yes=False, dry_run=False, run_test=run_test)

    return {
'''
new = '''    result = change_project(project, first_change, yes=False, dry_run=False, run_test=run_test)

    print("")
    print("Run workspace files through Max from anywhere:")
    print("  max run calc2.py add 5 3")
    print("  max run calc2.py --help")
    print("")

    return {
'''
if old in text and "Run workspace files through Max from anywhere" not in text:
    text = text.replace(old, new)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/ux.py")
if p.exists():
    text = p.read_text()
    text = text.replace(
        'print(f"max run <file.py>")',
        'print(f"max run <file.py> [args]")',
    )
    p.write_text(text)
PY

# Remove the experimental v18 file so the codebase is back at the v17 checkpoint.
rm -f src/agent_harness/test_flow.py

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()
blocked = [
    "test_flow",
    "test_project(project",
    "test_from_cwd",
]
found = [item for item in blocked if item in text]
if found:
    raise SystemExit("ERROR: v18 leftovers remain in max_cli.py: " + ", ".join(found))
PY

python3 -m compileall src/agent_harness

echo ""
echo "v17 stable restore installed."
echo ""
echo "Now run:"
echo "  max content \"improve calculator add subtract tests\""
echo "  max context \"improve calculator add subtract tests\""
echo "  max run calc2.py add 5 3"
echo "  max do calc2.py subtract 10 4"
echo ""
echo "Note: max test is back to the original v17 integration self-test command, not the experimental v18 workspace test command."
