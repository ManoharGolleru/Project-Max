#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v12_files_progress.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v12_files_progress_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in cli.py max_cli.py chat_actions.py ask_model.py edit_flow.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/model_progress.py <<'EOF'
from __future__ import annotations

import sys
import threading
import time
from typing import Any

from .ollama_client import chat as ollama_chat


def _duration_ns_to_sec(value: Any) -> float:
    try:
        return float(value) / 1_000_000_000
    except Exception:
        return 0.0


def _metrics(resp: dict[str, Any], wall_sec: float) -> dict[str, Any]:
    prompt_count = int(resp.get("prompt_eval_count") or 0)
    eval_count = int(resp.get("eval_count") or 0)

    prompt_sec = _duration_ns_to_sec(resp.get("prompt_eval_duration"))
    eval_sec = _duration_ns_to_sec(resp.get("eval_duration"))
    total_sec = _duration_ns_to_sec(resp.get("total_duration")) or wall_sec

    prompt_tps = round(prompt_count / prompt_sec, 2) if prompt_count and prompt_sec > 0 else None
    eval_tps = round(eval_count / eval_sec, 2) if eval_count and eval_sec > 0 else None

    return {
        "wall_sec": round(wall_sec, 3),
        "total_sec": round(total_sec, 3),
        "prompt_tokens": prompt_count,
        "output_tokens": eval_count,
        "prompt_tok_per_sec": prompt_tps,
        "output_tok_per_sec": eval_tps,
    }


def _print_metrics(m: dict[str, Any]) -> None:
    parts = [f"done in {m['wall_sec']:.1f}s"]

    if m.get("prompt_tokens"):
        p = f"prompt {m['prompt_tokens']} tok"
        if m.get("prompt_tok_per_sec") is not None:
            p += f" @ {m['prompt_tok_per_sec']} tok/s"
        parts.append(p)

    if m.get("output_tokens"):
        o = f"output {m['output_tokens']} tok"
        if m.get("output_tok_per_sec") is not None:
            o += f" @ {m['output_tok_per_sec']} tok/s"
        parts.append(o)

    print("Model metrics: " + " | ".join(parts))
    print("")


def chat_with_progress(*args: Any, **kwargs: Any) -> dict[str, Any]:
    model = kwargs.get("model", "model")
    num_ctx = kwargs.get("num_ctx", "unknown")

    phases = [
        "preparing project context",
        "asking the local model",
        "waiting for structured JSON",
        "still generating on CPU",
        "checking the response",
    ]

    start = time.perf_counter()
    stop = threading.Event()

    print("")
    print(f"Max is using the model: {model}")
    print(f"Context window: {num_ctx}")
    print("This can take a while on CPU.")
    print("")

    def worker() -> None:
        i = 0
        while not stop.wait(8):
            elapsed = time.perf_counter() - start
            phase = phases[i % len(phases)]
            print(f"  ... {phase} ({elapsed:.0f}s elapsed)", flush=True)
            i += 1

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()

    try:
        resp = ollama_chat(*args, **kwargs)
    except KeyboardInterrupt:
        stop.set()
        thread.join(timeout=0.2)
        print("")
        print("Model call cancelled.")
        print("")
        raise
    finally:
        stop.set()

    thread.join(timeout=0.2)

    wall = time.perf_counter() - start
    m = _metrics(resp if isinstance(resp, dict) else {}, wall)

    if isinstance(resp, dict):
        resp["_max_metrics"] = m

    _print_metrics(m)

    return resp
EOF

cat > src/agent_harness/file_tools.py <<'EOF'
from __future__ import annotations

from pathlib import Path


TEXT_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".json", ".md", ".txt", ".html", ".css",
    ".scss", ".yml", ".yaml", ".toml", ".sh", ".csv", ".xml", ".env", ".gitignore",
}


def workspace(project: Path) -> Path:
    return project / "workspace"


def _safe_rel(path_text: str) -> tuple[bool, str]:
    if not path_text or not path_text.strip():
        return False, "empty path"

    p = Path(path_text)

    if p.is_absolute():
        return False, f"absolute paths are blocked: {path_text}"

    if ".." in p.parts:
        return False, f"path traversal is blocked: {path_text}"

    if str(path_text).startswith("~"):
        return False, f"home-relative paths are blocked: {path_text}"

    if any(part in {".git", ".agent", "node_modules", "__pycache__", ".venv"} for part in p.parts):
        return False, f"protected folder is blocked: {path_text}"

    return True, "ok"


def _is_text(path: Path) -> bool:
    if path.name == ".gitignore":
        return True
    return path.suffix.lower() in TEXT_EXTS


def _skip(rel: Path) -> bool:
    return any(part in {".git", ".agent", "node_modules", "__pycache__", ".venv"} for part in rel.parts)


def tree_text(project: Path, max_depth: int = 4, max_items: int = 250) -> str:
    root = workspace(project)

    if not root.exists():
        return f"Workspace does not exist:\n{root}"

    rows: list[str] = []
    count = 0

    rows.append(f"{root}/")

    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root)

        if _skip(rel):
            continue

        depth = len(rel.parts)

        if depth > max_depth:
            continue

        indent = "  " * depth
        suffix = "/" if p.is_dir() else ""

        rows.append(f"{indent}{p.name}{suffix}")
        count += 1

        if count >= max_items:
            rows.append(f"... stopped after {max_items} item(s)")
            break

    if len(rows) == 1:
        return f"The workspace is empty.\n\nWorkspace:\n{root}"

    return "\n".join(rows)


def read_text_file(project: Path, path_text: str, max_chars: int = 20000) -> str:
    ok, why = _safe_rel(path_text)

    if not ok:
        return f"Blocked: {why}"

    root = workspace(project)
    target = (root / path_text).resolve()

    try:
        target.relative_to(root.resolve())
    except Exception:
        return f"Blocked: path escapes workspace: {path_text}"

    if not target.exists():
        return f"File not found: {path_text}"

    if target.is_dir():
        return f"That path is a folder, not a file: {path_text}"

    if not _is_text(target):
        return f"Unsupported or likely binary file type: {path_text}"

    text = target.read_text(errors="replace")

    truncated = ""
    if len(text) > max_chars:
        text = text[:max_chars]
        truncated = f"\n\n[truncated after {max_chars} characters]"

    return f"--- {path_text} ---\n{text}{truncated}"


def search_text(project: Path, term: str, max_matches: int = 80) -> str:
    term = term.strip()

    if not term:
        return "Search term is empty."

    root = workspace(project)

    if not root.exists():
        return f"Workspace does not exist:\n{root}"

    matches: list[str] = []
    low_term = term.lower()

    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue

        rel = p.relative_to(root)

        if _skip(rel):
            continue

        if not _is_text(p):
            continue

        try:
            lines = p.read_text(errors="replace").splitlines()
        except Exception:
            continue

        for i, line in enumerate(lines, start=1):
            if low_term in line.lower():
                matches.append(f"{rel}:{i}: {line}")

                if len(matches) >= max_matches:
                    return "Matches:\n" + "\n".join(matches) + f"\n\n[stopped after {max_matches} match(es)]"

    if not matches:
        return f"No matches found for: {term}"

    return "Matches:\n" + "\n".join(matches)


def print_tree(project: Path, max_depth: int = 4) -> None:
    print("")
    print("Workspace tree")
    print("=" * 72)
    print(tree_text(project, max_depth=max_depth))
    print("")


def print_read(project: Path, path_text: str) -> None:
    print("")
    print("File")
    print("=" * 72)
    print(read_text_file(project, path_text))
    print("")


def print_search(project: Path, term: str) -> None:
    print("")
    print("Search")
    print("=" * 72)
    print(search_text(project, term))
    print("")
EOF

python3 - <<'PY'
from pathlib import Path

for name in ["ask_model.py", "edit_flow.py"]:
    p = Path("src/agent_harness") / name
    text = p.read_text()

    text = text.replace(
        "from .ollama_client import chat, extract_message_text",
        "from .model_progress import chat_with_progress as chat\nfrom .ollama_client import extract_message_text",
    )

    # edit_flow should cancel cleanly too.
    if name == "edit_flow.py":
        old = '''    try:
        change = request_change(project, user_request)
    except Exception as e:
        print(f"Change generation failed: {e}")
        return {"ok": False, "error": str(e)}
'''
        new = '''    try:
        change = request_change(project, user_request)
    except KeyboardInterrupt:
        print("")
        print("Change generation cancelled.")
        print("")
        return {"ok": False, "cancelled": True}
    except Exception as e:
        print(f"Change generation failed: {e}")
        return {"ok": False, "error": str(e)}
'''
        if old in text:
            text = text.replace(old, new)

    p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/cli.py")
text = p.read_text()

if "from .file_tools import print_read, print_search, print_tree" not in text:
    text = text.replace(
        "from .edit_flow import change_project, checkpoint_project, diff_project, rollback_project\n",
        "from .edit_flow import change_project, checkpoint_project, diff_project, rollback_project\n"
        "from .file_tools import print_read, print_search, print_tree\n",
    )

functions = r'''

def cmd_tree(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print_tree(root, max_depth=args.depth)


def cmd_read(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    path = " ".join(args.path).strip()
    if not path:
        print("ERROR: Missing file path.")
        print("Example: agentctl read test-project hello.py")
        return
    print_read(root, path)


def cmd_search(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    term = " ".join(args.term).strip()
    if not term:
        print("ERROR: Missing search term.")
        print("Example: agentctl search test-project hello")
        return
    print_search(root, term)

'''

if "def cmd_tree(args: argparse.Namespace)" not in text:
    text = text.replace("def cmd_benchmark(args: argparse.Namespace) -> None:", functions + "\ndef cmd_benchmark(args: argparse.Namespace) -> None:")

parser_entries = r'''
    p = sub.add_parser("tree")
    p.add_argument("project_name")
    p.add_argument("--depth", type=int, default=4)
    p.set_defaults(func=cmd_tree)

    p = sub.add_parser("read")
    p.add_argument("project_name")
    p.add_argument("path", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_read)

    p = sub.add_parser("search")
    p.add_argument("project_name")
    p.add_argument("term", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_search)

'''

if 'sub.add_parser("tree")' not in text:
    text = text.replace('    p = sub.add_parser("benchmark")\n', parser_entries + '\n    p = sub.add_parser("benchmark")\n')

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

# Improve project name resolution for commands like:
# max start test-project
# max status demo-project
# max open demo-project
old = '''def project_from_args(args: list[str]) -> tuple[str | None, list[str]]:
    if args:
        candidate = Path(args[0]).expanduser()
        if candidate.exists() and is_project(candidate.resolve()):
            return str(candidate.resolve()), args[1:]

    current = get_current_project()
    if current is not None:
        return str(current), args

    return None, args
'''
new = '''def project_from_args(args: list[str]) -> tuple[str | None, list[str]]:
    if args:
        p, err = pm_resolve_project_ref(args[0])
        if p is not None:
            return str(p), args[1:]

    current = get_current_project()
    if current is not None:
        return str(current), args

    return None, args
'''
if old in text:
    text = text.replace(old, new)

# Keep max files separate from max tree.
text = text.replace(
    '"aliases": ["file", "tree", "ls"],',
    '"aliases": ["file", "ls"],',
)

# Add current command if missing. where already has alias current, but this makes help cleaner.
if '"current": {' not in text:
    anchor = '''    "where": {
        "aliases": ["current", "project"],
        "summary": "Show the current selected project.",
        "usage": "max where",
        "agentctl": None,
        "needs_project": False,
    },
'''
    addition = '''    "current": {
        "aliases": [],
        "summary": "Show the current selected project.",
        "usage": "max current",
        "agentctl": None,
        "needs_project": False,
    },
'''
    text = text.replace(anchor, anchor + addition)

# Add file commands.
if '"tree": {' not in text:
    anchor = '''    "files": {
        "aliases": ["file", "ls"],
        "summary": "Show workspace files instantly without using the model.",
        "usage": "max files",
        "agentctl": ["files"],
        "needs_project": True,
    },
'''
    addition = '''    "tree": {
        "aliases": ["folders"],
        "summary": "Show a workspace tree.",
        "usage": "max tree [project]",
        "agentctl": ["tree"],
        "needs_project": True,
        "pass_args": True,
    },
    "read": {
        "aliases": ["cat", "show"],
        "summary": "Read a text file inside the workspace.",
        "usage": "max read <file>",
        "agentctl": ["read"],
        "needs_project": True,
        "remainder": True,
    },
    "search": {
        "aliases": ["grep", "find"],
        "summary": "Search text files inside the workspace.",
        "usage": "max search <term>",
        "agentctl": ["search"],
        "needs_project": True,
        "remainder": True,
    },
'''
    text = text.replace(anchor, anchor + addition)

# Dispatch current like where.
old = '''    if canonical == "where":
        return cmd_where()
'''
new = '''    if canonical == "where" or canonical == "current":
        return cmd_where()
'''
text = text.replace(old, new)

# Home rows.
if '("max tree", "Show workspace tree")' not in text:
    text = text.replace(
        '("max files", "Show workspace files instantly"),',
        '("max files", "Show workspace files instantly"),\n        ("max tree", "Show workspace tree"),\n        ("max read hello.py", "Read a workspace file"),\n        ("max search Max", "Search workspace files"),',
    )

# Help groups.
text = text.replace(
    '("Daily", ["start", "ask", "think", "files", "info", "status", "do", "run", "change", "diff", "checkpoint", "look", "open"]),',
    '("Daily", ["start", "ask", "think", "files", "tree", "read", "search", "info", "status", "do", "run", "change", "diff", "checkpoint", "look", "open"]),',
)

text = text.replace(
    '("Setup", ["projects", "new", "use", "where", "delete", "forget", "rename", "setup", "config"]),',
    '("Setup", ["projects", "new", "use", "where", "current", "delete", "forget", "rename", "setup", "config"]),',
)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/chat_actions.py")
text = p.read_text()

if "from .file_tools import print_read, print_search, print_tree" not in text:
    text = text.replace(
        "from .edit_flow import change_project, checkpoint_project, diff_project, rollback_project\n",
        "from .edit_flow import change_project, checkpoint_project, diff_project, rollback_project\n"
        "from .file_tools import print_read, print_search, print_tree\n",
    )

# Add file handlers before status block.
anchor = '''    if cmd in {"status", "dashboard", "overview"}:
        _print_local("status", status_text(project))
        return
'''
handlers = '''    if cmd in {"tree", "folders"}:
        print_tree(project)
        return

    if cmd in {"read", "cat", "show"}:
        if not rest:
            print("Usage: /read <file>")
            return
        print_read(project, " ".join(rest))
        return

    if cmd in {"search", "grep", "find"}:
        if not rest:
            print("Usage: /search <term>")
            return
        print_search(project, " ".join(rest))
        return

'''
if handlers.strip() not in text:
    text = text.replace(anchor, handlers + anchor)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/ux.py")
text = p.read_text()

# Add help lines for file tools if missing.
if 'print("/tree' not in text:
    text = text.replace(
        'print("/files                  Show workspace files instantly")',
        'print("/files                  Show workspace files instantly")\n            print("/tree                   Show workspace tree")\n            print("/read <file>            Read a workspace text file")\n            print("/search <term>          Search workspace text files")',
    )

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.12 files + project polish + model progress patch installed."
echo ""
echo "Test outside chat:"
echo "  max projects"
echo "  max start test-project"
echo "  max status test-project"
echo "  max open test-project"
echo "  max tree"
echo "  max read hello.py"
echo "  max search Max"
echo ""
echo "Test model feedback:"
echo "  max think \"what should I build next?\""
echo ""
echo "Inside chat:"
echo "  /tree"
echo "  /read hello.py"
echo "  /search Max"
echo "  /think what should I build next"
