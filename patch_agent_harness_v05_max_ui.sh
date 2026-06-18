#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "src/agent_harness" ]; then
  echo "ERROR: Run this from inside the agent-harness folder."
  echo "Example:"
  echo "  cd ~/agent-harness"
  echo "  bash patch_agent_harness_v05_max_ui.sh"
  exit 1
fi

BACKUP_DIR="patch_backup_v05_max_ui_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [ -f "src/agent_harness/max_cli.py" ]; then
  cp src/agent_harness/max_cli.py "$BACKUP_DIR/max_cli.py.bak"
fi

echo "Backup saved to: $BACKUP_DIR"

cat > src/agent_harness/max_cli.py <<'EOF'
from __future__ import annotations

import difflib
import os
import shutil
import subprocess
import sys
from pathlib import Path

from .util import APP_HOME, ensure_app_home


CURRENT_PROJECT_FILE = APP_HOME / "current_project"


COMMANDS = {
    "new": {
        "aliases": ["init", "create", "make"],
        "summary": "Create a new Max project.",
        "usage": "max new <project-name>",
        "agentctl": ["init"],
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
    "start": {
        "aliases": ["chat", "talk", "open-session", "session"],
        "summary": "Start the interactive Max session.",
        "usage": "max start [project]",
        "agentctl": ["chat"],
        "needs_project": True,
    },
    "status": {
        "aliases": ["dashboard", "home", "state", "overview"],
        "summary": "Show project dashboard.",
        "usage": "max status [project]",
        "agentctl": ["dashboard"],
        "needs_project": True,
    },
    "run": {
        "aliases": ["think", "plan"],
        "summary": "Ask Max to produce a safe next plan and suggested command.",
        "usage": "max run [project]",
        "agentctl": ["run"],
        "needs_project": True,
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
        "aliases": ["mem", "files"],
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
        "summary": "Show or change Max config.",
        "usage": "max config",
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
    return subprocess.call(cmd)


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
        candidate = Path(args[0]).expanduser()
        if candidate.exists() and is_project(candidate.resolve()):
            return str(candidate.resolve()), args[1:]

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
        ("max start", "Open interactive Max session"),
        ("max status", "Show project dashboard"),
        ("max do ls -lh .", "Run a safe command with approval/checks"),
        ("max run", "Ask the model for the next safe action"),
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
        ("Daily", ["start", "status", "do", "run", "look", "open"]),
        ("Setup", ["new", "use", "where", "setup", "config"]),
        ("Checks", ["check", "test", "model", "long", "logs", "unload"]),
        ("Memory", ["memory", "last"]),
        ("Advanced", ["raw", "help"]),
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
        ui.fail("Missing project path.")
        print("Use: max use <project-path>")
        return 2

    p = Path(args[0]).expanduser().resolve()

    if not p.exists():
        ui.fail(f"Project path does not exist: {p}")
        return 2

    if not is_project(p):
        ui.fail(f"Not a Max project: {p}")
        print("A Max project needs .agent/ and workspace/")
        return 2

    set_current_project(p)
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
        ui.ok(f"Current project set to: {p}")
        print("")
        print("Next:")
        print(f"  {ui.cyan('max setup')}")
        print(f"  {ui.cyan('max start')}")
        print(f"  {ui.cyan('max open')}")

    return code


def dispatch(canonical: str, args: list[str]) -> int:
    if canonical == "help":
        print_help()
        return 0

    if canonical == "use":
        return cmd_use(args)

    if canonical == "where":
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


def main(argv: list[str] | None = None) -> int:
    ensure_app_home()

    if argv is None:
        argv = sys.argv[1:]

    if not argv:
        print_home()
        return 0

    # Friendly behavior: max . opens/uses current project.
    if argv[0] == ".":
        cwd = Path.cwd().resolve()
        if is_project(cwd):
            set_current_project(cwd)
            return dispatch("status", [])
        ui.fail("Current folder is not a Max project.")
        print("Use: max new <project-name>")
        return 2

    # Friendly prompt-like behavior. Full natural language one-shot is later.
    if len(argv) == 1 and " " in argv[0]:
        ui.warn("Natural-language one-shot mode is not implemented yet.")
        print("For now use:")
        print("  max start")
        print("  max run")
        return 2

    name = argv[0]
    canonical = resolve_command(name)

    if canonical is None:
        return unknown(name)

    return dispatch(canonical, argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
EOF

python3 -m compileall src/agent_harness

mkdir -p "$HOME/.local/bin"

if [ -f "$HOME/.local/bin/max" ]; then
  cp "$HOME/.local/bin/max" "$BACKUP_DIR/max.wrapper.bak"
fi

cat > "$HOME/.local/bin/max" <<EOF
#!/usr/bin/env bash
source "${PWD}/.venv/bin/activate"
exec python -m agent_harness.max_cli "\$@"
EOF

chmod +x "$HOME/.local/bin/max"

echo ""
echo "Max UI patch installed."
echo ""
echo "Try:"
echo "  max"
echo "  max help"
echo "  max use test-project"
echo "  max status"
echo "  max start"
echo "  max do ls -lh ."
echo "  max statsu"
echo "  max open"
