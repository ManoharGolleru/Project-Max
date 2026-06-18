#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v02.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v02_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp src/agent_harness/cli.py "$BACKUP_DIR/cli.py.bak"
cp src/agent_harness/permissions.py "$BACKUP_DIR/permissions.py.bak"

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/permissions.py <<'EOF'
from __future__ import annotations

import shlex
from pathlib import Path


BLOCKED_PATTERNS = [
    "sudo",
    "su ",
    "rm -rf",
    "mkfs",
    "dd if=",
    ":(){",
    "chmod -R 777 /",
    "chmod -R 777",
    "chown -R",
    "shutdown",
    "reboot",
    "systemctl",
    "passwd",
    "usermod",
    "mount ",
    "umount ",
    "> /dev/",
    "$HOME",
    "${HOME}",
    "~",
]


READ_ONLY_COMMANDS = {
    "ls",
    "pwd",
    "find",
    "cat",
    "head",
    "tail",
    "wc",
    "du",
    "df",
    "tree",
    "grep",
    "rg",
    "sed",
    "awk",
    "git",
    "python",
    "python3",
}


def is_inside(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except Exception:
        return False


def is_dangerous(command: str) -> tuple[bool, str]:
    lowered = command.lower().strip()

    for pat in BLOCKED_PATTERNS:
        if pat in lowered:
            return True, f"Blocked dangerous pattern: {pat}"

    if "../" in command or "/.." in command:
        return True, "Blocked path traversal pattern: .."

    return False, ""


def tokenize_command(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except Exception:
        return command.split()


def command_name(command: str) -> str:
    tokens = tokenize_command(command)
    if not tokens:
        return ""
    return Path(tokens[0]).name


def validate_paths_in_command(command: str, workspace_root: Path) -> tuple[bool, str]:
    tokens = tokenize_command(command)
    workspace_root = workspace_root.resolve()

    for token in tokens:
        cleaned = token.strip().strip("'\"")

        if not cleaned:
            continue

        if cleaned.startswith("-"):
            continue

        if cleaned in {"|", ">", ">>", "<", "&&", "||", ";"}:
            continue

        # Absolute paths must stay inside the workspace.
        if cleaned.startswith("/"):
            p = Path(cleaned).resolve()
            if not is_inside(p, workspace_root):
                return False, f"Absolute path outside workspace is blocked: {cleaned}"

        # Home-relative paths are blocked for now.
        if cleaned.startswith("~/"):
            return False, f"Home-relative path is blocked: {cleaned}"

    return True, ""


def validate_command(command: str, cwd: Path, workspace_root: Path) -> tuple[bool, str]:
    cwd = cwd.resolve()
    workspace_root = workspace_root.resolve()

    if not is_inside(cwd, workspace_root):
        return False, "cwd outside workspace"

    dangerous, why = is_dangerous(command)
    if dangerous:
        return False, why

    paths_ok, path_reason = validate_paths_in_command(command, workspace_root)
    if not paths_ok:
        return False, path_reason

    return True, "ok"


def approval_prompt(command: str, cwd: Path, reason: str) -> bool:
    print("")
    print("The agent wants to run this command:")
    print(f"  {command}")
    print(f"Working directory: {cwd}")
    print(f"Reason: {reason}")
    print("")
    ans = input("Approve? [y/N/details]: ").strip().lower()

    if ans == "details":
        print("")
        print("v0.2 blocks obvious dangerous commands, blocks home paths,")
        print("blocks absolute paths outside the workspace, and blocks path traversal.")
        print("This is still not a full Docker sandbox yet.")
        print("")
        ans = input("Approve now? [y/N]: ").strip().lower()

    return ans in {"y", "yes"}
EOF

cat > src/agent_harness/command_runner.py <<'EOF'
from __future__ import annotations

import subprocess
import time
from pathlib import Path

from .permissions import approval_prompt, validate_command
from .util import now_ts


def run_command(
    command: str,
    cwd: Path,
    workspace_root: Path,
    reason: str,
    ask: bool = True,
) -> dict:
    cwd = cwd.resolve()
    workspace_root = workspace_root.resolve()

    valid, validation_reason = validate_command(command, cwd, workspace_root)

    if not valid:
        return {
            "ok": False,
            "blocked": True,
            "reason": validation_reason,
            "command": command,
            "cwd": str(cwd),
        }

    if ask and not approval_prompt(command, cwd, reason):
        return {
            "ok": False,
            "blocked": True,
            "reason": "user denied approval",
            "command": command,
            "cwd": str(cwd),
        }

    start = time.time()

    try:
        proc = subprocess.run(
            command,
            cwd=str(cwd),
            shell=True,
            text=True,
            capture_output=True,
            timeout=120,
        )

        duration = time.time() - start

        return {
            "ok": proc.returncode == 0,
            "blocked": False,
            "timestamp": now_ts(),
            "command": command,
            "cwd": str(cwd),
            "exit_code": proc.returncode,
            "duration_sec": round(duration, 3),
            "stdout": proc.stdout[-8000:],
            "stderr": proc.stderr[-8000:],
        }

    except subprocess.TimeoutExpired as e:
        duration = time.time() - start

        return {
            "ok": False,
            "blocked": False,
            "timestamp": now_ts(),
            "command": command,
            "cwd": str(cwd),
            "exit_code": None,
            "duration_sec": round(duration, 3),
            "stdout": (e.stdout or "")[-8000:] if isinstance(e.stdout, str) else "",
            "stderr": "Command timed out.",
        }
EOF

cat > src/agent_harness/long_context_test.py <<'EOF'
from __future__ import annotations

import time

from .config import load_config
from .ollama_client import chat, extract_message_text
from .schemas import extract_json_object
from .util import APP_HOME, ensure_app_home, meminfo_gb, now_ts, write_json


EXPECTED = {
    "alpha": "blue_harbor_17",
    "beta": "copper_bridge_42",
    "gamma": "violet_engine_93",
}


def make_document(num_ctx: int) -> str:
    # Rough token estimate. We use about 70 to 75 percent of context.
    # This is intentionally approximate because tokenization differs by model.
    target_chars = int(num_ctx * 2.8)
    base_line = (
        "FILLER LINE {i:05d}: This line is irrelevant project history. "
        "It discusses stale logs, previous plans, interface notes, and old test output. "
        "The model should ignore noise and recover the anchor facts only.\n"
    )

    lines = []
    i = 0
    while len("".join(lines)) < target_chars:
        lines.append(base_line.format(i=i))
        i += 1

    n = len(lines)
    lines.insert(max(1, n // 20), f"ANCHOR_ALPHA={EXPECTED['alpha']}\n")
    lines.insert(max(2, n // 2), f"ANCHOR_BETA={EXPECTED['beta']}\n")
    lines.insert(max(3, int(n * 0.90)), f"ANCHOR_GAMMA={EXPECTED['gamma']}\n")

    return "".join(lines)


def run_long_context_test(
    model: str | None = None,
    contexts: list[int] | None = None,
) -> dict:
    ensure_app_home()
    cfg = load_config()

    if model is None:
        model = cfg["model"]

    if contexts is None:
        contexts = [4096, 8192, 16384]

    results = []

    for ctx in contexts:
        document = make_document(ctx)

        prompt = f"""
You are testing long-context retrieval for a local agent system.

Read the document and return JSON only. No markdown.

Required JSON schema:
{{
  "alpha": "string",
  "beta": "string",
  "gamma": "string",
  "found_all": boolean,
  "summary": "string"
}}

You must recover the exact values for:
ANCHOR_ALPHA
ANCHOR_BETA
ANCHOR_GAMMA

DOCUMENT START
{document}
DOCUMENT END
"""

        before = meminfo_gb()
        t0 = time.time()

        item = {
            "timestamp": now_ts(),
            "model": model,
            "num_ctx": ctx,
            "document_chars": len(document),
            "ok": False,
            "json_valid": False,
            "found_all": False,
            "duration_sec": None,
            "error": "",
            "ram_available_before_gb": round(before.get("MemAvailable", 0), 2),
            "ram_available_after_gb": None,
            "swap_free_before_gb": round(before.get("SwapFree", 0), 2),
            "swap_free_after_gb": None,
            "raw_text_preview": "",
            "parsed": {},
        }

        try:
            resp = chat(
                model=model,
                num_ctx=ctx,
                temperature=0.0,
                messages=[
                    {"role": "system", "content": "Return valid JSON only. Do not include markdown."},
                    {"role": "user", "content": prompt},
                ],
            )

            text = extract_message_text(resp)
            item["raw_text_preview"] = text[:500]

            obj = extract_json_object(text)
            item["json_valid"] = True
            item["parsed"] = obj

            alpha_ok = obj.get("alpha") == EXPECTED["alpha"]
            beta_ok = obj.get("beta") == EXPECTED["beta"]
            gamma_ok = obj.get("gamma") == EXPECTED["gamma"]

            item["found_all"] = bool(alpha_ok and beta_ok and gamma_ok)
            item["ok"] = item["json_valid"] and item["found_all"]

        except Exception as e:
            item["error"] = str(e)

        after = meminfo_gb()

        item["duration_sec"] = round(time.time() - t0, 3)
        item["ram_available_after_gb"] = round(after.get("MemAvailable", 0), 2)
        item["swap_free_after_gb"] = round(after.get("SwapFree", 0), 2)

        results.append(item)

        print(
            f"context={ctx} "
            f"chars={item['document_chars']} "
            f"ok={item['ok']} "
            f"json_valid={item['json_valid']} "
            f"found_all={item['found_all']} "
            f"duration={item['duration_sec']}s "
            f"ram_before={item['ram_available_before_gb']}GB "
            f"ram_after={item['ram_available_after_gb']}GB"
        )

        if item["error"]:
            print(f"  error: {item['error']}")

        if item["json_valid"] and not item["found_all"]:
            print(f"  parsed: {item['parsed']}")

    report = {
        "model": model,
        "created_at": now_ts(),
        "expected": EXPECTED,
        "results": results,
    }

    write_json(APP_HOME / "long_context_test_report.json", report)
    print("")
    print(f"Report saved to: {APP_HOME / 'long_context_test_report.json'}")

    return report
EOF

cat > src/agent_harness/ollama_control.py <<'EOF'
from __future__ import annotations

import json
import shutil
import subprocess
import urllib.request

from .config import load_config


def unload_model(model: str | None = None) -> dict:
    cfg = load_config()

    if model is None:
        model = cfg["model"]

    result = {
        "model": model,
        "ok": False,
        "method": None,
        "stdout": "",
        "stderr": "",
        "error": "",
    }

    if shutil.which("ollama"):
        try:
            proc = subprocess.run(
                ["ollama", "stop", model],
                text=True,
                capture_output=True,
                timeout=60,
            )
            result["method"] = "ollama stop"
            result["stdout"] = proc.stdout
            result["stderr"] = proc.stderr

            if proc.returncode == 0:
                result["ok"] = True
                return result

        except Exception as e:
            result["error"] = str(e)

    # Fallback: ask Ollama API to unload with keep_alive=0.
    try:
        payload = {
            "model": model,
            "prompt": "",
            "stream": False,
            "keep_alive": 0,
        }

        data = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(
            "http://localhost:11434/api/generate",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8", errors="replace")

        result["method"] = "api keep_alive=0"
        result["stdout"] = body
        result["ok"] = True

    except Exception as e:
        result["error"] = str(e)

    return result
EOF

cat > src/agent_harness/cli.py <<'EOF'
from __future__ import annotations

import argparse
import json
from pathlib import Path

from .command_runner import run_command
from .config import load_config, save_config
from .doctor import run_doctor
from .long_context_test import run_long_context_test
from .memory import append_command_history, show_memory, update_current_state
from .model_test import run_model_test
from .ollama_client import chat, extract_message_text
from .ollama_control import unload_model
from .schemas import extract_json_object, validate_plan
from .util import APP_HOME, ensure_app_home, read_json, write_json
from .workspace import find_project, init_project


def cmd_doctor(args: argparse.Namespace) -> None:
    report = run_doctor(json_only=args.json)

    if args.json:
        print(json.dumps(report, indent=2))


def cmd_config(args: argparse.Namespace) -> None:
    cfg = load_config()

    if args.set_model:
        cfg["model"] = args.set_model
        save_config(cfg)
        print(f"Updated model: {args.set_model}")

    if args.set_context:
        cfg["default_context"] = args.set_context
        save_config(cfg)
        print(f"Updated default_context: {args.set_context}")

    if args.json:
        print(json.dumps(load_config(), indent=2))
    else:
        print("Current config:")
        print(json.dumps(load_config(), indent=2))


def cmd_model_test(args: argparse.Namespace) -> None:
    contexts = [4096, 8192, 16384]

    if args.include_32k:
        contexts.append(32768)

    run_model_test(model=args.model, contexts=contexts)


def cmd_long_context_test(args: argparse.Namespace) -> None:
    contexts = [4096, 8192, 16384]

    if args.include_32k:
        contexts.append(32768)

    run_long_context_test(model=args.model, contexts=contexts)


def cmd_unload_model(args: argparse.Namespace) -> None:
    result = unload_model(model=args.model)
    print(json.dumps(result, indent=2))


def cmd_init(args: argparse.Namespace) -> None:
    root = init_project(args.project_name)

    print(f"Project created: {root}")
    print(f"Workspace: {root / 'workspace'}")
    print(f"Memory: {root / '.agent'}")


def cmd_status(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)

    print(f"Project: {root}")

    for name in ["current_state.md", "plan.json", "open_issues.json", "completed_steps.json"]:
        p = root / ".agent" / name

        print("")
        print(f"--- {name} ---")

        if p.suffix == ".json":
            print(json.dumps(read_json(p, {}), indent=2)[:3000])
        else:
            print(p.read_text()[-3000:])


def cmd_memory(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    show_memory(root)


def cmd_run(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    workspace = root / "workspace"
    project_config = read_json(root / "agent.config.json", {})
    global_config = load_config()

    model = project_config.get("model") or global_config["model"]
    context = int(project_config.get("context") or global_config["default_context"])
    temperature = float(project_config.get("temperature") or global_config["temperature"])

    prompt = f"""
You are the planner/reviewer inside a local agent harness.

Return JSON only. No markdown.

The controller owns tools and memory. You do not run commands directly.
You propose a small safe next plan.

Schema:
{{
  "goal": "string",
  "steps": ["string"],
  "next_action": "string",
  "suggested_command": "string",
  "reason": "string"
}}

Rules:
- suggested_command must be read-only.
- suggested_command must be safe.
- suggested_command must work inside the workspace.
- Use relative paths only.
- Prefer commands like: ls -lh .
- Do not use absolute paths.
- Do not use sudo.
- Do not delete files.
- Do not install packages.

Current project:
{root}

Workspace:
{workspace}

Task:
Create a minimal first plan for inspecting this workspace.
Suggest only one safe read-only shell command using a relative path.
"""

    print(f"Calling model: {model}")
    print(f"Context: {context}")

    resp = chat(
        model=model,
        num_ctx=context,
        temperature=temperature,
        messages=[
            {"role": "system", "content": "Return valid JSON only."},
            {"role": "user", "content": prompt},
        ],
    )

    text = extract_message_text(resp)

    print("")
    print("Model response:")
    print(text)

    try:
        obj = extract_json_object(text)
    except Exception as e:
        print("")
        print(f"Invalid JSON from model: {e}")
        return

    errors = validate_plan(obj)

    if errors:
        print("")
        print("Plan validation errors:")

        for e in errors:
            print(f"- {e}")

        return

    write_json(root / ".agent" / "plan.json", obj)
    update_current_state(root, f"Model produced plan:\n\n{json.dumps(obj, indent=2)}")

    suggested = obj.get("suggested_command") or "ls -la ."
    reason = obj.get("reason") or "Inspect workspace."

    print("")
    print("The controller will ask before running the suggested command.")

    result = run_command(
        command=suggested,
        cwd=workspace,
        workspace_root=workspace,
        reason=reason,
        ask=True,
    )

    append_command_history(root, result)
    update_current_state(root, f"Command result:\n\n{json.dumps(result, indent=2)}")

    print("")
    print("Command result:")
    print(json.dumps(result, indent=2))
    print("")
    print(f"Memory updated in: {root / '.agent'}")


def cmd_inspect(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    workspace = root / "workspace"

    print("v0.2 inspect runs basic read-only checks.")

    for command in ["pwd", "find . -maxdepth 2 -type f | sort | head -50"]:
        result = run_command(
            command=command,
            cwd=workspace,
            workspace_root=workspace,
            reason="Basic workspace inspection.",
            ask=args.ask,
        )

        append_command_history(root, result)

        print("")
        print(json.dumps(result, indent=2))


def cmd_safe_run(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    workspace = root / "workspace"

    if not args.command:
        print("ERROR: Provide a command.")
        print("Example: agentctl safe-run test-project ls -lh .")
        return

    command = " ".join(args.command)

    result = run_command(
        command=command,
        cwd=workspace,
        workspace_root=workspace,
        reason=args.reason or "User requested safe-run.",
        ask=not args.yes,
    )

    append_command_history(root, result)
    update_current_state(root, f"safe-run result:\n\n{json.dumps(result, indent=2)}")

    print(json.dumps(result, indent=2))


def cmd_logs(args: argparse.Namespace) -> None:
    paths = {
        "install": APP_HOME / "logs" / "install.log",
        "doctor": APP_HOME / "doctor_report.json",
        "model": APP_HOME / "model_test_report.json",
        "long": APP_HOME / "long_context_test_report.json",
    }

    if args.which is None:
        print("Available logs/reports:")
        for name, path in paths.items():
            exists = "exists" if path.exists() else "missing"
            print(f"- {name}: {path} ({exists})")
        return

    path = paths.get(args.which)

    if path is None:
        print(f"Unknown log: {args.which}")
        return

    if not path.exists():
        print(f"Missing: {path}")
        return

    text = path.read_text(errors="replace")
    lines = text.splitlines()
    tail = lines[-args.tail :]
    print("\n".join(tail))


def cmd_benchmark(args: argparse.Namespace) -> None:
    print("Running v0.2 benchmark: doctor + model JSON test + long-context test.")
    print("")

    run_doctor(json_only=False)

    print("")
    run_model_test(model=args.model, contexts=[4096, 8192])

    print("")
    run_long_context_test(model=args.model, contexts=[4096, 8192])

    print("")
    print("Benchmark complete.")


def main() -> None:
    ensure_app_home()

    parser = argparse.ArgumentParser(prog="agentctl")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("doctor")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("config")
    p.add_argument("--json", action="store_true")
    p.add_argument("--set-model")
    p.add_argument("--set-context", type=int)
    p.set_defaults(func=cmd_config)

    p = sub.add_parser("model-test")
    p.add_argument("--model", default=None)
    p.add_argument("--include-32k", action="store_true")
    p.set_defaults(func=cmd_model_test)

    p = sub.add_parser("long-context-test")
    p.add_argument("--model", default=None)
    p.add_argument("--include-32k", action="store_true")
    p.set_defaults(func=cmd_long_context_test)

    p = sub.add_parser("unload-model")
    p.add_argument("--model", default=None)
    p.set_defaults(func=cmd_unload_model)

    p = sub.add_parser("init")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("status")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("memory")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_memory)

    p = sub.add_parser("run")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("inspect")
    p.add_argument("project_name")
    p.add_argument("--ask", action="store_true")
    p.set_defaults(func=cmd_inspect)

    p = sub.add_parser("safe-run")
    p.add_argument("project_name")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--reason", default=None)
    p.add_argument("command", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_safe_run)

    p = sub.add_parser("logs")
    p.add_argument("which", nargs="?", choices=["install", "doctor", "model", "long"])
    p.add_argument("--tail", type=int, default=80)
    p.set_defaults(func=cmd_logs)

    p = sub.add_parser("benchmark")
    p.add_argument("--model", default=None)
    p.set_defaults(func=cmd_benchmark)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
EOF

python3 -m compileall src/agent_harness

echo ""
echo "v0.2 patch installed."
echo ""
echo "Now run:"
echo "  agentctl doctor"
echo "  agentctl safe-run test-project ls -lh ."
echo "  agentctl safe-run test-project ls -lh /home/heavenlyemperor/Documents"
echo "  agentctl long-context-test"
echo ""
echo "The second safe-run should be blocked because it points outside the workspace."
