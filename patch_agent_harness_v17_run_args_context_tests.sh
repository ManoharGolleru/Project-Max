#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v17_run_args_context_tests.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v17_run_args_context_tests_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py chat_actions.py edit_flow.py task_flow.py ux.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

# Make `max content ...` mean `max context ...`, not model ask.
if '"context": {' in text:
    text = text.replace(
        '"context": {\n        "aliases": [],',
        '"context": {\n        "aliases": ["content"],',
    )

# Fix run/do normalization:
# max run calc2.py add 5 3 -> python3 calc2.py add 5 3
old = '''def _normalize_safe_command_args(rest: list[str]) -> list[str]:
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
'''
new = '''def _normalize_safe_command_args(rest: list[str]) -> list[str]:
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
if old in text:
    text = text.replace(old, new)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/chat_actions.py")
text = p.read_text()

old = '''def _smart_command(rest: list[str]) -> str:
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
new = '''def _smart_command(rest: list[str]) -> str:
    if not rest:
        return ""

    target = rest[0]

    if target.endswith(".py"):
        return "python3 " + " ".join(rest)

    if target.endswith(".sh"):
        return "bash " + " ".join(rest)

    return " ".join(rest)
'''
if old in text:
    text = text.replace(old, new)

# Make `content` inside chat behave like context.
if 'cmd in {"context"}' in text:
    text = text.replace(
        'if cmd in {"context"}:',
        'if cmd in {"context", "content"}:',
    )

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/edit_flow.py")
text = p.read_text()

# Stronger prompt rule: if modifying/creating a Python file, include a test_command.
needle = '''- If no test command is needed, set test_command to "".
'''
replacement = '''- If creating or modifying a Python file, include a safe test_command whenever possible.
- If the user requests a CLI, include a test_command that exercises the CLI, not only --help.
- If no test command is needed, set test_command to "".
'''
if needle in text and "include a safe test_command whenever possible" not in text:
    text = text.replace(needle, replacement)

# Add a small fallback: if no test_command but a Python file changed, suggest python3 firstfile.py
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

# After task flow, remind user that commands run from workspace through max run.
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
text = p.read_text()

# Dashboard useful commands: make run examples clearer.
text = text.replace(
    'print(f"max run <file.py>")',
    'print(f"max run <file.py> [args]")',
)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.17 run args + context alias + test fallback installed."
echo ""
echo "Test:"
echo "  max content \"improve calculator add subtract tests\""
echo "  max context \"improve calculator add subtract tests\""
echo "  max run calc2.py add 5 3"
echo "  max do calc2.py subtract 10 4"
echo ""
echo "Inside chat:"
echo "  content improve calculator tests"
echo "  run calc2.py add 5 3"
echo "  max run calc2.py subtract 10 4"
