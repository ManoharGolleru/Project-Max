#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v10_workflow_polish.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v10_workflow_polish_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in max_cli.py chat_actions.py edit_flow.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

# Let `max projects` behave like `max files`.
text = text.replace(
    '"aliases": ["file", "tree"],',
    '"aliases": ["file", "tree", "projects", "list", "ls"],'
)

# Make backend subprocess cancellation clean.
old = '''def run_agentctl(args: list[str]) -> int:
    cmd = ["agentctl"] + args
    return subprocess.call(cmd)
'''
new = '''def run_agentctl(args: list[str]) -> int:
    cmd = ["agentctl"] + args
    try:
        return subprocess.call(cmd)
    except KeyboardInterrupt:
        print("")
        print("Max command cancelled.")
        return 130
'''
if old in text:
    text = text.replace(old, new)

# Unknown multi-word top-level input becomes a question.
old = '''    if canonical is None:
        return unknown(name)

    return dispatch(canonical, argv[1:])
'''
new = '''    if canonical is None:
        if len(argv) > 1:
            return dispatch("ask", [" ".join(argv)])
        return unknown(name)

    return dispatch(canonical, argv[1:])
'''
if old in text:
    text = text.replace(old, new)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/chat_actions.py")
text = p.read_text()

# In chat, after /change, offer suggested test command immediately.
text = text.replace(
    "        change_project(project, request)\n",
    "        change_project(project, request, run_test=True)\n"
)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/edit_flow.py")
text = p.read_text()

old = '''    print("Next useful commands:")
    print("  max diff")
    print("  max checkpoint -m \\"describe this change\\"")
    print("  max rollback")
'''
new = '''    print("Next useful commands:")
    print("  max diff                         or /diff inside chat")
    print("  max checkpoint -m \\"message\\"     or /checkpoint message")
    print("  max rollback                     or /rollback inside chat")
'''
if old in text:
    text = text.replace(old, new)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.10 workflow polish patch installed."
echo ""
echo "Test:"
echo "  max projects"
echo "  max what is in this project"
echo "  max start"
echo ""
echo "Inside chat:"
echo "  /change create a small hello3.py script that prints hello third time from Max"
echo "  /diff"
echo "  /checkpoint add hello3 script"
