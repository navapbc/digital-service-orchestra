"""Tests for ticket_reducer._alias.compute_alias and the read-time backfill
applied by ticket_reducer._processors.process_create.

Behaviours under test:
  - compute_alias returns adj-noun-noun for full 16-hex IDs
  - compute_alias returns adj-noun (2 words) for legacy 8-hex IDs
  - compute_alias returns the same value as the shipped ticket-alias-compute.py
    shell helper (cross-implementation parity)
  - process_create populates state['alias'] from data.alias when present
  - process_create backfills state['alias'] from ticket_id when data.alias missing
"""

import json
import subprocess
import sys
import time
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "plugins" / "dso" / "scripts"
sys.path.insert(0, str(SCRIPTS))

from ticket_reducer._alias import compute_alias  # noqa: E402
from ticket_reducer import reduce_ticket  # noqa: E402


def test_compute_alias_full_id_three_words():
    alias = compute_alias("0193-d61d-abcd-1234")
    assert alias is not None
    parts = alias.split("-")
    assert len(parts) == 3, f"expected adj-noun-noun, got {alias!r}"


def test_compute_alias_legacy_8hex_two_words():
    alias = compute_alias("0193-d61d")
    assert alias is not None
    parts = alias.split("-")
    assert len(parts) == 2, f"expected adj-noun, got {alias!r}"


def test_compute_alias_too_short_returns_none():
    assert compute_alias("abc") is None
    assert compute_alias("") is None


def test_compute_alias_matches_shell_helper():
    """Module fallback must match the existing shell-side computation byte-for-byte
    so backfilled aliases for legacy tickets are the same as if they had been
    written at create time."""
    shell = SCRIPTS / "ticket-alias-compute.py"
    wordlist = REPO_ROOT / "plugins" / "dso" / "resources" / "ticket-wordlist.txt"
    assert shell.exists()
    assert wordlist.exists()
    for tid in ("0193-d61d-abcd-1234", "ffff-0000-1111-2222"):
        out = subprocess.run(
            [sys.executable, str(shell), tid, str(wordlist)],
            capture_output=True,
            text=True,
            check=True,
        )
        assert out.stdout.strip() == compute_alias(tid)


def _plant_ticket(root: Path, ticket_id: str, alias_in_data: str | None) -> Path:
    """Write a minimal CREATE event for ticket_id, optionally with data.alias."""
    td = root / ticket_id
    td.mkdir(parents=True, exist_ok=True)
    ts = time.time_ns()
    ev = str(uuid.uuid4())
    data = {"ticket_type": "task", "title": "test"}
    if alias_in_data is not None:
        data["alias"] = alias_in_data
    payload = {
        "timestamp": ts,
        "uuid": ev,
        "event_type": "CREATE",
        "env_id": "",
        "author": "test",
        "data": data,
    }
    (td / f"{ts}-{ev}-CREATE.json").write_text(json.dumps(payload))
    return td


def test_process_create_prefers_stored_over_backfill(tmp_path):
    """When data.alias is present, process_create uses it verbatim — even when
    that stored value differs from what compute_alias(ticket_id) would yield.
    This guards against a regression where backfill clobbers the stored alias
    (a real risk if the conditional flips). The asserted value is intentionally
    NOT the deterministic backfill — a tautological "plant X, expect X" test
    would still pass if process_create returned a hardcoded value."""
    ticket_id = "aaaa-bbbb-cccc-dddd"
    backfill_would_yield = compute_alias(ticket_id)
    stored = "manually-chosen-alias"
    assert stored != backfill_would_yield, (
        "test invariant: stored must differ from backfill so the assertion "
        "actually proves stored-wins precedence"
    )
    td = _plant_ticket(tmp_path, ticket_id, stored)
    state = reduce_ticket(str(td))
    assert state["alias"] == stored


def test_process_create_backfills_when_alias_missing(tmp_path):
    """Legacy tickets (no data.alias on CREATE) should surface a computed alias."""
    td = _plant_ticket(tmp_path, "0193-d61d-abcd-1234", alias_in_data=None)
    state = reduce_ticket(str(td))
    expected = compute_alias("0193-d61d-abcd-1234")
    assert state["alias"] == expected
    assert state["alias"] is not None


# ── Edge-case coverage for ticket-alias-resolve.py (Finding 4) ────────────────

RESOLVER_SCRIPT = SCRIPTS / "ticket-alias-resolve.py"


def _run_resolver(target: str, tracker: str | Path) -> tuple[int, str, str]:
    """Invoke ticket-alias-resolve.py and return (rc, stdout, stderr)."""
    proc = subprocess.run(
        [sys.executable, str(RESOLVER_SCRIPT), target, str(tracker)],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def test_resolver_missing_tracker_dir_fails_loud(tmp_path):
    """Non-existent tracker directory must exit non-zero with a useful stderr —
    silent emptiness is indistinguishable from 'no matches found'."""
    rc, _, err = _run_resolver("anything", tmp_path / "does-not-exist")
    assert rc != 0
    assert "cannot list" in err


def test_resolver_malformed_create_json_is_skipped(tmp_path):
    """A ticket dir with corrupt CREATE event JSON must not crash the resolver —
    other tickets in the same tracker must still resolve."""
    # Valid ticket
    good = _plant_ticket(tmp_path, "1111-2222-3333-4444", "good-stored-alias")
    # Corrupt ticket
    bad = tmp_path / "5555-6666-7777-8888"
    bad.mkdir()
    ts = time.time_ns()
    (bad / f"{ts}-junk-CREATE.json").write_text("{ not valid json")
    rc, out, _ = _run_resolver("good-stored-alias", tmp_path)
    assert rc == 0
    assert out.strip() == f"alias\t{good.name}"


def test_resolver_dotfile_dirs_ignored(tmp_path):
    """Entries starting with '.' (caches, lockfiles, the __bridge__ pseudo-dir
    by accident) must not be scanned — they aren't tickets."""
    (tmp_path / ".graph-cache").mkdir()
    (tmp_path / ".graph-cache" / "fake-CREATE.json").write_text(
        json.dumps({"data": {"alias": "should-not-match"}})
    )
    rc, out, _ = _run_resolver("should-not-match", tmp_path)
    assert rc == 0
    assert out.strip() == ""


def test_resolver_backfilled_alias_matches_legacy_ticket(tmp_path):
    """A ticket with no data.alias must still resolve via the computed
    fallback — this is the whole point of the backfill."""
    td = _plant_ticket(tmp_path, "0193-d61d-abcd-1234", alias_in_data=None)
    expected = compute_alias("0193-d61d-abcd-1234")
    rc, out, _ = _run_resolver(expected, tmp_path)
    assert rc == 0
    assert out.strip() == f"alias\t{td.name}"


def test_resolver_jira_key_takes_precedence_over_alias_collision(tmp_path):
    """If a single ticket's CREATE event has both a matching jira_key and a
    matching alias for the same input string (pathological), jira wins —
    matches the resolver's documented precedence order."""
    td = tmp_path / "abcd-efab-1234-5678"
    td.mkdir()
    ts = time.time_ns()
    (td / f"{ts}-x-CREATE.json").write_text(
        json.dumps(
            {
                "data": {"alias": "COLLIDE-99", "jira_key": "COLLIDE-99"},
            }
        )
    )
    rc, out, _ = _run_resolver("COLLIDE-99", tmp_path)
    assert rc == 0
    assert out.strip() == f"jira\t{td.name}"


def test_load_warns_once_when_wordlist_missing(tmp_path, capsys, monkeypatch):
    """When the wordlist is unavailable, _load() must emit a one-shot stderr
    diagnostic — silent fallback to the 8-hex alias hides a real
    misconfiguration. The warning must appear exactly once per process even
    across many _load() calls (cache + warned-flag both prevent re-emission)."""
    from ticket_reducer import _alias as alias_mod

    # Reset the module-level cache + warned flag so this test starts clean
    monkeypatch.setattr(alias_mod, "_WORDS_CACHE", None)
    monkeypatch.setattr(alias_mod, "_WARNED_MISSING", False)
    monkeypatch.setenv("TICKET_WORDLIST_PATH", str(tmp_path / "does-not-exist.txt"))

    alias_mod._load()
    alias_mod._load()
    alias_mod._load()
    captured = capsys.readouterr()
    occurrences = captured.err.count("ticket-wordlist.txt unavailable")
    assert occurrences == 1, (
        f"expected exactly one WARN, saw {occurrences} in stderr: {captured.err!r}"
    )
