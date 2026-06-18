from __future__ import annotations

import argparse
import json
from pathlib import Path

from .command_runner import run_command
from .ask_model import ask_project
from .smart_ask import smart_ask_project
from .config import load_config, save_config
from .doctor import run_doctor
from .edit_flow import change_project, checkpoint_project, diff_project, rollback_project
from .file_tools import print_read, print_search, print_tree
from .long_context_test import run_long_context_test
from .local_answer import files_text, info_text
from .memory import append_command_history, show_memory, update_current_state
from .integration_test import run_self_test
from .model_test import run_model_test
from .ollama_client import chat, extract_message_text
from .ollama_control import unload_model
from .schemas import extract_json_object, validate_plan
from .sessions import print_session, print_sessions
from .util import APP_HOME, ensure_app_home, read_json, write_json
from .workspace import find_project, init_project
from .ux import chat_loop, open_vscode, print_dashboard, print_last, setup_vscode


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
    contexts = [4096, 8192]

    if args.include_16k:
        contexts.append(16384)

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
        "self": APP_HOME / "self_test_report.json",
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




def cmd_self_test(args: argparse.Namespace) -> None:
    run_self_test(
        with_model=args.with_model,
        with_long=args.with_long,
        clean=args.clean,
    )




def cmd_ask(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    prompt = " ".join(args.prompt).strip()

    if not prompt:
        print("ERROR: Missing prompt.")
        print("Example: agentctl ask test-project what is in this project?")
        return

    result = smart_ask_project(
        root,
        prompt,
        interactive=not args.json,
        no_run=args.no_run,
        force_model=False,
    )

    if args.json:
        print(json.dumps(result, indent=2))




def cmd_think(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    prompt = " ".join(args.prompt).strip()

    if not prompt:
        print("ERROR: Missing prompt.")
        print("Example: agentctl think test-project what should I do next?")
        return

    result = smart_ask_project(
        root,
        prompt,
        interactive=not args.json,
        no_run=args.no_run,
        force_model=True,
    )

    if args.json:
        print(json.dumps(result, indent=2))


def cmd_files(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print(files_text(root))


def cmd_info(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print(info_text(root))


def cmd_sessions(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print_sessions(root)


def cmd_session(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    print_session(root, session_id=args.session_id, tail=args.tail)




def cmd_change(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    prompt = " ".join(args.prompt).strip()

    if not prompt:
        print("ERROR: Missing change request.")
        print("Example: agentctl change test-project create a hello.py script")
        return

    result = change_project(
        root,
        prompt,
        yes=args.yes,
        dry_run=args.dry_run,
        run_test=args.run_test,
    )

    if args.json:
        print(json.dumps(result, indent=2))


def cmd_diff(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    result = diff_project(root)

    if args.json:
        print(json.dumps(result, indent=2))


def cmd_checkpoint(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    msg = args.message or "Max checkpoint"
    checkpoint_project(root, msg)


def cmd_rollback(args: argparse.Namespace) -> None:
    root = find_project(args.project_name)
    rollback_project(root, yes=args.yes)




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
    p.add_argument("--include-16k", action="store_true")
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
    p.add_argument("which", nargs="?", choices=["install", "doctor", "model", "long", "self"])
    p.add_argument("--tail", type=int, default=80)
    p.set_defaults(func=cmd_logs)


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



    p = sub.add_parser("self-test")
    p.add_argument("--with-model", action="store_true")
    p.add_argument("--with-long", action="store_true")
    p.add_argument("--clean", action="store_true")
    p.set_defaults(func=cmd_self_test)



    p = sub.add_parser("ask")
    p.add_argument("project_name")
    p.add_argument("--no-run", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("prompt", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_ask)


    p = sub.add_parser("think")
    p.add_argument("project_name")
    p.add_argument("--no-run", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("prompt", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_think)

    p = sub.add_parser("files")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_files)

    p = sub.add_parser("info")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_info)


    p = sub.add_parser("sessions")
    p.add_argument("project_name")
    p.set_defaults(func=cmd_sessions)

    p = sub.add_parser("session")
    p.add_argument("project_name")
    p.add_argument("session_id", nargs="?")
    p.add_argument("--tail", type=int, default=40)
    p.set_defaults(func=cmd_session)



    p = sub.add_parser("change")
    p.add_argument("project_name")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--run-test", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("prompt", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_change)

    p = sub.add_parser("diff")
    p.add_argument("project_name")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_diff)

    p = sub.add_parser("checkpoint")
    p.add_argument("project_name")
    p.add_argument("-m", "--message", default=None)
    p.set_defaults(func=cmd_checkpoint)

    p = sub.add_parser("rollback")
    p.add_argument("project_name")
    p.add_argument("--yes", action="store_true")
    p.set_defaults(func=cmd_rollback)



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


    p = sub.add_parser("benchmark")
    p.add_argument("--model", default=None)
    p.set_defaults(func=cmd_benchmark)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
