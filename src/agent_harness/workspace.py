from __future__ import annotations

from pathlib import Path

from .config import load_config
from .util import now_ts, write_json


MEMORY_MD_FILES = {
    "project_goal.md": "# Project goal\n\n",
    "decisions.md": "# Decisions\n\n",
    "current_state.md": "# Current state\n\n",
}

MEMORY_JSON_FILES = {
    "plan.json": {"created_at": None, "steps": []},
    "open_issues.json": {"issues": []},
    "completed_steps.json": {"steps": []},
    "command_history.json": {"commands": []},
    "test_history.json": {"tests": []},
    "failure_log.json": {"failures": []},
    "run_metrics.json": {"runs": []},
}


def init_project(project_name: str) -> Path:
    root = Path(project_name).expanduser().resolve()
    workspace = root / "workspace"
    agent = root / ".agent"

    workspace.mkdir(parents=True, exist_ok=True)
    agent.mkdir(parents=True, exist_ok=True)

    for sub in ["file_summaries", "git_diffs", "ui_audit_reports"]:
        (agent / sub).mkdir(parents=True, exist_ok=True)

    for name, content in MEMORY_MD_FILES.items():
        p = agent / name
        if not p.exists():
            p.write_text(content)

    for name, content in MEMORY_JSON_FILES.items():
        p = agent / name
        if not p.exists():
            data = dict(content)
            if "created_at" in data:
                data["created_at"] = now_ts()
            write_json(p, data)

    cfg = load_config()

    project_config = root / "agent.config.json"
    if not project_config.exists():
        write_json(
            project_config,
            {
                "model": cfg["model"],
                "context": cfg["default_context"],
                "temperature": cfg["temperature"],
                "ram_limit_gb": cfg["ram_limit_gb"],
                "approval_mode": cfg["approval_mode"],
            },
        )

    gitignore = root / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text(".venv/\nnode_modules/\n__pycache__/\n")

    return root


def find_project(project_name: str) -> Path:
    root = Path(project_name).expanduser().resolve()
    if not root.exists():
        raise FileNotFoundError(f"Project not found: {root}")
    if not (root / ".agent").exists():
        raise FileNotFoundError(f"Missing .agent folder: {root / '.agent'}")
    if not (root / "workspace").exists():
        raise FileNotFoundError(f"Missing workspace folder: {root / 'workspace'}")
    return root
