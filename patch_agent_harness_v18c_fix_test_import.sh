#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v18c_fix_test_import.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v18c_fix_test_import_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp src/agent_harness/max_cli.py "$BACKUP_DIR/max_cli.py.bak"

echo "Backup saved to: $BACKUP_DIR"

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()
lines = text.splitlines()

bad_import = "from .test_flow import test_project, test_from_cwd"

# Remove the bad import wherever v18b inserted it.
lines = [line for line in lines if line.strip() != bad_import]

# Insert the import in a safe place:
# right after the last __future__ import if present.
insert_at = None
for i, line in enumerate(lines):
    if line.startswith("from __future__ import "):
        insert_at = i + 1

if insert_at is None:
    # Fallback: after shebang, encoding comment, and top comments.
    insert_at = 0
    while insert_at < len(lines):
        stripped = lines[insert_at].strip()
        if stripped.startswith("#!") or stripped.startswith("# -*-") or stripped.startswith("# coding"):
            insert_at += 1
            continue
        break

lines.insert(insert_at, bad_import)

p.write_text("\n".join(lines) + "\n")
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.18c import repair installed."
echo ""
echo "Now test:"
echo "  max test calc2.py add 5 6"
echo "  max test calc2.py subtract 10 4"
echo "  max test last"
echo "  max test history"
echo "  max test"
