#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v03_ux.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v03_ux_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp src/agent_harness/cli.py "$BACKUP_DIR/cli.py.bak"

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/ux.py <<'EOF'
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from .command_runner import run_command
from .doctor import run_doctor
from .long_context_test import run_long_context_test
from .memory import append_command_history, show_memory, update_current_state
from .ollama_control import unload_model
from .util import APP_HOME, read_json, write_json


def _short(text: str, limit: int = 1400) -> str:
    text = text or ""
    if len(text) <= limit:
        return text
    return text[-limit:]


def _count_commands(project: Path) -> int:
    data = read_json(project / ".agent" / "command_history.json", {"commands": []})
    return len(data.get("commands", []))


def _last_command(project: Path) -> dict | None:
    data = read_json(project / ".agent" / "command_history.json", {"commands": []})
    commands = data.get("commands", [])
    if not commands:
        return None
    return commands[-1]


def print_dashboard(project: Path) -> None:
    agent = project / ".agent"
    workspace = project / "workspace"
    project_config = read_json(project / "agent.config.json", {})

    plan = read_json(agent / "plan.json", {})
    open_issues = read_json(agent / "open_issues.json", {"issues": []})
    completed = read_json(agent / "completed_steps.json", {"steps": []})
    last_cmd = _last_command(project)

    print("")
    print("agent-harness dashboard")
    print("=" * 72)
    print(f"Project:   {project}")
    print(f"Workspace: {workspace}")
    print(f"Memory:    {agent}")
    print("")
    print("Config")
    print("-" * 72)
    print(f"Model:       {project_config.get('model', 'not set')}")
    print(f"Context:     {project_config.get('context', 'not set')}")
    print(f"RAM limit:   {project_config.get('ram_limit_gb', 'not set')} GB")
    print(f"Approval:    {project_config.get('approval_mode', 'not set')}")
    print("")
    print("State")
    print("-" * 72)
    print(f"Plan goal:        {plan.get('goal', 'none')}")
    print(f"Plan steps:       {len(plan.get('steps', []))}")
    print(f"Open issues:      {len(open_issues.get('issues', []))}")
    print(f"Completed steps:  {len(completed.get('steps', []))}")
    print(f"Commands run:     {_count_commands(project)}")
    print("")

    if last_cmd:
        print("Last command")
        print("-" * 72)
        print(f"Command:   {last_cmd.get('command')}")
        print(f"OK:        {last_cmd.get('ok')}")
        print(f"Blocked:   {last_cmd.get('blocked')}")
        print(f"Exit code: {last_cmd.get('exit_code')}")
        print(f"Time:      {last_cmd.get('timestamp', '')}")
        stdout = last_cmd.get("stdout") or ""
        stderr = last_cmd.get("stderr") or ""
        if stdout:
            print("")
            print("stdout")
            print(_short(stdout))
        if stderr:
            print("")
            print("stderr")
            print(_short(stderr))

    print("")
    print("Useful commands")
    print("-" * 72)
    print(f"agentctl chat {project}")
    print(f"agentctl run {project}")
    print(f"agentctl inspect {project}")
    print(f"agentctl last {project}")
    print(f"agentctl setup-vscode {project}")
    print(f"agentctl open {project}")
    print("")


def setup_vscode(project: Path) -> None:
    vscode = project / ".vscode"
    vscode.mkdir(parents=True, exist_ok=True)

    tasks = {
        "version": "2.0.0",
        "tasks": [
            {
                "label": "agent: dashboard",
                "type": "shell",
                "command": "agentctl dashboard \"${workspaceFolder}\"",
                "problemMatcher": [],
            },
            {
                "label": "agent: run",
                "type": "shell",
                "command": "agentctl run \"${workspaceFolder}\"",
                "problemMatcher": [],
            },
            {
                "label": "agent: inspect",
                "type": "shell",
                "command": "agentctl inspect \"${workspaceFolder}\"",
                "problemMatcher": [],
            },
            {
                "label": "agent: model test",
                "type": "shell",
                "command": "agentctl model-test",
                "problemMatcher": [],
            },
            {
                "label": "agent: long context test",
                "type": "shell",
                "command": "agentctl long-context-test",
                "problemMatcher": [],
            },
        ],
    }

    settings = {
        "files.exclude": {
            "**/__pycache__": True,
            "**/.pytest_cache": True,
        },
        "terminal.integrated.defaultProfile.linux": "bash",
    }

    extensions = {
        "recommendations": [
            "ms-python.python",
            "ms-vscode.vscode-json",
        ]
    }

    write_json(vscode / "tasks.json", tasks)
    write_json(vscode / "settings.json", settings)
    write_json(vscode / "extensions.json", extensions)

    agent_md = project / "AGENT.md"
    if not agent_md.exists():
        agent_md.write_text(
            "# Agent workspace\n\n"
            "This folder is managed by agent-harness.\n\n"
            "Important folders:\n\n"
            "- `workspace/`: files the agent is allowed to inspect and work inside.\n"
            "- `.agent/`: structured memory, command history, plans, and logs.\n\n"
            "Useful terminal commands:\n\n"
            "```bash\n"
            "agentctl dashboard .\n"
            "agentctl chat .\n"
            "agentctl run .\n"
            "agentctl inspect .\n"
            "agentctl last .\n"
            "```\n"
        )

    print(f"VS Code files created in: {vscode}")
    print(f"Agent notes created at: {agent_md}")


def open_vscode(project: Path) -> None:
    if not shutil.which("code"):
        print("VS Code command `code` was not found in PATH.")
        print("")
        print("Open VS Code manually, then use:")
        print(f"  File -> Open Folder -> {project}")
        print("")
        print("Inside VS Code, you can open the command palette and install the `code` shell command if available.")
        return

    print(f"Opening VS Code: {project}")
    subprocess.run(["code", str(project)], check=False)


def print_last(project: Path, limit: int = 3) -> None:
    data = read_json(project / ".agent" / "command_history.json", {"commands": []})
    commands = data.get("commands", [])

    if not commands:
        print("No command history yet.")
        return

    print(f"Last {min(limit, len(commands))} command(s)")
    print("=" * 72)

    for item in commands[-limit:]:
        print("")
        print(f"Time:    {item.get('timestamp', '')}")
        print(f"Command: {item.get('command')}")
        print(f"OK:      {item.get('ok')}")
        print(f"Blocked: {item.get('blocked')}")
        print(f"Reason:  {item.get('reason', '')}")
        print(f"Exit:    {item.get('exit_code', '')}")

        stdout = item.get("stdout") or ""
        stderr = item.get("stderr") or ""

        if stdout:
            print("")
            print("stdout")
            print(_short(stdout, 1200))

        if stderr:
            print("")
            print("stderr")
            print(_short(stderr, 1200))


def chat_loop(project: Path) -> None:
    workspace = project / "workspace"

    print("")
    print("agent-harness interactive session")
    print("=" * 72)
    print(f"Project: {project}")
    print("")
    print("Type /help for commands. Type /exit to leave.")
    print("")

    while True:
        try:
            line = input("agent> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("")
            print("Exiting.")
            return

        if not line:
            continue

        if line in {"/exit", "/quit", "exit", "quit"}:
            print("Exiting.")
            return

        if line == "/help":
            print("")
            print("Commands")
            print("-" * 72)
            print("/dashboard              Show project dashboard")
            print("/status                 Show current state and plan")
            print("/memory                 List .agent memory files")
            print("/run                    Ask model for next safe plan and command")
            print("/inspect                Run basic read-only inspection")
            print("/safe <command>         Run a command through safety checks")
            print("/long                   Run 4K/8K long-context test")
            print("/doctor                 Run machine checks")
            print("/unload                 Unload current Ollama model")
            print("/open                   Open project in VS Code")
            print("/last                   Show recent command history")
            print("/exit                   Leave interactive session")
            print("")
            continue

        if line == "/dashboard":
            print_dashboard(project)
            continue

        if line == "/status":
            current_state = project / ".agent" / "current_state.md"
            plan = read_json(project / ".agent" / "plan.json", {})
            print("")
            print("--- current_state.md ---")
            print(_short(current_state.read_text() if current_state.exists() else ""))
            print("")
            print("--- plan.json ---")
            print(json.dumps(plan, indent=2))
            continue

        if line == "/memory":
            show_memory(project)
            continue

        if line == "/doctor":
            run_doctor(json_only=False)
            continue

        if line == "/inspect":
            for command in ["pwd", "find . -maxdepth 2 -type f | sort | head -50"]:
                result = run_command(
                    command=command,
                    cwd=workspace,
                    workspace_root=workspace,
                    reason="Interactive inspection.",
                    ask=False,
                )
                append_command_history(project, result)
                print(json.dumps(result, indent=2))
            continue

        if line.startswith("/safe "):
            command = line[len("/safe ") :].strip()
            if not command:
                print("Usage: /safe <command>")
                continue

            result = run_command(
                command=command,
                cwd=workspace,
                workspace_root=workspace,
                reason="Interactive safe command.",
                ask=True,
            )
            append_command_history(project, result)
            update_current_state(project, f"interactive safe result:\n\n{json.dumps(result, indent=2)}")
            print(json.dumps(result, indent=2))
            continue

        if line == "/long":
            run_long_context_test(model=None, contexts=[4096, 8192])
            continue

        if line == "/unload":
            result = unload_model(model=None)
            print(json.dumps(result, indent=2))
            continue

        if line == "/open":
            open_vscode(project)
            continue

        if line == "/last":
            print_last(project)
            continue

        if line == "/run":
            print("Leave chat with /exit, then run:")
            print(f"  agentctl run {project}")
            print("")
            print("I am keeping /run external in v0.3 so the main model loop stays simple and debuggable.")
            continue

        print("Unknown command. Type /help.")
EOF

python3 - <<'PY'
from pathlib import Path

p = Path("src/agent_harness/cli.py")
text = p.read_text()

import_line = "from .ux import chat_loop, open_vscode, print_dashboard, print_last, setup_vscode\n"

if import_line not in text:
    marker = "from .workspace import find_project, init_project\n"
    text = text.replace(marker, marker + import_line)

functions = r'''

def cmd_dashboard(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print_dashboard(root)


def cmd_setup_vscode(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    setup_vscode(root)


def cmd_open(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    open_vscode(root)


def cmd_last(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print_last(root, limit=args.limit)


def cmd_chat(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    chat_loop(root)

'''

if "def cmd_dashboard(args: argparse.Namespace)" not in text:
    text = text.replace("def cmd_benchmark(args: argparse.Namespace) -> None:", functions + "\ndef cmd_benchmark(args: argparse.Namespace) -> None:")

parser_entries = r'''
    p = sub.add_parser("dashboard")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_dashboard)

    p = sub.add_parser("setup-vscode")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_setup_vscode)

    p = sub.add_parser("open")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_open)

    p = sub.add_parser("last")
    p.add_argument("project_name")
    p.add_argument("--limit", type=int, default=3)
    p.set_defaults(func=cmd_last)

    p = sub.add_parser("chat")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_chat)

'''

if 'sub.add_parser("dashboard")' not in text:
    text = text.replace('    p = sub.add_parser("benchmark")\n', parser_entries + '\n    p = sub.add_parser("benchmark")\n')

p.write_text(text)
PY

python3 -m compileall src/agent_harness

echo ""
echo "v0.3 UX patch installed."
echo ""
echo "Try:"
echo "  agentctl dashboard test-project"
echo "  agentctl setup-vscode test-project"
echo "  agentctl open test-project"
echo "  agentctl chat test-project"
echo "  agentctl last test-project"
