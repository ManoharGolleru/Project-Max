from __future__ import annotations

from pathlib import Path

from .ask_model import ask_project
from .local_answer import answer_local_and_log, local_answer


def smart_ask_project(
    project: Path,
    user_prompt: str,
    interactive: bool = True,
    no_run: bool = False,
    force_model: bool = False,
) -> dict:
    if not force_model:
        local = local_answer(project, user_prompt)
        if local is not None:
            return answer_local_and_log(project, user_prompt, local, interactive=interactive)

    return ask_project(
        project,
        user_prompt,
        interactive=interactive,
        no_run=no_run,
    )
