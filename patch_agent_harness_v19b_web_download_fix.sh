#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v19b_web_download_fix.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v19b_web_download_fix_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in web_flow.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/web_flow.py")
text = p.read_text()

old = '''def _record(
    op: str,
    result: dict[str, Any],
    saved_path: str | None = None,
) -> dict[str, Any]:
    return {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "op": op,
        "url": result.get("url"),
        "status": result.get("status"),
        "content_type": result.get("content_type"),
        "bytes": result.get("bytes", 0),
        "truncated": result.get("truncated", False),
        "duration_sec": result.get("duration_sec", 0),
        "saved_path": saved_path,
        "ok": bool(result.get("ok")),
        "error": result.get("error", ""),
    }
'''

new = '''def _record(
    op: str,
    result: dict[str, Any],
    saved_path: str | None = None,
    ok_override: bool | None = None,
    error_override: str | None = None,
) -> dict[str, Any]:
    ok = bool(result.get("ok")) if ok_override is None else bool(ok_override)
    error = str(result.get("error", "")) if error_override is None else error_override

    return {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "op": op,
        "url": result.get("url"),
        "status": result.get("status"),
        "content_type": result.get("content_type"),
        "bytes": result.get("bytes", 0),
        "truncated": result.get("truncated", False),
        "duration_sec": result.get("duration_sec", 0),
        "saved_path": saved_path,
        "ok": ok,
        "error": error,
    }
'''

if old not in text:
    raise SystemExit("Could not find _record() in web_flow.py")

text = text.replace(old, new)

old = '''    allowed, message = _check_download_allowed(config)
    if not allowed:
        print(message)
        _append_history(project, config, _record("save", result))
        return 1
'''

new = '''    allowed, message = _check_download_allowed(config)
    if not allowed:
        print(message)
        _append_history(
            project,
            config,
            _record("save", result, ok_override=False, error_override="Downloads disabled"),
        )
        print("")
        print("Current setting:")
        print(f"  allow_downloads = {config.get('allow_downloads', False)}")
        return 1
'''

if old not in text:
    raise SystemExit("Could not find download permission block in web_flow.py")

text = text.replace(old, new)

old = '''    saved_rel = out_path.relative_to(project).as_posix() if out_path.is_relative_to(project) else str(out_path)
'''

new = '''    try:
        saved_rel = out_path.relative_to(project).as_posix()
    except ValueError:
        saved_rel = str(out_path)
'''

if old in text:
    text = text.replace(old, new)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.19b web download/history fix installed."
echo ""
echo "Now run:"
echo "  max config set allow_downloads true"
echo "  max config get allow_downloads"
echo "  max web save https://google.com google.html"
echo "  max web history"
echo "  ls -lh test-project/workspace/downloads"
