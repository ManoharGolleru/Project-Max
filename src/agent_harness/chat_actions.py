from __future__ import annotations

import json
import shlex
from pathlib import Path

from .command_runner import run_command
from .edit_flow import change_project, checkpoint_project, diff_project, rollback_project
from .file_tools import print_read, print_search, print_tree
from .index_tools import print_context as direct_print_context, print_index as direct_print_index
from .task_flow import fix_project, plan_project, task_project
from .local_answer import answer_local_and_log, files_text, local_answer, status_text
from .memory import append_command_history, update_current_state
from .project_commands import print_projects as pm_print_projects, resolve_project_ref as pm_resolve_project_ref, set_current_project as pm_set_current_project, register_project as pm_register_project
from .sessions import print_session, print_sessions
from .smart_ask import smart_ask_project
from .skill_manager import skills_command as max_skills_command


def _print_local(title: str, text: str) -> None:
    print("")
    print(f"Max [local: {title}]")
    print("=" * 72)
    print(text)
    print("")


def _usage() -> None:
    print("")
    print("Max did not call the model automatically.")
    print("")
    print("Useful options:")
    print('  /think what should I build next        slow model reasoning')
    print('  /change create hello.py               generate file changes with diff + approval')
    print('  /do python3 hello.py                  run a safe command')
    print('  /diff                                 show workspace changes')
    print('  /checkpoint add hello script          save a Git checkpoint')
    print("")
    print('You can also type the same commands with max, for example:')
    print('  max change "create a small hello.py script"')
    print("")


def _parse(text: str) -> list[str] | None:
    try:
        return shlex.split(text)
    except ValueError as e:
        print(f"Could not parse command: {e}")
        return None




def _smart_command(rest: list[str]) -> str:
    if not rest:
        return ""

    target = rest[0]

    if target.endswith(".py"):
        return "python3 " + " ".join(rest)

    if target.endswith(".sh"):
        return "bash " + " ".join(rest)

    return " ".join(rest)

def _checkpoint_message(parts: list[str]) -> str:
    if not parts:
        return "Max checkpoint"

    if parts[0] in {"-m", "--message"} and len(parts) > 1:
        return " ".join(parts[1:])

    return " ".join(parts)


def handle_chat_fallback(project: Path, line: str) -> None:
    raw = line.strip()

    if not raw:
        return

    local = local_answer(project, raw)
    if local is not None:
        answer_local_and_log(project, raw, local, interactive=True)
        return

    cmd_text = raw

    if cmd_text.startswith("max "):
        cmd_text = cmd_text[4:].strip()

    if cmd_text.startswith("/"):
        cmd_text = cmd_text[1:].strip()

    parts = _parse(cmd_text)
    if not parts:
        return

    cmd = parts[0].lower()
    rest = parts[1:]

    if cmd in {"projects", "project-list"}:
        pm_print_projects()
        return

    if cmd in {"project", "files", "file", "tree"}:
        _print_local("files", files_text(project))
        return

    if cmd in {"use", "switch", "select"}:
        if not rest:
            print("Usage: /use <project-name-or-path>")
            return

        p, err = pm_resolve_project_ref(rest[0])
        if err:
            print(err)
            return

        assert p is not None
        pm_set_current_project(p)
        pm_register_project(p)
        print(f"Current project set to: {p}")
        print("Exit and run `max start` again to open that project's chat.")
        return

    if cmd in {"tree", "folders"}:
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

    if cmd in {"status", "dashboard", "overview"}:
        _print_local("status", status_text(project))
        return

    if cmd in {"skills", "skill"}:
        max_skills_command(rest)
        return

    if cmd in {"sessions", "session-list"}:
        print_sessions(project)
        return

    if cmd in {"session", "show-session"}:
        session_id = rest[0] if rest else None
        print_session(project, session_id=session_id)
        return

    if cmd in {"think", "reason", "decide"}:
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

        command = _smart_command(rest)

        workspace = project / "workspace"
        result = run_command(
            command=command,
            cwd=workspace,
            workspace_root=workspace,
            reason="User asked Max to run something from chat.",
            ask=True,
        )
        append_command_history(project, result)
        update_current_state(project, f"Chat run result:\n\n{json.dumps(result, indent=2)}")
        print(json.dumps(result, indent=2))
        return

    if cmd in {"index"}:
        direct_print_index(project)
        return

    if cmd in {"context", "content"}:
        query = " ".join(rest).strip() or "project overview"
        direct_print_context(project, query)
        return

    if cmd in {"plan", "outline"}:
        prompt = " ".join(rest).strip()
        if not prompt:
            print("Usage: /plan <task>")
            return
        plan_project(project, prompt)
        return

    if cmd in {"task", "build", "work"}:
        prompt = " ".join(rest).strip()
        if not prompt:
            print("Usage: /task <task>")
            return
        task_project(project, prompt)
        return

    if cmd in {"fix", "repair"}:
        fix_project(project)
        return

    if cmd in {"change", "edit", "write", "modify", "patch"}:
        request = " ".join(rest).strip()
        if not request:
            print('Usage: /change create a small hello.py script')
            return

        change_project(project, request, run_test=True)
        return

    if cmd in {"diff", "changes"}:
        diff_project(project)
        return

    if cmd in {"checkpoint", "save", "commit"}:
        checkpoint_project(project, _checkpoint_message(rest))
        return

    if cmd in {"rollback", "undo", "revert"}:
        rollback_project(project)
        return

    if cmd in {"do", "safe", "safe-run", "cmd", "command"}:
        if not rest:
            print("Usage: /do <safe command>")
            return

        command = _smart_command(rest)
        workspace = project / "workspace"

        result = run_command(
            command=command,
            cwd=workspace,
            workspace_root=workspace,
            reason="User requested a safe command from chat.",
            ask=True,
        )

        append_command_history(project, result)
        update_current_state(project, f"Chat command result:\n\n{json.dumps(result, indent=2)}")
        print(json.dumps(result, indent=2))
        return

    if any(word in raw.lower() for word in ["build", "next", "plan", "fix", "create", "make"]):
        print("")
        print("Max did not call the model automatically.")
        print("")
        print("For advice/reasoning:")
        print(f"  /think {raw}")
        print("")
        print("For actual file changes:")
        print(f"  /change {raw}")
        print("")
        return

    _usage()
