from __future__ import annotations

import difflib
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

from .util import APP_HOME, ensure_app_home
from .index_tools import print_context as direct_print_context, print_index as direct_print_index
from .task_flow import fix_project as direct_fix_project, plan_project as direct_plan_project, task_project as direct_task_project
from .skill_manager import skills_command as max_skills_command
from .project_settings import config_project as direct_config_project
from .web_flow import web_project as direct_web_project
from .browser_flow import browser_project as direct_browser_project
from .research_flow import research_project as direct_research_project
from .notes_flow import notes_project as direct_notes_project
from .audit_flow import audit_project as direct_audit_project
from .workspace_flow import workspace_project as direct_workspace_project
from .test_flow import test_project as direct_test_project
from .project_commands import (
    delete_project as pm_delete_project,
    forget_project as pm_forget_project,
    print_projects as pm_print_projects,
    register_project as pm_register_project,
    rename_project as pm_rename_project,
    resolve_project_ref as pm_resolve_project_ref,
    set_current_project as pm_set_current_project,
)


CURRENT_PROJECT_FILE = APP_HOME / "current_project"


COMMANDS = {
    "new": {
        "aliases": ["init", "create", "make"],
        "summary": "Create a new Max project.",
        "usage": "max new <project-name>",
        "agentctl": ["init"],
        "needs_project": False,
    },
    "projects": {
        "aliases": ["list"],
        "summary": "List Max projects and show the current one.",
        "usage": "max projects",
        "agentctl": None,
        "needs_project": False,
    },
    "skills": {
        "aliases": ["skill"],
        "summary": "Install, list, search, and inspect agent skills.",
        "usage": "max skills [install|list|search|show]",
        "agentctl": None,
        "needs_project": False,
    },
    "delete": {
        "aliases": ["remove", "rm"],
        "summary": "Delete a Max project folder after confirmation.",
        "usage": "max delete <project-name-or-path>",
        "agentctl": None,
        "needs_project": False,
    },
    "forget": {
        "aliases": ["unregister"],
        "summary": "Forget a project from Max without deleting files.",
        "usage": "max forget <project-name-or-path>",
        "agentctl": None,
        "needs_project": False,
    },
    "rename": {
        "aliases": ["mv"],
        "summary": "Rename a Max project folder.",
        "usage": "max rename <project> <new-name>",
        "agentctl": None,
        "needs_project": False,
    },
    "use": {
        "aliases": ["select", "switch"],
        "summary": "Set the current project so you do not need to type it every time.",
        "usage": "max use <project-path>",
        "agentctl": None,
        "needs_project": False,
    },
    "where": {
        "aliases": ["current", "project"],
        "summary": "Show the current selected project.",
        "usage": "max where",
        "agentctl": None,
        "needs_project": False,
    },
    "current": {
        "aliases": [],
        "summary": "Show the current selected project.",
        "usage": "max current",
        "agentctl": None,
        "needs_project": False,
    },
    "start": {
        "aliases": ["chat", "talk", "open-session", "session"],
        "summary": "Start the interactive Max session.",
        "usage": "max start [project]",
        "agentctl": ["chat"],
        "needs_project": True,
    },
    "ask": {
        "aliases": ["question", "tell", "explain"],
        "summary": "Ask Max a project-aware question.",
        "usage": "max ask <question>",
        "agentctl": ["ask"],
        "needs_project": True,
        "remainder": True,
    },
    "think": {
        "aliases": ["reason", "decide", "plan-next"],
        "summary": "Force a model call for reasoning, planning, or decisions.",
        "usage": "max think <question>",
        "agentctl": ["think"],
        "needs_project": True,
        "remainder": True,
    },
    "files": {
        "aliases": ["file", "ls"],
        "summary": "Show workspace files instantly without using the model.",
        "usage": "max files",
        "agentctl": ["files"],
        "needs_project": True,
    },
    "tree": {
        "aliases": ["folders"],
        "summary": "Show a workspace tree.",
        "usage": "max tree [project]",
        "agentctl": ["tree"],
        "needs_project": True,
        "pass_args": True,
    },
    "workspace": {
        "aliases": ["where"],
        "summary": "Show workspace info, path, files, or tree.",
        "usage": "max workspace [path|files|tree]",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "shell": {
        "aliases": [],
        "summary": "Open a shell inside the active workspace.",
        "usage": "max shell",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "pwd": {
        "aliases": [],
        "summary": "Print the active workspace path.",
        "usage": "max pwd",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "cd": {
        "aliases": [],
        "summary": "Print a cd command for the active workspace.",
        "usage": "max cd",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "audit": {
        "aliases": ["timeline"],
        "summary": "Show a unified project activity timeline.",
        "usage": "max audit [list|search|show|paths|export]",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "notes": {
        "aliases": ["memory"],
        "summary": "Save project notes and simple file summaries.",
        "usage": "max notes [add|list|show|search|research|summarize|summaries]",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "research": {
        "aliases": ["lookup"],
        "summary": "Collect web sources into a markdown research note.",
        "usage": "max research [search|url|urls|history] <query-or-url>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "browser": {
        "aliases": ["chromium"],
        "summary": "Use a browser backend for rendered text and screenshots.",
        "usage": "max browser [check|text|screenshot|history] <url>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "web": {
        "aliases": ["internet", "url"],
        "summary": "Fetch, read, or save URLs using project permissions.",
        "usage": "max web [fetch|read|save|history] <url>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
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
    "info": {
        "aliases": ["about"],
        "summary": "Show project, model, memory, and path info instantly.",
        "usage": "max info",
        "agentctl": ["info"],
        "needs_project": True,
    },
    "sessions": {
        "aliases": ["session-list"],
        "summary": "List saved Max sessions.",
        "usage": "max sessions [project]",
        "agentctl": ["sessions"],
        "needs_project": True,
    },
    "session": {
        "aliases": ["show-session"],
        "summary": "Show latest or selected session transcript.",
        "usage": "max session [project] [session-id]",
        "agentctl": ["session"],
        "needs_project": True,
        "pass_args": True,
    },
    "status": {
        "aliases": ["dashboard", "home", "state", "overview"],
        "summary": "Show project dashboard.",
        "usage": "max status [project]",
        "agentctl": ["dashboard"],
        "needs_project": True,
    },
    "run": {
        "aliases": ["execute"],
        "summary": "Run a file or command safely inside the workspace.",
        "usage": "max run <file-or-command>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "next": {
        "aliases": ["plan-next"],
        "summary": "Ask Max to produce a safe next plan and suggested command.",
        "usage": "max next [project]",
        "agentctl": ["run"],
        "needs_project": True,
    },
    "change": {
        "aliases": ["edit", "write", "modify", "patch"],
        "summary": "Ask Max to propose file changes, show a diff, and apply after approval.",
        "usage": "max change <request>",
        "agentctl": ["change"],
        "needs_project": True,
        "remainder": True,
    },
    "plan": {
        "aliases": ["outline"],
        "summary": "Create a skill-guided implementation plan.",
        "usage": "max plan <task>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "task": {
        "aliases": ["build", "work"],
        "summary": "Plan a task, then offer the first patch.",
        "usage": "max task <task>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "fix": {
        "aliases": ["repair"],
        "summary": "Use the last failed command to propose a fix.",
        "usage": "max fix",
        "agentctl": None,
        "needs_project": True,
    },
    "index": {
        "aliases": [],
        "summary": "Build a workspace file index for smarter context.",
        "usage": "max index",
        "agentctl": None,
        "needs_project": True,
    },
    "context": {
        "aliases": ["content"],
        "summary": "Show files/context Max would use for a task.",
        "usage": "max context <task>",
        "agentctl": None,
        "needs_project": True,
        "remainder": True,
    },
    "diff": {
        "aliases": ["changes"],
        "summary": "Show workspace Git status and diff.",
        "usage": "max diff",
        "agentctl": ["diff"],
        "needs_project": True,
    },
    "checkpoint": {
        "aliases": ["save", "commit"],
        "summary": "Commit current workspace changes as a checkpoint.",
        "usage": "max checkpoint -m <message>",
        "agentctl": ["checkpoint"],
        "needs_project": True,
        "pass_args": True,
    },
    "rollback": {
        "aliases": ["undo", "revert"],
        "summary": "Discard uncommitted workspace changes.",
        "usage": "max rollback",
        "agentctl": ["rollback"],
        "needs_project": True,
        "pass_args": True,
    },
    "do": {
        "aliases": ["safe", "safe-run", "command", "cmd"],
        "summary": "Run a shell command through Max safety checks.",
        "usage": "max do <command>",
        "agentctl": ["safe-run"],
        "needs_project": True,
        "remainder": True,
    },
    "look": {
        "aliases": ["inspect", "scan"],
        "summary": "Inspect workspace with read-only checks.",
        "usage": "max look [project]",
        "agentctl": ["inspect"],
        "needs_project": True,
    },
    "check": {
        "aliases": ["doctor", "health"],
        "summary": "Check machine, tools, Ollama, RAM, and config.",
        "usage": "max check",
        "agentctl": ["doctor"],
        "needs_project": False,
    },
    "test": {
        "aliases": ["self-test", "verify"],
        "summary": "Run Max integration tests.",
        "usage": "max test [--with-model] [--with-long]",
        "agentctl": ["self-test"],
        "needs_project": False,
        "pass_args": True,
    },
    "model": {
        "aliases": ["model-test"],
        "summary": "Test the local model JSON response behavior.",
        "usage": "max model",
        "agentctl": ["model-test"],
        "needs_project": False,
        "pass_args": True,
    },
    "long": {
        "aliases": ["long-test", "context"],
        "summary": "Run long-context retrieval test.",
        "usage": "max long [--include-16k]",
        "agentctl": ["long-context-test"],
        "needs_project": False,
        "pass_args": True,
    },
    "open": {
        "aliases": ["code", "vscode"],
        "summary": "Open the current project in VS Code.",
        "usage": "max open [project]",
        "agentctl": ["open"],
        "needs_project": True,
    },
    "setup": {
        "aliases": ["setup-vscode", "vscode-setup"],
        "summary": "Create VS Code tasks/settings for the project.",
        "usage": "max setup [project]",
        "agentctl": ["setup-vscode"],
        "needs_project": True,
    },
    "memory": {
        "aliases": ["mem"],
        "summary": "List Max memory files.",
        "usage": "max memory [project]",
        "agentctl": ["memory"],
        "needs_project": True,
    },
    "last": {
        "aliases": ["recent", "history"],
        "summary": "Show recent command history.",
        "usage": "max last [project]",
        "agentctl": ["last"],
        "needs_project": True,
        "pass_args": True,
    },
    "logs": {
        "aliases": ["log"],
        "summary": "Show logs and reports.",
        "usage": "max logs [install|doctor|model|long|self]",
        "agentctl": ["logs"],
        "needs_project": False,
        "pass_args": True,
    },
    "config": {
        "aliases": ["settings", "set"],
        "summary": "Show or change project config and permissions.",
        "usage": "max config [show|path|set|get|enable|disable]",
        "agentctl": ["config"],
        "needs_project": False,
        "pass_args": True,
    },
    "unload": {
        "aliases": ["stop-model", "free"],
        "summary": "Unload the Ollama model from memory.",
        "usage": "max unload",
        "agentctl": ["unload-model"],
        "needs_project": False,
        "pass_args": True,
    },
    "raw": {
        "aliases": ["agentctl"],
        "summary": "Pass a command directly to the backend agentctl.",
        "usage": "max raw <agentctl-command>",
        "agentctl": [],
        "needs_project": False,
        "remainder": True,
    },
    "help": {
        "aliases": ["commands", "?"],
        "summary": "Show Max help.",
        "usage": "max help",
        "agentctl": None,
        "needs_project": False,
    },
}


def supports_color() -> bool:
    return sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


class UI:
    def __init__(self) -> None:
        self.color = supports_color()

    def c(self, code: str, text: str) -> str:
        if not self.color:
            return text
        return f"\033[{code}m{text}\033[0m"

    def dim(self, text: str) -> str:
        return self.c("2", text)

    def bold(self, text: str) -> str:
        return self.c("1", text)

    def cyan(self, text: str) -> str:
        return self.c("36", text)

    def green(self, text: str) -> str:
        return self.c("32", text)

    def yellow(self, text: str) -> str:
        return self.c("33", text)

    def red(self, text: str) -> str:
        return self.c("31", text)

    def blue(self, text: str) -> str:
        return self.c("34", text)

    def line(self) -> str:
        return self.dim("─" * 72)

    def header(self, title: str, subtitle: str | None = None) -> None:
        print("")
        print(self.bold(self.cyan("Max")) + self.dim("  local agent harness"))
        print(self.line())
        print(self.bold(title))
        if subtitle:
            print(self.dim(subtitle))
        print("")

    def ok(self, text: str) -> None:
        print(self.green("✓ ") + text)

    def warn(self, text: str) -> None:
        print(self.yellow("! ") + text)

    def fail(self, text: str) -> None:
        print(self.red("✗ ") + text)


ui = UI()


def all_names() -> dict[str, str]:
    out: dict[str, str] = {}
    for canonical, meta in COMMANDS.items():
        out[canonical] = canonical
        for alias in meta.get("aliases", []):
            out[alias] = canonical
    return out


def resolve_command(name: str) -> str | None:
    return all_names().get(name)


def suggestions(name: str, n: int = 4) -> list[str]:
    names = sorted(all_names().keys())
    matches = difflib.get_close_matches(name, names, n=n, cutoff=0.45)
    canonical = []
    for m in matches:
        c = all_names()[m]
        if c not in canonical:
            canonical.append(c)
    return canonical[:n]


def run_agentctl(args: list[str]) -> int:
    cmd = ["agentctl"] + args
    try:
        return subprocess.call(cmd)
    except KeyboardInterrupt:
        print("")
        print("Max command cancelled.")
        return 130


def is_project(path: Path) -> bool:
    return (path / ".agent").exists() and (path / "workspace").exists()


def set_current_project(path: Path) -> None:
    ensure_app_home()
    CURRENT_PROJECT_FILE.write_text(str(path.expanduser().resolve()))


def get_current_project() -> Path | None:
    cwd = Path.cwd().resolve()

    if is_project(cwd):
        return cwd

    if CURRENT_PROJECT_FILE.exists():
        p = Path(CURRENT_PROJECT_FILE.read_text().strip()).expanduser().resolve()
        if is_project(p):
            return p

    return None


def project_from_args(args: list[str]) -> tuple[str | None, list[str]]:
    if args:
        p, err = pm_resolve_project_ref(args[0])
        if p is not None:
            return str(p), args[1:]

    current = get_current_project()
    if current is not None:
        return str(current), args

    return None, args


def print_home() -> None:
    project = get_current_project()

    ui.header(
        "A smaller front door for your local agent system.",
        "Use natural commands. Advanced backend commands still exist through max raw.",
    )

    if project:
        ui.ok(f"Current project: {project}")
    else:
        ui.warn("No current project selected.")
        print("  Use: " + ui.bold("max new my-project") + " or " + ui.bold("max use <project>"))

    print("")
    print(ui.bold("Everyday commands"))
    print(ui.line())
    rows = [
        ("max projects", "List and switch between projects"),
        ("max skills install", "Install agent workflow skills"),
        ("max start", "Open interactive Max session"),
        ("max ask \"what is here?\"", "Ask a project-aware question"),
        ("max think \"what next?\"", "Force a model reasoning call"),
        ("max files", "Show workspace files instantly"),
        ("max tree", "Show workspace tree"),
        ("max read hello.py", "Read a workspace file"),
        ("max search Max", "Search workspace files"),
        ("max web read https://example.com", "Read a URL with project permissions"),
        ("max browser screenshot https://example.com", "Save a rendered page screenshot"),
        ("max research \"python argparse examples\"", "Collect sources into research notes"),
        ("max notes summarize calc2.py", "Save a lightweight file summary"),
        ("max audit", "Show unified project timeline"),
        ("max shell", "Open a shell inside the active workspace"),
        ("max test calc2.py add 5 3", "Run a workspace test command"),
        ("max info", "Show project/model info instantly"),
        ("max status", "Show project dashboard"),
        ("max do ls -lh .", "Run a safe command with approval/checks"),
        ("max run calc2.py [args]", "Run a workspace file safely"),
        ("max next", "Ask model for next safe action"),
        ("max index", "Build file index for smarter context"),
        ("max context \"task\"", "Preview selected task context"),
        ("max plan \"task\"", "Create a skill-guided plan"),
        ("max task \"task\"", "Plan, then offer first patch"),
        ("max fix", "Fix the last failed command"),
        ("max change \"create hello.py\"", "Propose file changes with diff + approval"),
        ("max diff", "Show workspace changes"),
        ("max checkpoint -m \"msg\"", "Save a Git checkpoint"),
        ("max open", "Open project in VS Code"),
        ("max check", "Check machine and model setup"),
        ("max test --with-model", "Run integration tests"),
        ("max logs", "Show reports and logs"),
    ]

    for cmd, desc in rows:
        print(f"  {ui.cyan(cmd):28} {ui.dim(desc)}")

    print("")
    print(ui.bold("Project setup"))
    print(ui.line())
    print(f"  {ui.cyan('max new my-project'):28} {ui.dim('Create a project')}")
    print(f"  {ui.cyan('max use my-project'):28} {ui.dim('Set active project')}")
    print(f"  {ui.cyan('max setup'):28} {ui.dim('Create VS Code tasks/settings')}")
    print("")
    print("Type " + ui.bold("max help") + " for the full compact command list.")
    print("")


def print_help() -> None:
    ui.header("Max command guide", "Small command set, natural aliases, advanced backend hidden behind max raw.")

    groups = [
        ("Daily", ["start", "ask", "think", "files", "tree", "read", "search", "web", "browser", "research", "notes", "audit", "workspace", "shell", "test", "index", "context", "plan", "task", "fix", "info", "status", "do", "run", "change", "diff", "checkpoint", "look", "open"]),
        ("Setup", ["projects", "skills", "new", "use", "where", "current", "delete", "forget", "rename", "setup", "config"]),
        ("Checks", ["check", "test", "model", "long", "logs", "unload"]),
        ("Memory", ["memory", "last", "sessions", "session"]),
        ("Advanced", ["rollback", "raw", "help"]),
    ]

    for title, keys in groups:
        print(ui.bold(title))
        print(ui.line())
        for key in keys:
            meta = COMMANDS[key]
            aliases = ", ".join(meta.get("aliases", []))
            alias_text = f" aliases: {aliases}" if aliases else ""
            print(f"  {ui.cyan(meta['usage']):34} {meta['summary']}")
            if alias_text:
                print(f"  {'':34} {ui.dim(alias_text)}")
        print("")

    print(ui.bold("Design rule"))
    print(ui.line())
    print("  Use Max for normal work. Use agentctl only for backend/debugging.")
    print("")


def cmd_use(args: list[str]) -> int:
    if not args:
        ui.fail("Missing project name or path.")
        print("Use: max use <project-name-or-path>")
        print("")
        pm_print_projects()
        return 2

    p, err = pm_resolve_project_ref(args[0])

    if err:
        ui.fail(err)
        print("")
        pm_print_projects()
        return 2

    assert p is not None

    pm_set_current_project(p)
    pm_register_project(p)

    ui.ok(f"Current project set to: {p}")
    return 0


def cmd_where() -> int:
    p = get_current_project()
    if p is None:
        ui.warn("No current project selected.")
        print("Use: max use <project-path>")
        return 1

    ui.ok(f"Current project: {p}")
    return 0


def cmd_new(args: list[str]) -> int:
    if not args:
        ui.fail("Missing project name.")
        print("Use: max new <project-name>")
        return 2

    code = run_agentctl(["init", args[0]])

    p = Path(args[0]).expanduser().resolve()
    if code == 0 and is_project(p):
        set_current_project(p)
        pm_register_project(p)
        ui.ok(f"Current project set to: {p}")
        print("")
        print("Next:")
        print(f"  {ui.cyan('max setup')}")
        print(f"  {ui.cyan('max start')}")
        print(f"  {ui.cyan('max open')}")

    return code




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




def _normalize_safe_command_args(rest: list[str]) -> list[str]:
    if not rest:
        return []

    # Allow both:
    #   max run "python3 calc2.py add 5 3"
    #   max run calc2.py add 5 3
    if len(rest) == 1:
        try:
            parts = shlex.split(rest[0])
        except ValueError:
            parts = rest
    else:
        parts = rest

    if not parts:
        return []

    target = parts[0]

    # Layman shortcuts:
    #   max run calc2.py
    #   max run calc2.py add 5 3
    # become:
    #   python3 calc2.py
    #   python3 calc2.py add 5 3
    if target.endswith(".py"):
        return ["python3", target] + parts[1:]

    if target.endswith(".sh"):
        return ["bash", target] + parts[1:]

    return parts

def cmd_direct_safe_command(args: list[str], allow_empty_as_next: bool = False) -> int:
    project_text, rest = project_from_args(args)

    if project_text is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2

    if not rest:
        if allow_empty_as_next:
            return run_agentctl(["run", project_text])
        ui.fail("Missing command.")
        print("Use: max run <file-or-command>")
        print("Examples:")
        print("  max run calc2.py")
        print("  max run python3 calc2.py")
        print("  max do ls -lh .")
        return 2

    command_args = _normalize_safe_command_args(rest)

    return run_agentctl(["safe-run", project_text] + command_args)


def dispatch(canonical: str, args: list[str]) -> int:
    if canonical == "help":
        print_help()
        return 0

    if canonical == "projects":
        return pm_print_projects()

    if canonical == "skills":
        return max_skills_command(args)

    if canonical == "delete":
        yes = "--yes" in args or "-y" in args
        clean = [a for a in args if a not in {"--yes", "-y"}]
        if not clean:
            ui.fail("Missing project name or path.")
            print("Use: max delete <project-name-or-path>")
            return 2
        return pm_delete_project(clean[0], yes=yes)

    if canonical == "forget":
        if not args:
            ui.fail("Missing project name or path.")
            print("Use: max forget <project-name-or-path>")
            return 2
        return pm_forget_project(args[0])

    if canonical == "rename":
        if len(args) < 2:
            ui.fail("Missing project and new name.")
            print("Use: max rename <project-name-or-path> <new-name>")
            return 2
        return pm_rename_project(args[0], args[1])

    if canonical == "use":
        return cmd_use(args)

    if canonical == "run":
        return cmd_direct_safe_command(args, allow_empty_as_next=True)

    if canonical == "do":
        return cmd_direct_safe_command(args, allow_empty_as_next=False)

    if canonical == "where" or canonical == "current":
        return cmd_where()

    if canonical == "new":
        return cmd_new(args)

    meta = COMMANDS[canonical]
    agentctl_cmd = meta.get("agentctl")

    if agentctl_cmd is None:
        print_help()
        return 0

    if canonical == "raw":
        if not args:
            ui.fail("Missing backend command.")
            print("Use: max raw <agentctl-command>")
            return 2
        return run_agentctl(args)

    project = None
    rest = args

    if meta.get("needs_project"):
        project, rest = project_from_args(args)
        if project is None:
            ui.fail("No project selected.")
            print("")
            print("Use one of these:")
            print("  max use <project-path>")
            print("  max new <project-name>")
            print("  max status <project-path>")
            return 2

    final_args = list(agentctl_cmd)

    if project is not None:
        final_args.append(project)

    if meta.get("remainder"):
        if not rest:
            ui.fail("Missing command.")
            print(f"Use: {meta['usage']}")
            return 2
        final_args.extend(rest)
    elif meta.get("pass_args"):
        final_args.extend(rest)
    else:
        final_args.extend(rest)

    return run_agentctl(final_args)


def unknown(name: str) -> int:
    ui.header("I do not know that command yet.", f"Unknown command: {name}")

    opts = suggestions(name)
    if opts:
        print(ui.bold("Did you mean?"))
        print(ui.line())
        for opt in opts:
            print(f"  {ui.cyan('max ' + opt):22} {COMMANDS[opt]['summary']}")
        print("")
    else:
        print("No close match found.")
        print("")

    print("Useful commands:")
    print(f"  {ui.cyan('max help')}")
    print(f"  {ui.cyan('max status')}")
    print(f"  {ui.cyan('max start')}")
    print(f"  {ui.cyan('max check')}")
    print("")
    return 2




def _direct_project_and_rest(args: list[str]) -> tuple[Path | None, list[str]]:
    project_text, rest = project_from_args(args)
    if project_text is None:
        return None, args
    return Path(project_text), rest


def _direct_plan(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    prompt = " ".join(rest).strip()
    if not prompt:
        ui.fail("Missing task.")
        print('Use: max plan "your task"')
        return 2
    direct_plan_project(project, prompt)
    return 0


def _direct_task(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    prompt = " ".join(rest).strip()
    if not prompt:
        ui.fail("Missing task.")
        print('Use: max task "your task"')
        return 2
    direct_task_project(project, prompt)
    return 0


def _direct_fix(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    direct_fix_project(project)
    return 0


def _direct_index(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    direct_print_index(project)
    return 0


def _direct_context(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    query = " ".join(rest).strip()
    if not query:
        query = "project overview"
    direct_print_context(project, query)
    return 0




def _direct_config(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    return direct_config_project(project, rest)




def _direct_web(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    return direct_web_project(project, rest)




def _direct_browser(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    return direct_browser_project(project, rest)




def _direct_research(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    return direct_research_project(project, rest)




def _direct_notes(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    return direct_notes_project(project, rest)




def _direct_audit(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    return direct_audit_project(project, rest)




def _direct_workspace(args: list[str]) -> int:
    if not args:
        args = ["workspace"]
    command = args[0]
    project, rest = _direct_project_and_rest(args[1:])
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    return direct_workspace_project(project, [command] + rest)




def _direct_test(args: list[str]) -> int:
    project, rest = _direct_project_and_rest(args)
    if project is None:
        ui.fail("No project selected.")
        print("Use: max use <project> or max new <project>")
        return 2
    return direct_test_project(project, rest)


def main(argv: list[str] | None = None) -> int:
    ensure_app_home()

    if argv is None:
        argv = sys.argv[1:]

    if not argv:
        print_home()
        return 0

    if argv and argv[0] in {"test", "check"}:
        return _direct_test(argv[1:])

    if argv and argv[0] in {"workspace", "where", "pwd", "cd", "shell"}:
        return _direct_workspace(argv)

    if argv and argv[0] in {"audit", "timeline"}:
        return _direct_audit(argv[1:])

    if argv and argv[0] in {"notes", "memory"}:
        return _direct_notes(argv[1:])

    if argv and argv[0] in {"research", "lookup"}:
        return _direct_research(argv[1:])

    if argv and argv[0] in {"browser", "chromium"}:
        return _direct_browser(argv[1:])

    if argv and argv[0] in {"web", "internet", "url"}:
        return _direct_web(argv[1:])

    if argv and argv[0] in {"config", "settings", "set"}:
        return _direct_config(argv[1:])

    if argv and argv[0] in {"plan", "outline"}:
        return _direct_plan(argv[1:])

    if argv and argv[0] in {"task", "build", "work"}:
        return _direct_task(argv[1:])

    if argv and argv[0] in {"fix", "repair"}:
        return _direct_fix(argv[1:])

    if argv and argv[0] in {"index"}:
        return _direct_index(argv[1:])

    if argv and argv[0] in {"context", "content"}:
        return _direct_context(argv[1:])


    # Friendly behavior: max . opens/uses current project.
    if argv[0] == ".":
        cwd = Path.cwd().resolve()
        if is_project(cwd):
            set_current_project(cwd)
            return dispatch("status", [])
        ui.fail("Current folder is not a Max project.")
        print("Use: max new <project-name>")
        return 2

    # Friendly prompt-like behavior.
    # Example: max "what is in this project?"
    if len(argv) == 1 and " " in argv[0]:
        return dispatch("ask", [argv[0]])

    name = argv[0]
    canonical = resolve_command(name)

    if canonical is None:
        if len(argv) > 1:
            return dispatch("ask", [" ".join(argv)])
        return unknown(name)

    return dispatch(canonical, argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
