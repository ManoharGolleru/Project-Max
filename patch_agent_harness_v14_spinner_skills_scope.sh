#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v14_spinner_skills_scope.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v14_spinner_skills_scope_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

for f in model_progress.py max_cli.py chat_actions.py edit_flow.py ask_model.py; do
  if [ -f "src/agent_harness/$f" ]; then
    cp "src/agent_harness/$f" "$BACKUP_DIR/$f.bak"
  fi
done

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/model_progress.py <<'EOF'
from __future__ import annotations

import itertools
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


def response_metrics(resp: dict[str, Any], wall_sec: float) -> dict[str, Any]:
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


def metrics_text(m: dict[str, Any]) -> str:
    parts = [f"done in {m.get('wall_sec', 0):.1f}s"]

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

    return " | ".join(parts)


def print_metrics(m: dict[str, Any]) -> None:
    print("Model metrics: " + metrics_text(m))
    print("")


def _trim_line(text: str, width: int = 110) -> str:
    text = " ".join(str(text).split())
    if len(text) <= width:
        return text
    return text[: width - 3] + "..."


def chat_with_progress(
    *args: Any,
    task_label: str = "thinking",
    task_steps: list[str] | None = None,
    **kwargs: Any,
) -> dict[str, Any]:
    model = kwargs.get("model", "model")
    num_ctx = kwargs.get("num_ctx", "unknown")

    steps = task_steps or [
        "preparing context",
        "running local inference",
        "waiting for response",
        "checking output",
    ]

    start = time.perf_counter()
    stop = threading.Event()
    spinner = itertools.cycle(["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])

    is_tty = sys.stdout.isatty()

    print("")
    print(f"Max is {task_label}. Model={model} ctx={num_ctx}")
    print("Press Ctrl+C to cancel.")
    print("")

    def worker() -> None:
        i = 0
        while not stop.wait(0.2):
            elapsed = time.perf_counter() - start
            step = steps[min(int(elapsed // 20), len(steps) - 1)]
            line = f"{next(spinner)} {step} · {elapsed:.0f}s elapsed"
            line = _trim_line(line)

            if is_tty:
                sys.stdout.write("\r" + line + " " * max(0, 120 - len(line)))
                sys.stdout.flush()
            else:
                # Non-interactive logs should not be spammed.
                if i % 150 == 0:
                    print(line, flush=True)
                i += 1

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()

    try:
        resp = ollama_chat(*args, **kwargs)
    except KeyboardInterrupt:
        stop.set()
        thread.join(timeout=0.2)
        if is_tty:
            sys.stdout.write("\r" + " " * 120 + "\r")
            sys.stdout.flush()
        print("")
        print("Model call cancelled.")
        print("")
        raise
    finally:
        stop.set()

    thread.join(timeout=0.2)

    if is_tty:
        sys.stdout.write("\r" + " " * 120 + "\r")
        sys.stdout.flush()

    wall = time.perf_counter() - start
    metrics = response_metrics(resp if isinstance(resp, dict) else {}, wall)

    if isinstance(resp, dict):
        resp["_max_metrics"] = metrics

    print_metrics(metrics)

    return resp
EOF

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/edit_flow.py")
text = p.read_text()

# Reduce duplicate preamble.
text = text.replace(
'''    print("")
    print("Max is generating a file change with the model.")
    print("This is an important operation, so it may take a while on CPU.")
    print("")
''',
'''    print("")
    print("Max is preparing a change proposal.")
    print("")
'''
)

# Add scope-discipline wording into prompt if not already present.
needle = '''Rules:
- Use only relative paths inside the workspace.
- Do not use absolute paths.
'''
replacement = '''Rules:
- Follow the user's requested scope exactly.
- Do not add extra features, functions, files, dependencies, or behavior unless the user explicitly asked for them.
- If you think an extra feature would be useful, mention it in notes instead of implementing it.
- For example, if the user asks for add and subtract, do not implement multiply or divide.
- Use only relative paths inside the workspace.
- Do not use absolute paths.
'''
if needle in text and "Follow the user's requested scope exactly" not in text:
    text = text.replace(needle, replacement)

# Expand JSON schema to include skill_usage without making older responses fail.
old = '''  "test_command": "optional safe relative command, or empty string",
  "notes": "anything the user should know"
}
'''
new = '''  "test_command": "optional safe relative command, or empty string",
  "notes": "anything the user should know",
  "skill_usage": "briefly state which loaded skill guidance affected the proposal, or empty string"
}
'''
if old in text and "skill_usage" not in text:
    text = text.replace(old, new)

# Store selected skills and metrics in change object.
old = '''    obj = parse_change_response(text)
    obj["model_duration_sec"] = duration

    return obj
'''
new = '''    obj = parse_change_response(text)
    obj["model_duration_sec"] = duration
    obj["model_metrics"] = resp.get("_max_metrics", {}) if isinstance(resp, dict) else {}
    obj["selected_skills"] = selected_skills
    obj["skill_context_chars"] = len(skill_context or "")

    return obj
'''
if old in text:
    text = text.replace(old, new)

# Make parser tolerate skill_usage.
old = '''    obj.setdefault("test_command", "")
    obj.setdefault("notes", "")
'''
new = '''    obj.setdefault("test_command", "")
    obj.setdefault("notes", "")
    obj.setdefault("skill_usage", "")
    obj.setdefault("selected_skills", [])
'''
if old in text:
    text = text.replace(old, new)

# Show skills in proposal.
old = '''    print("")
    print("Files:")
'''
new = '''    selected_skills = change.get("selected_skills") or []
    if selected_skills:
        print("")
        print("Skills loaded:")
        print(", ".join(selected_skills))
    if change.get("skill_usage"):
        print("")
        print("Skill usage:")
        print(change["skill_usage"])

    print("")
    print("Files:")
'''
if old in text and "Skills loaded:" not in text:
    text = text.replace(old, new)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/max_cli.py")
text = p.read_text()

# Remove think/plan aliases from run if present so max think does not become agentctl run.
text = text.replace(
    '"aliases": ["think", "plan"],',
    '"aliases": ["next"],',
)

# Add explicit ask/think if missing.
if '"think": {' not in text:
    anchor = '''    "start": {
        "aliases": ["chat", "talk", "open-session", "session"],
        "summary": "Start the interactive Max session.",
        "usage": "max start [project]",
        "agentctl": ["chat"],
        "needs_project": True,
    },
'''
    addition = '''    "ask": {
        "aliases": ["question", "tell", "explain"],
        "summary": "Ask Max a project-aware question.",
        "usage": "max ask <question>",
        "agentctl": ["ask"],
        "needs_project": True,
        "remainder": True,
    },
    "think": {
        "aliases": ["reason", "decide"],
        "summary": "Force a model call for reasoning. Does not run commands automatically.",
        "usage": "max think <question>",
        "agentctl": ["think"],
        "needs_project": True,
        "remainder": True,
    },
'''
    text = text.replace(anchor, anchor + addition)

# Add direct handling for ask/think to avoid argparse REMAINDER issues and old run alias issues.
if "def cmd_direct_ask(args: list[str], force_model: bool)" not in text:
    helper = r'''

def direct_project_prompt(args: list[str]) -> tuple[Path | None, list[str]]:
    project_text, rest = project_from_args(args)
    if project_text is None:
        return None, args
    return Path(project_text), rest


def cmd_direct_ask(args: list[str], force_model: bool) -> int:
    from .smart_ask import smart_ask_project

    project, rest = direct_project_prompt(args)

    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2

    prompt = " ".join(rest).strip()
    if not prompt:
        ui.fail("Missing question.")
        print('Use: max think "your question"')
        return 2

    smart_ask_project(
        project,
        prompt,
        interactive=True,
        no_run=force_model,
        force_model=force_model,
    )

    return 0

'''
    text = text.replace("def dispatch(canonical: str, args: list[str]) -> int:", helper + "\ndef dispatch(canonical: str, args: list[str]) -> int:")

old = '''    if canonical == "use":
        return cmd_use(args)

    meta = COMMANDS[canonical]
'''
new = '''    if canonical == "use":
        return cmd_use(args)

    if canonical == "ask":
        return cmd_direct_ask(args, force_model=False)

    if canonical == "think":
        return cmd_direct_ask(args, force_model=True)

    meta = COMMANDS[canonical]
'''
if old in text and "cmd_direct_ask(args, force_model=True)" not in text:
    text = text.replace(old, new)

p.write_text(text)
PY

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/chat_actions.py")
text = p.read_text()

if "from .smart_ask import smart_ask_project" not in text:
    text = text.replace(
        "from .sessions import print_session, print_sessions\n",
        "from .sessions import print_session, print_sessions\nfrom .smart_ask import smart_ask_project\n",
    )

# Add think/ask/run handling before change handler.
anchor = '''    if cmd in {"change", "edit", "write", "modify", "patch"}:
        request = " ".join(rest).strip()
'''
handlers = '''    if cmd in {"think", "reason", "decide"}:
        prompt = " ".join(rest).strip()
        if not prompt:
            print("Usage: /think <question>")
            return
        smart_ask_project(project, prompt, interactive=True, no_run=True, force_model=True)
        return

    if cmd in {"ask", "question"}:
        prompt = " ".join(rest).strip()
        if not prompt:
            print("Usage: /ask <question>")
            return
        smart_ask_project(project, prompt, interactive=True, no_run=False, force_model=False)
        return

    if cmd == "run":
        if not rest:
            print("Usage: /run <file.py> or /do <command>")
            return

        # Layman shortcut: run calculator.py -> python3 calculator.py
        if len(rest) == 1 and rest[0].endswith(".py"):
            command = "python3 " + rest[0]
        else:
            command = " ".join(rest)

        workspace = project / "workspace"
        result = run_command(
            command=command,
            cwd=workspace,
            workspace_root=workspace,
            reason="User asked Max to run something from chat.",
            ask=True,
        )
        append_command_history(project, result)
        update_current_state(project, f"Chat run result:\\n\\n{json.dumps(result, indent=2)}")
        print(json.dumps(result, indent=2))
        return

'''
if handlers.strip() not in text:
    text = text.replace(anchor, handlers + anchor)

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.14 spinner + skills scope patch installed."
echo ""
echo "Test:"
echo "  max think \"what is your opinion on AI?\""
echo "  max change \"create a small calc2.py script with add and subtract and a simple self-test\""
echo ""
echo "Inside chat:"
echo "  max think \"what is your opinion on AI?\""
echo "  run calculator.py"
echo "  max run calculator.py"
