from agent_harness.permissions import is_dangerous


def test_blocks_sudo():
    blocked, why = is_dangerous("sudo apt update")
    assert blocked


def test_blocks_rm_rf():
    blocked, why = is_dangerous("rm -rf /")
    assert blocked


def test_safe_ls():
    blocked, why = is_dangerous("ls -la")
    assert not blocked
