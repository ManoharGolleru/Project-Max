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
