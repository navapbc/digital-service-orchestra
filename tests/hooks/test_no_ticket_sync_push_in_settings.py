"""Test that ticket-sync-push.sh references have been removed from settings files.

TDD spec: grep .claude/settings.json and lockpick-workflow/hooks.json for
ticket-sync-push; assert zero matches.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SETTINGS_JSON = REPO_ROOT / ".claude" / "settings.json"
HOOKS_JSON = REPO_ROOT / "plugins" / "dso" / ".claude-plugin" / "plugin.json"


def test_no_ticket_sync_push_in_settings() -> None:
    """settings.json must not reference ticket-sync-push."""
    content = SETTINGS_JSON.read_text()
    assert "ticket-sync-push" not in content, (
        ".claude/settings.json still contains ticket-sync-push reference(s). "
        "These should have been removed as part of removing the automatic ticket sync hook."
    )


def test_no_ticket_sync_push_in_hooks_json() -> None:
    """plugin.json hooks must not reference ticket-sync-push."""
    content = HOOKS_JSON.read_text()
    assert "ticket-sync-push" not in content, (
        ".claude-plugin/plugin.json still contains ticket-sync-push reference(s). "
        "These should have been removed as part of removing the automatic ticket sync hook."
    )
