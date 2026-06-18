from __future__ import annotations

import time

from .config import load_config
from .ollama_client import chat, extract_message_text
from .schemas import extract_json_object
from .util import APP_HOME, ensure_app_home, meminfo_gb, now_ts, write_json


EXPECTED = {
    "alpha": "blue_harbor_17",
    "beta": "copper_bridge_42",
    "gamma": "violet_engine_93",
}


def make_document(num_ctx: int) -> str:
    # Rough token estimate. We use about 70 to 75 percent of context.
    # This is intentionally approximate because tokenization differs by model.
    target_chars = int(num_ctx * 2.8)
    base_line = (
        "FILLER LINE {i:05d}: This line is irrelevant project history. "
        "It discusses stale logs, previous plans, interface notes, and old test output. "
        "The model should ignore noise and recover the anchor facts only.\n"
    )

    lines = []
    i = 0
    while len("".join(lines)) < target_chars:
        lines.append(base_line.format(i=i))
        i += 1

    n = len(lines)
    lines.insert(max(1, n // 20), f"ANCHOR_ALPHA={EXPECTED['alpha']}\n")
    lines.insert(max(2, n // 2), f"ANCHOR_BETA={EXPECTED['beta']}\n")
    lines.insert(max(3, int(n * 0.90)), f"ANCHOR_GAMMA={EXPECTED['gamma']}\n")

    return "".join(lines)


def run_long_context_test(
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
        document = make_document(ctx)

        prompt = f"""
You are testing long-context retrieval for a local agent system.

Read the document and return JSON only. No markdown.

Required JSON schema:
{{
  "alpha": "string",
  "beta": "string",
  "gamma": "string",
  "found_all": boolean,
  "summary": "string"
}}

You must recover the exact values for:
ANCHOR_ALPHA
ANCHOR_BETA
ANCHOR_GAMMA

DOCUMENT START
{document}
DOCUMENT END
"""

        before = meminfo_gb()
        t0 = time.time()

        item = {
            "timestamp": now_ts(),
            "model": model,
            "num_ctx": ctx,
            "document_chars": len(document),
            "ok": False,
            "json_valid": False,
            "found_all": False,
            "duration_sec": None,
            "error": "",
            "ram_available_before_gb": round(before.get("MemAvailable", 0), 2),
            "ram_available_after_gb": None,
            "swap_free_before_gb": round(before.get("SwapFree", 0), 2),
            "swap_free_after_gb": None,
            "raw_text_preview": "",
            "parsed": {},
        }

        try:
            resp = chat(
                model=model,
                num_ctx=ctx,
                temperature=0.0,
                messages=[
                    {"role": "system", "content": "Return valid JSON only. Do not include markdown."},
                    {"role": "user", "content": prompt},
                ],
            )

            text = extract_message_text(resp)
            item["raw_text_preview"] = text[:500]

            obj = extract_json_object(text)
            item["json_valid"] = True
            item["parsed"] = obj

            alpha_ok = obj.get("alpha") == EXPECTED["alpha"]
            beta_ok = obj.get("beta") == EXPECTED["beta"]
            gamma_ok = obj.get("gamma") == EXPECTED["gamma"]

            item["found_all"] = bool(alpha_ok and beta_ok and gamma_ok)
            item["ok"] = item["json_valid"] and item["found_all"]

        except Exception as e:
            item["error"] = str(e)

        after = meminfo_gb()

        item["duration_sec"] = round(time.time() - t0, 3)
        item["ram_available_after_gb"] = round(after.get("MemAvailable", 0), 2)
        item["swap_free_after_gb"] = round(after.get("SwapFree", 0), 2)

        results.append(item)

        print(
            f"context={ctx} "
            f"chars={item['document_chars']} "
            f"ok={item['ok']} "
            f"json_valid={item['json_valid']} "
            f"found_all={item['found_all']} "
            f"duration={item['duration_sec']}s "
            f"ram_before={item['ram_available_before_gb']}GB "
            f"ram_after={item['ram_available_after_gb']}GB"
        )

        if item["error"]:
            print(f"  error: {item['error']}")

        if item["json_valid"] and not item["found_all"]:
            print(f"  parsed: {item['parsed']}")

    report = {
        "model": model,
        "created_at": now_ts(),
        "expected": EXPECTED,
        "results": results,
    }

    write_json(APP_HOME / "long_context_test_report.json", report)
    print("")
    print(f"Report saved to: {APP_HOME / 'long_context_test_report.json'}")

    return report
