from agent_harness.schemas import extract_json_object, validate_plan


def test_extract_json_object():
    obj = extract_json_object('{"ok": true}')
    assert obj["ok"] is True


def test_validate_plan():
    errors = validate_plan(
        {
            "goal": "inspect",
            "steps": ["list files"],
            "next_action": "run command",
            "suggested_command": "ls -la",
            "reason": "Inspect workspace",
        }
    )
    assert errors == []
