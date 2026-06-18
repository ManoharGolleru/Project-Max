from __future__ import annotations

import json
import re
from typing import Any


def extract_json_object(text: str) -> dict[str, Any]:
    cleaned = text.strip()

    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?", "", cleaned.strip(), flags=re.IGNORECASE).strip()
        cleaned = re.sub(r"```$", "", cleaned.strip()).strip()

    try:
        obj = json.loads(cleaned)
    except json.JSONDecodeError:
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start == -1 or end == -1 or end <= start:
            raise
        obj = json.loads(cleaned[start : end + 1])

    if not isinstance(obj, dict):
        raise ValueError("Expected JSON object")

    return obj


def validate_plan(obj: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    if "goal" not in obj or not isinstance(obj["goal"], str):
        errors.append("Missing string field: goal")

    if "steps" not in obj or not isinstance(obj["steps"], list):
        errors.append("Missing list field: steps")

    if "next_action" not in obj or not isinstance(obj["next_action"], str):
        errors.append("Missing string field: next_action")

    if "suggested_command" not in obj or not isinstance(obj["suggested_command"], str):
        errors.append("Missing string field: suggested_command")

    if "reason" not in obj or not isinstance(obj["reason"], str):
        errors.append("Missing string field: reason")

    return errors
