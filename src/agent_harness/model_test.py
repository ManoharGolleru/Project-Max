from __future__ import annotations

import time

from .config import load_config
from .ollama_client import chat, extract_message_text
from .schemas import extract_json_object
from .util import APP_HOME, ensure_app_home, meminfo_gb, now_ts, write_json


def run_model_test(
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
        before = meminfo_gb()
        t0 = time.time()

        prompt = (
            "Return valid JSON only. No markdown. "
            "Schema: {\"ok\": boolean, \"model_role\": string, \"next_steps\": string[]} "
            "Set ok to true. model_role should be planner_reviewer. "
            "Include exactly three next_steps."
        )

        item = {
            "timestamp": now_ts(),
            "model": model,
            "num_ctx": ctx,
            "ok": False,
            "json_valid": False,
            "duration_sec": None,
            "error": "",
            "ram_available_before_gb": round(before.get("MemAvailable", 0), 2),
            "ram_available_after_gb": None,
            "swap_free_before_gb": round(before.get("SwapFree", 0), 2),
            "swap_free_after_gb": None,
            "raw_text_preview": "",
        }

        try:
            resp = chat(
                model=model,
                num_ctx=ctx,
                temperature=0.1,
                messages=[
                    {"role": "system", "content": "You are a strict JSON generator."},
                    {"role": "user", "content": prompt},
                ],
            )

            text = extract_message_text(resp)
            item["raw_text_preview"] = text[:500]

            obj = extract_json_object(text)
            item["json_valid"] = True
            item["ok"] = bool(obj.get("ok")) and isinstance(obj.get("next_steps"), list)

        except Exception as e:
            item["error"] = str(e)

        after = meminfo_gb()

        item["duration_sec"] = round(time.time() - t0, 3)
        item["ram_available_after_gb"] = round(after.get("MemAvailable", 0), 2)
        item["swap_free_after_gb"] = round(after.get("SwapFree", 0), 2)

        results.append(item)

        print(
            f"context={ctx} "
            f"ok={item['ok']} "
            f"json_valid={item['json_valid']} "
            f"duration={item['duration_sec']}s "
            f"ram_before={item['ram_available_before_gb']}GB "
            f"ram_after={item['ram_available_after_gb']}GB"
        )

        if item["error"]:
            print(f"  error: {item['error']}")

    report = {
        "model": model,
        "created_at": now_ts(),
        "results": results,
    }

    write_json(APP_HOME / "model_test_report.json", report)
    print("")
    print(f"Report saved to: {APP_HOME / 'model_test_report.json'}")

    return report
