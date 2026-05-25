"""Unit tests for gov_copy_postprocess.readability and gov_copy_postprocess.banned.

Covers task 012f-500c-e9de-494a (RED test for compute_fk_grade) and
task 20f1-51f5-4f06-4611 (RED test for find_banned_words).

DDs tested:
  - compute_fk_grade returns Flesch-Kincaid grade within 1e-6 of textstat
    reference value for a representative gov-copy sentence.
  - find_banned_words returns banned words found in text, case-insensitive,
    preserving first-occurrence order; returns [] when none found.

RED markers:
  test_compute_fk_grade_matches_textstat_reference
  test_find_banned_words_returns_matches_in_order
"""

from __future__ import annotations

import pytest
import textstat

from gov_copy_postprocess.readability import compute_fk_grade
from gov_copy_postprocess.banned import find_banned_words


SAMPLE_TEXT = "You can apply for benefits online."


@pytest.mark.unit
class TestComputeFkGrade:
    """compute_fk_grade delegates to textstat.flesch_kincaid_grade."""

    # [test_compute_fk_grade_matches_textstat_reference]
    def test_compute_fk_grade_matches_textstat_reference(self) -> None:
        """compute_fk_grade must match textstat.flesch_kincaid_grade within 1e-6."""
        expected = textstat.flesch_kincaid_grade(SAMPLE_TEXT)
        result = compute_fk_grade(SAMPLE_TEXT)
        assert abs(result - expected) < 1e-6, (
            f"compute_fk_grade({SAMPLE_TEXT!r}) returned {result!r}; "
            f"expected {expected!r} (within 1e-6)"
        )


@pytest.mark.unit
class TestFindBannedWords:
    """find_banned_words scans text for banned words, case-insensitively, in order."""

    # [test_find_banned_words_returns_matches_in_order]
    def test_find_banned_words_returns_matches_in_order(self) -> None:
        """Returns matched banned words in first-occurrence order."""
        text = "Please Utilize the portal and leverage data."
        banned: set[str] = {"utilize", "leverage"}
        result = find_banned_words(text, banned)
        assert result == ["utilize", "leverage"], (
            f"find_banned_words({text!r}, {banned!r}) returned {result!r}; "
            f"expected ['utilize', 'leverage'] in first-occurrence order"
        )

    def test_find_banned_words_returns_empty_when_no_match(self) -> None:
        """Returns empty list when no banned words appear in text."""
        text = "All good text."
        banned: set[str] = {"utilize"}
        result = find_banned_words(text, banned)
        assert result == [], (
            f"find_banned_words({text!r}, {banned!r}) returned {result!r}; "
            f"expected []"
        )

    def test_find_banned_words_case_insensitive(self) -> None:
        """Detects banned words regardless of capitalisation in the source text."""
        text = "LEVERAGE this UTILIZE that."
        banned: set[str] = {"leverage", "utilize"}
        result = find_banned_words(text, banned)
        # Both words must be detected; order follows first occurrence in text.
        assert set(result) == {"leverage", "utilize"}, (
            f"find_banned_words({text!r}, {banned!r}) returned {result!r}; "
            f"expected both 'leverage' and 'utilize' (case-insensitive)"
        )
        assert result.index("leverage") < result.index("utilize"), (
            "Expected 'leverage' to appear before 'utilize' (first-occurrence order)"
        )


# ---------------------------------------------------------------------------
# RED tests for is_active_voice — task 508b-9ca7-4317-4caa
# ---------------------------------------------------------------------------

from gov_copy_postprocess.voice import is_active_voice  # noqa: E402


@pytest.mark.unit
class TestIsActiveVoice:
    """is_active_voice returns True for active sentences, False for passive ones."""

    # [test_is_active_voice_active_sentence]
    def test_is_active_voice_active_sentence(self) -> None:
        """'You can apply online.' is an active-voice sentence."""
        assert is_active_voice("You can apply online.") is True, (
            "is_active_voice('You can apply online.') must return True"
        )

    def test_is_active_voice_passive_reviewed_by_staff(self) -> None:
        """'Applications are reviewed by staff.' is a passive-voice sentence."""
        assert is_active_voice("Applications are reviewed by staff.") is False, (
            "is_active_voice('Applications are reviewed by staff.') must return False"
        )

    def test_is_active_voice_passive_was_submitted(self) -> None:
        """'The form was submitted yesterday.' is a passive-voice sentence."""
        assert is_active_voice("The form was submitted yesterday.") is False, (
            "is_active_voice('The form was submitted yesterday.') must return False"
        )

    def test_is_active_voice_active_we_process(self) -> None:
        """'We process forms daily.' is an active-voice sentence."""
        assert is_active_voice("We process forms daily.") is True, (
            "is_active_voice('We process forms daily.') must return True"
        )


# ---------------------------------------------------------------------------
# RED tests for build_deviations — task e811-ed8b-bba6-41b1
# ---------------------------------------------------------------------------

from gov_copy_postprocess.deviations import build_deviations  # noqa: E402


def _make_item(
    fk_grade: float = 5.0,
    banned_words_found: list | None = None,
    active_voice: bool = True,
    deviations: list | None = None,
) -> dict:
    """Construct a minimal item dict matching the gov_copy_postprocess item shape."""
    return {
        "checks": {
            "fk_grade": fk_grade,
            "banned_words_found": banned_words_found if banned_words_found is not None else [],
            "active_voice": active_voice,
        },
        "rationale": {
            "deviations": deviations if deviations is not None else [],
        },
    }


@pytest.mark.unit
class TestBuildDeviations:
    """build_deviations produces rationale.deviations[] entries with correct reason values."""

    # [test_build_deviations_new_entry_gets_unjustified_reason]
    def test_build_deviations_new_entry_gets_unjustified_reason(self) -> None:
        """Failing item with no existing deviation entry → new entry with reason='unjustified'."""
        item = _make_item(fk_grade=14.0, deviations=[])
        result = build_deviations(item, existing_deviations=[], fk_max=12)
        rule_ids = [d["rule_id"] for d in result]
        assert "fk_grade" in rule_ids, (
            f"Expected 'fk_grade' deviation in result; got rule_ids={rule_ids!r}"
        )
        fk_entry = next(d for d in result if d["rule_id"] == "fk_grade")
        assert fk_entry["reason"] == "unjustified", (
            f"Expected reason='unjustified' for new fk_grade deviation; got {fk_entry['reason']!r}"
        )

    def test_build_deviations_preserves_non_empty_reason(self) -> None:
        """Failing item with existing deviation with non-empty reason → reason preserved verbatim."""
        existing = [{"rule_id": "fk_grade", "reason": "Approved by content team"}]
        item = _make_item(fk_grade=14.0, deviations=existing)
        result = build_deviations(item, existing_deviations=existing, fk_max=12)
        fk_entry = next((d for d in result if d["rule_id"] == "fk_grade"), None)
        assert fk_entry is not None, "Expected 'fk_grade' entry in result"
        assert fk_entry["reason"] == "Approved by content team", (
            f"Expected preserved reason 'Approved by content team'; got {fk_entry['reason']!r}"
        )

    def test_build_deviations_empty_reason_gets_unjustified(self) -> None:
        """Failing item with existing deviation with empty reason → reason becomes 'unjustified'."""
        existing = [{"rule_id": "banned_words_found", "reason": ""}]
        item = _make_item(banned_words_found=["utilize"], deviations=existing)
        result = build_deviations(item, existing_deviations=existing, fk_max=12)
        bw_entry = next((d for d in result if d["rule_id"] == "banned_words_found"), None)
        assert bw_entry is not None, "Expected 'banned_words_found' entry in result"
        assert bw_entry["reason"] == "unjustified", (
            f"Expected reason='unjustified' for empty-reason deviation; got {bw_entry['reason']!r}"
        )

    def test_build_deviations_passing_item_produces_no_deviation(self) -> None:
        """Passing item (all checks in bounds) → no deviations emitted for owned rule_ids."""
        item = _make_item(fk_grade=8.0, banned_words_found=[], active_voice=True, deviations=[])
        result = build_deviations(item, existing_deviations=[], fk_max=12)
        owned_rule_ids = {"fk_grade", "banned_words_found", "active_voice"}
        emitted = {d["rule_id"] for d in result if d["rule_id"] in owned_rule_ids}
        assert emitted == set(), (
            f"Expected no owned deviations for passing item; got {emitted!r}"
        )

    def test_build_deviations_preserves_unowned_rule_ids(self) -> None:
        """Deviation entries for rule_ids outside fk_grade/banned_words_found/active_voice are
        passed through unchanged."""
        unrelated = [{"rule_id": "sentence_length", "reason": "Long sentence approved"}]
        item = _make_item(deviations=unrelated)
        result = build_deviations(item, existing_deviations=unrelated, fk_max=12)
        unrelated_in_result = [d for d in result if d["rule_id"] == "sentence_length"]
        assert len(unrelated_in_result) == 1, (
            f"Expected unrelated 'sentence_length' entry preserved in result; got {result!r}"
        )
        assert unrelated_in_result[0]["reason"] == "Long sentence approved", (
            f"Expected unrelated reason preserved verbatim; got {unrelated_in_result[0]['reason']!r}"
        )

    def test_build_deviations_active_voice_failure_gets_unjustified(self) -> None:
        """Passive-voice item with no existing deviation → new entry with reason='unjustified'."""
        item = _make_item(active_voice=False, deviations=[])
        result = build_deviations(item, existing_deviations=[], fk_max=12)
        av_entry = next((d for d in result if d["rule_id"] == "active_voice"), None)
        assert av_entry is not None, "Expected 'active_voice' deviation entry in result"
        assert av_entry["reason"] == "unjustified", (
            f"Expected reason='unjustified' for new active_voice deviation; got {av_entry['reason']!r}"
        )


# ---------------------------------------------------------------------------
# RED tests for load_gov_copy_config — task e475-e682-5942-446a
# ---------------------------------------------------------------------------

import configparser  # noqa: E402
from pathlib import Path  # noqa: E402

from gov_copy_postprocess.config import load_gov_copy_config, ConfigError  # noqa: E402


@pytest.mark.unit
class TestLoadGovCopyConfig:
    """load_gov_copy_config reads [gov_copy] section from an INI config file."""

    # [test_load_gov_copy_config_parses_valid_config]
    def test_load_gov_copy_config_parses_valid_config(self, tmp_path: Path) -> None:
        """Valid [gov_copy] block returns object with correct banned_words, fk_max, closing_ratio."""
        config_file = tmp_path / "gov-copy.conf"
        config_file.write_text(
            "[gov_copy]\n"
            "banned_words = utilize,leverage\n"
            "fk_max = 8\n"
            "closing_ratio = 0.95\n"
        )
        result = load_gov_copy_config(config_file)
        assert result.banned_words == {"utilize", "leverage"}, (
            f"Expected banned_words={{'utilize','leverage'}}; got {result.banned_words!r}"
        )
        assert result.fk_max == 8, (
            f"Expected fk_max=8; got {result.fk_max!r}"
        )
        assert abs(result.closing_ratio - 0.95) < 1e-9, (
            f"Expected closing_ratio=0.95; got {result.closing_ratio!r}"
        )

    def test_load_gov_copy_config_raises_on_missing_file(self, tmp_path: Path) -> None:
        """Missing config file at path raises ConfigError."""
        missing = tmp_path / "does_not_exist.conf"
        with pytest.raises(ConfigError):
            load_gov_copy_config(missing)

    def test_load_gov_copy_config_raises_on_missing_section(self, tmp_path: Path) -> None:
        """Config file without [gov_copy] section raises ConfigError."""
        config_file = tmp_path / "other.conf"
        config_file.write_text(
            "[other_section]\n"
            "banned_words = utilize\n"
        )
        with pytest.raises(ConfigError):
            load_gov_copy_config(config_file)

    def test_load_gov_copy_config_raises_on_unparseable_fk_max(self, tmp_path: Path) -> None:
        """fk_max value that cannot be parsed as int raises ConfigError."""
        config_file = tmp_path / "bad_fk.conf"
        config_file.write_text(
            "[gov_copy]\n"
            "banned_words = utilize\n"
            "fk_max = abc\n"
            "closing_ratio = 0.95\n"
        )
        with pytest.raises(ConfigError):
            load_gov_copy_config(config_file)
