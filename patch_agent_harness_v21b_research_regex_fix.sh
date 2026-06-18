#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v21b_research_regex_fix.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v21b_research_regex_fix_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in research_flow.py max_cli.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/research_flow.py")
text = p.read_text()

bad = """    for match in re.finditer(r'href=["\\\\']([^"\\\\']+)["\\\\']', raw_html):"""
good = """    for match in re.finditer(r"href=[\\"']([^\\"']+)[\\"']", raw_html):"""

if bad in text:
    text = text.replace(bad, good)
else:
    lines = []
    replaced = False
    for line in text.splitlines():
        if "for match in re.finditer" in line and "href=" in line and "raw_html" in line:
            lines.append(good)
            replaced = True
        else:
            lines.append(line)
    text = "\n".join(lines) + "\n"

    if not replaced:
        raise SystemExit("Could not find the broken re.finditer href line in research_flow.py")

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.21b research regex fix installed."
echo ""
echo "Now run:"
echo "  max config set allow_network true"
echo "  max research url https://example.com"
echo "  max research \"python argparse examples\" --limit 3"
echo "  max research history"
echo "  ls -lh test-project/workspace/research-notes"
