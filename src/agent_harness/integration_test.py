from __future__ import annotations

import json
import shutil
import time
from pathlib import Path
from typing import Any

from .command_runner import run_command
from .config import load_config
from .doctor import run_doctor
from .long_context_test import run_long_context_test
from .memory import append_command_history, update_current_state
from .ollama_client import chat, extract_message_text
from .ollama_control import unload_model
from .schemas import extract_json_object, validate_plan
from .util import APP_HOME, meminfo_gb, now_ts, write_json
from .workspace import init_project
from .ux import setup_vscode


def _add_result(
    results: list[dict[str, Any]],
    name: str,
    ok: bool,
    details: dict[str, Any] | None = None,
    error: str = "",
) -> None:
    results.append(
        {
            "name": name,
            "ok": bool(ok),
            "error": error,
            "details": details or {},
        }
    )


def _print_summary(report: dict[str, Any]) -> None:
    print("")
    print("agent-harness self-test")
    print("=" * 72)
    print(f"Project: {report['project']}")
    print(f"Started: {report['started_at']}")
    print(f"Finished: {report['finished_at']}")
    print(f"Passed: {report['passed']}/{report['total']}")
    print(f"Failed: {report['failed']}")
    print("")

    for item in report["results"]:
        mark = "PASS" if item["ok"] else "FAIL"
        print(f"[{mark}] {item['name']}")
        if item.get("error"):
            print(f"       error: {item['error']}")

    print("")
    print(f"Report saved to: {APP_HOME / 'self_test_report.json'}")
    print("")


def run_self_test(
    with_model: bool = False,
    with_long: bool = False,
    clean: bool = False,
) -> dict[str, Any]:
    cfg = load_config()
    results: list[dict[str, Any]] = []

    test_root = APP_HOME / "self_tests" / f"selftest_{int(time.time())}"
    project = init_project(str(test_root))
    workspace = project / "workspace"
    agent = project / ".agent"

    started_at = now_ts()

    try:
        doctor = run_doctor(json_only=True)
        _add_result(
            results,
            "doctor runs",
            doctor.get("ollama_api") == "ok",
            {
                "ollama_api": doctor.get("ollama_api"),
                "ram_available_gb": doctor.get("ram_available_gb"),
                "configured_model": doctor.get("configured_model"),
            },
        )
    except Exception as e:
        _add_result(results, "doctor runs", False, error=str(e))

    try:
        expected_paths = [
            workspace,
            agent,
            agent / "plan.json",
            agent / "command_history.json",
            agent / "current_state.md",
            project / "agent.config.json",
        ]
        missing = [str(p) for p in expected_paths if not p.exists()]
        _add_result(
            results,
            "workspace and memory files exist",
            not missing,
            {"missing": missing},
        )
    except Exception as e:
        _add_result(results, "workspace and memory files exist", False, error=str(e))

    try:
        sample = workspace / "sample.txt"
        sample.write_text("agent-harness self-test sample\n")

        result = run_command(
            command="ls -lh .",
            cwd=workspace,
            workspace_root=workspace,
            reason="Self-test safe read-only command.",
            ask=False,
        )
        append_command_history(project, result)

        _add_result(
            results,
            "safe relative command runs",
            result.get("ok") is True and result.get("blocked") is False,
            result,
        )
    except Exception as e:
        _add_result(results, "safe relative command runs", False, error=str(e))

    try:
        blocked = run_command(
            command=f"ls -lh {Path.home()}",
            cwd=workspace,
            workspace_root=workspace,
            reason="Self-test outside path should be blocked.",
            ask=False,
        )
        append_command_history(project, blocked)

        _add_result(
            results,
            "outside absolute path is blocked",
            blocked.get("blocked") is True,
            blocked,
        )
    except Exception as e:
        _add_result(results, "outside absolute path is blocked", False, error=str(e))

    try:
        cat_result = run_command(
            command="cat sample.txt",
            cwd=workspace,
            workspace_root=workspace,
            reason="Self-test read sample file.",
            ask=False,
        )
        append_command_history(project, cat_result)

        _add_result(
            results,
            "sample file can be read inside workspace",
            cat_result.get("ok") is True and "self-test sample" in cat_result.get("stdout", ""),
            cat_result,
        )
    except Exception as e:
        _add_result(results, "sample file can be read inside workspace", False, error=str(e))

    try:
        setup_vscode(project)
        vscode_files = [
            project / ".vscode" / "tasks.json",
            project / ".vscode" / "settings.json",
            project / ".vscode" / "extensions.json",
            project / "AGENT.md",
        ]
        missing = [str(p) for p in vscode_files if not p.exists()]

        _add_result(
            results,
            "VS Code setup files exist",
            not missing,
            {"missing": missing},
        )
    except Exception as e:
        _add_result(results, "VS Code setup files exist", False, error=str(e))

    try:
        update_current_state(project, "Self-test local checks completed.")
        current_state = (agent / "current_state.md").read_text()

        _add_result(
            results,
            "current_state memory updates",
            "Self-test local checks completed" in current_state,
            {"current_state_tail": current_state[-500:]},
        )
    except Exception as e:
        _add_result(results, "current_state memory updates", False, error=str(e))

    if with_model:
        try:
            before = meminfo_gb()

            prompt = f"""
You are testing an agent controller.

Return JSON only. No markdown.

Schema:
{{
  "goal": "string",
  "steps": ["string"],
  "next_action": "string",
  "suggested_command": "string",
  "reason": "string"
}}

Rules:
- suggested_command must be exactly: ls -lh .
- Use only a safe read-only command.
- Do not use absolute paths.
- Do not use sudo.
- Do not delete or install anything.

Workspace:
{workspace}
"""

            resp = chat(
                model=cfg["model"],
                num_ctx=4096,
                temperature=0.1,
                messages=[
                    {"role": "system", "content": "Return valid JSON only."},
                    {"role": "user", "content": prompt},
                ],
            )

            text = extract_message_text(resp)
            obj = extract_json_object(text)
            errors = validate_plan(obj)

            ok = not errors and obj.get("suggested_command") == "ls -lh ."

            _add_result(
                results,
                "model returns valid safe plan JSON",
                ok,
                {
                    "plan": obj,
                    "errors": errors,
                    "ram_available_before_gb": round(before.get("MemAvailable", 0), 2),
                    "ram_available_after_gb": round(meminfo_gb().get("MemAvailable", 0), 2),
                },
            )

            if ok:
                write_json(agent / "plan.json", obj)
                update_current_state(project, f"Self-test model plan:\n\n{json.dumps(obj, indent=2)}")

                model_cmd_result = run_command(
                    command=obj["suggested_command"],
                    cwd=workspace,
                    workspace_root=workspace,
                    reason=obj["reason"],
                    ask=False,
                )

                append_command_history(project, model_cmd_result)

                _add_result(
                    results,
                    "model-suggested command executes through controller",
                    model_cmd_result.get("ok") is True and model_cmd_result.get("blocked") is False,
                    model_cmd_result,
                )
        except Exception as e:
            _add_result(results, "model returns valid safe plan JSON", False, error=str(e))

    if with_long:
        try:
            long_report = run_long_context_test(model=cfg["model"], contexts=[4096])
            long_ok = all(item.get("ok") for item in long_report.get("results", []))

            _add_result(
                results,
                "4K long-context retrieval works",
                long_ok,
                {
                    "results": long_report.get("results", []),
                },
            )
        except Exception as e:
            _add_result(results, "4K long-context retrieval works", False, error=str(e))

    if with_model:
        try:
            unload = unload_model(model=cfg["model"])
            _add_result(
                results,
                "model unload command returns",
                bool(unload.get("ok")),
                unload,
            )
        except Exception as e:
            _add_result(results, "model unload command returns", False, error=str(e))

    passed = sum(1 for item in results if item["ok"])
    total = len(results)
    failed = total - passed

    report = {
        "started_at": started_at,
        "finished_at": now_ts(),
        "project": str(project),
        "with_model": with_model,
        "with_long": with_long,
        "clean": clean,
        "passed": passed,
        "failed": failed,
        "total": total,
        "results": results,
    }

    write_json(APP_HOME / "self_test_report.json", report)

    if clean:
        shutil.rmtree(project, ignore_errors=True)
        report["project_cleaned"] = True
        write_json(APP_HOME / "self_test_report.json", report)

    _print_summary(report)

    return report
