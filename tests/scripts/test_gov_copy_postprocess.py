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
            f"find_banned_words({text!r}, {banned!r}) returned {result!r}; expected []"
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
            "banned_words_found": banned_words_found
            if banned_words_found is not None
            else [],
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
        bw_entry = next(
            (d for d in result if d["rule_id"] == "banned_words_found"), None
        )
        assert bw_entry is not None, "Expected 'banned_words_found' entry in result"
        assert bw_entry["reason"] == "unjustified", (
            f"Expected reason='unjustified' for empty-reason deviation; got {bw_entry['reason']!r}"
        )

    def test_build_deviations_passing_item_produces_no_deviation(self) -> None:
        """Passing item (all checks in bounds) → no deviations emitted for owned rule_ids."""
        item = _make_item(
            fk_grade=8.0, banned_words_found=[], active_voice=True, deviations=[]
        )
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

from pathlib import Path  # noqa: E402

from gov_copy_postprocess.config import load_gov_copy_config, ConfigError  # noqa: E402


@pytest.mark.unit
class TestLoadGovCopyConfig:
    """load_gov_copy_config reads flat dot-notation gov_copy.* keys.

    Matches the format parsed by read-config.sh — INI section headers are
    deliberately NOT supported (silently ignored by read-config.sh).
    """

    # [test_load_gov_copy_config_parses_valid_config]
    def test_load_gov_copy_config_parses_valid_config(self, tmp_path: Path) -> None:
        """Flat gov_copy.* keys return object with correct banned_words, fk_max, closing_ratio."""
        config_file = tmp_path / "gov-copy.conf"
        config_file.write_text(
            "gov_copy.banned_words=utilize,leverage\n"
            "gov_copy.fk_max=8\n"
            "gov_copy.closing_ratio=0.95\n"
        )
        result = load_gov_copy_config(config_file)
        assert result.banned_words == {"utilize", "leverage"}, (
            f"Expected banned_words={{'utilize','leverage'}}; got {result.banned_words!r}"
        )
        assert result.fk_max == 8, f"Expected fk_max=8; got {result.fk_max!r}"
        assert abs(result.closing_ratio - 0.95) < 1e-9, (
            f"Expected closing_ratio=0.95; got {result.closing_ratio!r}"
        )

    def test_load_gov_copy_config_raises_on_missing_file(self, tmp_path: Path) -> None:
        """Missing config file at path raises ConfigError."""
        missing = tmp_path / "does_not_exist.conf"
        with pytest.raises(ConfigError):
            load_gov_copy_config(missing)

    def test_load_gov_copy_config_raises_on_missing_keys(self, tmp_path: Path) -> None:
        """Config file without gov_copy.* keys raises ConfigError listing the missing keys."""
        config_file = tmp_path / "other.conf"
        config_file.write_text("other.banned_words=utilize\n")
        with pytest.raises(ConfigError) as excinfo:
            load_gov_copy_config(config_file)
        assert "gov_copy" in str(excinfo.value)

    def test_load_gov_copy_config_ignores_ini_section_headers(
        self, tmp_path: Path
    ) -> None:
        """INI section headers are skipped; the parser still requires flat dot-notation keys."""
        config_file = tmp_path / "ini.conf"
        config_file.write_text(
            "[gov_copy]\nbanned_words=utilize\nfk_max=8\nclosing_ratio=0.95\n"
        )
        # Section header is ignored; the indented keys would still parse but the canonical
        # gov_copy.* keys are absent, so this must fail with a "missing keys" ConfigError.
        with pytest.raises(ConfigError) as excinfo:
            load_gov_copy_config(config_file)
        assert "missing" in str(excinfo.value).lower() or "gov_copy" in str(
            excinfo.value
        )

    def test_load_gov_copy_config_raises_on_unparseable_fk_max(
        self, tmp_path: Path
    ) -> None:
        """fk_max value that cannot be parsed as int raises ConfigError."""
        config_file = tmp_path / "bad_fk.conf"
        config_file.write_text(
            "gov_copy.banned_words=utilize\n"
            "gov_copy.fk_max=abc\n"
            "gov_copy.closing_ratio=0.95\n"
        )
        with pytest.raises(ConfigError):
            load_gov_copy_config(config_file)


# ---------------------------------------------------------------------------
# RED tests for __main__ pipeline — task 2e31-d874-7bd1-47fe
# ---------------------------------------------------------------------------

import subprocess  # noqa: E402
import sys  # noqa: E402
import yaml  # noqa: E402


def _write_config(tmp_path: Path, **overrides) -> Path:
    """Write a minimal flat dot-notation gov_copy.* config file; overrides replace defaults."""
    defaults = {
        "banned_words": "utilize,leverage",
        "fk_max": "12",
        "closing_ratio": "0.80",
    }
    defaults.update(overrides)
    cfg = tmp_path / "gov-copy.conf"
    cfg.write_text(
        f"gov_copy.banned_words={defaults['banned_words']}\n"
        f"gov_copy.fk_max={defaults['fk_max']}\n"
        f"gov_copy.closing_ratio={defaults['closing_ratio']}\n"
    )
    return cfg


def _write_artifact(
    tmp_path: Path, items: list, filename: str = "artifact.yaml"
) -> Path:
    """Write a gov-copy artifact YAML with the given items list."""
    artifact = tmp_path / filename
    artifact.write_text(yaml.dump({"schema_version": 1, "items": items}))
    return artifact


def _run_pipeline(
    artifact_path: Path, config_path: Path
) -> subprocess.CompletedProcess:
    """Run the __main__ pipeline via subprocess; always returns (never raises)."""
    repo_root = Path(__file__).resolve().parents[2]
    return subprocess.run(
        [
            sys.executable,
            "-m",
            "plugins.dso.scripts.gov_copy_postprocess",
            str(artifact_path),
            "--config-path",
            str(config_path),
        ],
        capture_output=True,
        text=True,
        timeout=30,
        cwd=str(repo_root),
    )


@pytest.mark.unit
class TestMainPipelineEmptyItems:
    """(a) Empty items[] artifact → exit 0, summary reports all-pass state."""

    # [test_main_pipeline_empty_items_exits_zero]
    def test_main_pipeline_empty_items_exits_zero(self, tmp_path: Path) -> None:
        """Empty items[] artifact must exit 0 (no items to fail)."""
        artifact = _write_artifact(tmp_path, items=[])
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        assert result.returncode == 0, (
            f"Expected exit 0 for empty items[]; got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )

    def test_main_pipeline_empty_items_stdout_all_pass(self, tmp_path: Path) -> None:
        """Empty items[] artifact stdout must contain pass_ratio: 1.00
        and closing_threshold_met: true."""
        artifact = _write_artifact(tmp_path, items=[])
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        stdout = result.stdout.lower()
        assert "pass_ratio: 1.00" in stdout, (
            f"Expected stdout to contain 'pass_ratio: 1.00' for empty-items artifact.\n"
            f"stdout={result.stdout!r}"
        )
        assert "closing_threshold_met: true" in stdout, (
            f"Expected stdout to contain 'closing_threshold_met: true'.\n"
            f"stdout={result.stdout!r}"
        )


@pytest.mark.unit
class TestMainPipelineEmptyText:
    """(b) Item with empty text → no crash, banned_words_found==[], voice computed."""

    # [test_main_pipeline_empty_text_no_crash]
    def test_main_pipeline_empty_text_no_crash(self, tmp_path: Path) -> None:
        """Item with empty-string text values must exit 0 and write a summary to stdout."""
        items = [
            {
                "id": "empty-item",
                "values": {
                    "label": "",
                    "hint": "",
                    "errors": {},
                },
                "rationale": {
                    "rule_ids": [],
                    "conflicts": [],
                    "deviations": [],
                },
                "checks": {
                    "fk_grade": 0,
                    "banned_words_found": [],
                    "active_voice": True,
                    "source": "deterministic-post-processor",
                },
            }
        ]
        artifact = _write_artifact(tmp_path, items=items)
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        assert result.returncode == 0, (
            f"Empty-text item must exit 0 (fk_grade=0 passes fk_max=12, no banned words); "
            f"got returncode={result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )
        assert "traceback" not in result.stderr.lower(), (
            f"Empty-text item must not raise an exception.\nstderr={result.stderr!r}"
        )

    def test_main_pipeline_empty_text_banned_words_empty(self, tmp_path: Path) -> None:
        """Item with empty text → pipeline exits 0 and stdout contains no banned-word hits."""
        items = [
            {
                "id": "empty-item",
                "values": {"label": "", "hint": "", "errors": {}},
                "rationale": {"rule_ids": [], "conflicts": [], "deviations": []},
                "checks": {
                    "fk_grade": 0,
                    "banned_words_found": [],
                    "active_voice": True,
                    "source": "deterministic-post-processor",
                },
            }
        ]
        artifact = _write_artifact(tmp_path, items=items)
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        # Pipeline must succeed (not crash) and produce a summary
        assert result.returncode == 0, (
            f"Empty-text item must exit 0; got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )
        # Stdout must contain a summary line (signals the pipeline ran)
        assert "pass_ratio" in result.stdout.lower(), (
            f"Expected stdout to contain 'pass_ratio' summary field.\n"
            f"stdout={result.stdout!r}"
        )
        # Stdout must NOT report banned words found for an empty-text item
        assert "utilize" not in result.stdout and "leverage" not in result.stdout, (
            f"Empty-text item must not produce banned_words_found entries.\n"
            f"stdout={result.stdout!r}"
        )


@pytest.mark.unit
class TestMainPipelineLargeText:
    """(c) Item with text >10k chars → completes within 30s without timeout."""

    # [test_main_pipeline_large_text_completes_within_30s]
    def test_main_pipeline_large_text_completes_within_30s(
        self, tmp_path: Path
    ) -> None:
        """Pipeline with a >10k character text item must complete within 30 seconds."""
        large_text = "You can apply for benefits online. " * 300  # ~10 500 chars
        assert len(large_text) > 10_000, "Precondition: text must exceed 10k chars"
        items = [
            {
                "id": "large-text-item",
                "values": {
                    "label": large_text[:200],
                    "hint": large_text,
                    "errors": {},
                },
                "rationale": {"rule_ids": [], "conflicts": [], "deviations": []},
                "checks": {
                    "fk_grade": 5,
                    "banned_words_found": [],
                    "active_voice": True,
                    "source": "deterministic-post-processor",
                },
            }
        ]
        artifact = _write_artifact(tmp_path, items=items)
        cfg = _write_config(tmp_path)
        # subprocess.run timeout=30 will raise subprocess.TimeoutExpired if exceeded
        result = _run_pipeline(artifact, cfg)
        # If we reach here the pipeline completed within 30s; verify it exited cleanly
        assert result.returncode == 0, (
            f"Large-text item pipeline must exit 0 (all checks pass for this item); "
            f"got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )


@pytest.mark.unit
class TestMainPipelineCrossFieldPassiveVoiceRegression:
    """Regression test for the '. ' field-joiner fix in _get_item_text.

    Before the fix, fields were joined with a single space, so a be-verb
    at the end of one field could match a past-participle at the start
    of the next field — a cross-field false-positive passive match.

    The classic adversarial case: label='Form status is' + hint='updated
    daily' joined to 'Form status is updated daily' would match the
    passive regex \\b(am|is|...)\\b\\s+...ed\\b even though NEITHER field
    is passive on its own.

    The fix changed the joiner to '. ' (period+space) so the regex \\s+
    bridge cannot cross the field boundary. This test pins that fix.
    """

    # [test_main_pipeline_no_cross_field_passive_false_positive]
    def test_main_pipeline_no_cross_field_passive_false_positive(
        self, tmp_path: Path
    ) -> None:
        """label+hint joining must not synthesize a cross-field passive match."""
        # Adversarial item: each field is active-voice on its own, but
        # concatenated with a single space they would form 'is updated'.
        item = {
            "id": "cross-field-adversarial",
            "values": {
                "label": "Form status is",
                "hint": "updated daily",
                "errors": {},
            },
            "rationale": {"rule_ids": [], "conflicts": [], "deviations": []},
        }
        artifact = _write_artifact(tmp_path, items=[item])
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        assert result.returncode == 0, (
            f"Pipeline should exit 0 for adversarial-but-passing item; "
            f"got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )
        written = yaml.safe_load(artifact.read_text())
        checks = written["items"][0]["checks"]
        assert checks["active_voice"] is True, (
            f"Cross-field false-positive regression: 'Form status is' + "
            f"'updated daily' must NOT be detected as passive. "
            f"Got active_voice={checks['active_voice']!r}. "
            f"This likely means _get_item_text reverted to single-space "
            f"joining and the regex bridged the field boundary."
        )
        # Also verify no spurious active_voice deviation was recorded
        devs = written["items"][0]["rationale"]["deviations"]
        active_voice_devs = [d for d in devs if d.get("rule_id") == "active_voice"]
        assert not active_voice_devs, (
            f"No active_voice deviation expected; got {active_voice_devs!r}"
        )


# ---------------------------------------------------------------------------
# RED tests for __main__ pipeline — task 1211-d27b-cbd8-4532
# Covers: LLM-overwrite, per-rule source attribution, summary/exit codes,
# deviations with rule_id, YAML write-back, atomic write, CLI contract.
# ---------------------------------------------------------------------------


def _make_passing_item(item_id: str = "p1") -> dict:
    """Return a minimal item that passes all three rules (fk_grade ≤ 12, no banned, active)."""
    return {
        "id": item_id,
        "values": {
            "label": "You can apply online.",
            "hint": "Submit your form today.",
            "errors": {},
        },
        "rationale": {
            "rule_ids": [],
            "conflicts": [],
            "deviations": [],
        },
        "checks": {
            "fk_grade": 99,  # LLM-supplied; pipeline MUST overwrite with computed value
            "banned_words_found": [],
            "active_voice": True,
            "source": "llm",  # LLM-supplied source; pipeline MUST replace per-rule
        },
    }


def _make_failing_item(item_id: str = "f1") -> dict:
    """Return an item that fails the active_voice rule (passive sentence) and passes the others."""
    return {
        "id": item_id,
        "values": {
            "label": "Applications are reviewed.",
            "hint": "Applications are reviewed by staff.",
            "errors": {},
        },
        "rationale": {
            "rule_ids": [],
            "conflicts": [],
            "deviations": [],
        },
        "checks": {
            "fk_grade": 5,
            "banned_words_found": [],
            "active_voice": True,  # LLM says True; pipeline MUST compute False (passive)
            "source": "llm",
        },
    }


# --- Test 1: LLM-supplied checks.fk_grade is OVERWRITTEN by deterministic value ---


@pytest.mark.unit
class TestMainPipelineOverwritesLLMFkGrade:
    """LLM-supplied checks.fk_grade=99 is replaced by deterministic Flesch-Kincaid value."""

    # [test_main_pipeline_overwrites_llm_fk_grade]
    def test_main_pipeline_overwrites_llm_fk_grade(self, tmp_path: Path) -> None:
        """Pipeline must overwrite LLM fk_grade=99 with deterministic computed value ≠ 99."""
        item = _make_passing_item("item-fk-overwrite")
        artifact = _write_artifact(tmp_path, items=[item])
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        assert result.returncode == 0, (
            f"Passing-text item must exit 0; got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )
        written = yaml.safe_load(artifact.read_text())
        written_item = written["items"][0]
        fk_grade = written_item["checks"]["fk_grade"]
        assert fk_grade != 99, (
            f"Pipeline must overwrite LLM fk_grade=99 with computed value; "
            f"got fk_grade={fk_grade!r} in written artifact"
        )


# --- Test 2: Per-rule source fields (NOT a single top-level checks.source) ---


@pytest.mark.unit
class TestMainPipelineSourceAttribution:
    """Pipeline writes a single top-level checks.source='deterministic-post-processor'.

    This matches the gov-copy-artifact contract (flat checks shape with one
    top-level source string). The earlier per-rule {value, source} shape was
    rejected by the validator (check-gov-copy-artifact.sh) and contradicted
    the contract spec at docs/contracts/gov-copy-artifact.md.
    """

    # [test_main_pipeline_source_is_post_processor]
    def test_main_pipeline_source_is_post_processor(self, tmp_path: Path) -> None:
        """checks.source must be exactly 'deterministic-post-processor' per contract."""
        item = _make_passing_item("src-flat")
        artifact = _write_artifact(tmp_path, items=[item])
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr={result.stderr!r}"
        )
        written = yaml.safe_load(artifact.read_text())
        checks = written["items"][0]["checks"]
        assert checks.get("source") == "deterministic-post-processor", (
            f"checks.source must be 'deterministic-post-processor' (contract value); "
            f"got {checks.get('source')!r}"
        )

    def test_main_pipeline_checks_are_flat_primitives(self, tmp_path: Path) -> None:
        """checks.fk_grade, banned_words_found, active_voice are primitives, not dicts."""
        item = _make_passing_item("src-primitives")
        artifact = _write_artifact(tmp_path, items=[item])
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr={result.stderr!r}"
        )
        written = yaml.safe_load(artifact.read_text())
        checks = written["items"][0]["checks"]
        assert isinstance(checks["fk_grade"], int), (
            f"checks.fk_grade must be int per contract; got {type(checks['fk_grade']).__name__}"
        )
        assert isinstance(checks["banned_words_found"], list), (
            f"checks.banned_words_found must be list per contract; got {type(checks['banned_words_found']).__name__}"
        )
        assert isinstance(checks["active_voice"], bool), (
            f"checks.active_voice must be bool per contract; got {type(checks['active_voice']).__name__}"
        )


# --- Test 3: 100%-pass artifact → exit 0, closing_threshold_met: true ---


@pytest.mark.unit
class TestMainPipelineAllPassExit:
    """All-passing artifact → exit 0 with closing_threshold_met: true in stdout."""

    # [test_main_pipeline_all_pass_exit_zero]
    def test_main_pipeline_all_pass_exit_zero(self, tmp_path: Path) -> None:
        """100%-pass artifact must exit 0."""
        items = [_make_passing_item(f"p{i}") for i in range(3)]
        artifact = _write_artifact(tmp_path, items=items)
        cfg = _write_config(tmp_path, closing_ratio="0.95")
        result = _run_pipeline(artifact, cfg)
        assert result.returncode == 0, (
            f"100%-pass artifact must exit 0; got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )

    def test_main_pipeline_all_pass_closing_threshold_true(
        self, tmp_path: Path
    ) -> None:
        """100%-pass artifact stdout must contain 'closing_threshold_met: true'."""
        items = [_make_passing_item(f"p{i}") for i in range(3)]
        artifact = _write_artifact(tmp_path, items=items)
        cfg = _write_config(tmp_path, closing_ratio="0.95")
        result = _run_pipeline(artifact, cfg)
        assert "closing_threshold_met: true" in result.stdout.lower(), (
            f"Expected 'closing_threshold_met: true' in stdout.\n"
            f"stdout={result.stdout!r}"
        )

    def test_main_pipeline_all_pass_pass_ratio_in_stdout(self, tmp_path: Path) -> None:
        """100%-pass artifact stdout must contain 'pass_ratio:' field."""
        items = [_make_passing_item(f"p{i}") for i in range(3)]
        artifact = _write_artifact(tmp_path, items=items)
        cfg = _write_config(tmp_path, closing_ratio="0.95")
        result = _run_pipeline(artifact, cfg)
        assert "pass_ratio:" in result.stdout.lower(), (
            f"Expected 'pass_ratio:' in stdout.\nstdout={result.stdout!r}"
        )


# --- Test 4: <95%-pass artifact → exit non-zero, closing_threshold_met: false,
#             summary includes pass_rate, total_items, deviations_count ---


@pytest.mark.unit
class TestMainPipelineBelowThresholdExit:
    """Below-threshold artifact → exit non-zero with closing_threshold_met: false."""

    # [test_main_pipeline_below_threshold_exit_nonzero]
    def test_main_pipeline_below_threshold_exit_nonzero(self, tmp_path: Path) -> None:
        """Artifact with pass_rate < 0.95 must exit non-zero."""
        # 1 passing + 19 failing = 5% pass rate, well below 95%
        passing = [_make_passing_item("p1")]
        failing = [_make_failing_item(f"f{i}") for i in range(19)]
        artifact = _write_artifact(tmp_path, items=passing + failing)
        cfg = _write_config(tmp_path, closing_ratio="0.95")
        result = _run_pipeline(artifact, cfg)
        assert result.returncode != 0, (
            f"Artifact with pass_ratio<0.95 must exit non-zero; got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )

    def test_main_pipeline_below_threshold_closing_false(self, tmp_path: Path) -> None:
        """Below-threshold stdout must contain 'closing_threshold_met: false'."""
        passing = [_make_passing_item("p1")]
        failing = [_make_failing_item(f"f{i}") for i in range(19)]
        artifact = _write_artifact(tmp_path, items=passing + failing)
        cfg = _write_config(tmp_path, closing_ratio="0.95")
        result = _run_pipeline(artifact, cfg)
        assert "closing_threshold_met: false" in result.stdout.lower(), (
            f"Expected 'closing_threshold_met: false' in stdout.\n"
            f"stdout={result.stdout!r}"
        )

    def test_main_pipeline_below_threshold_summary_fields(self, tmp_path: Path) -> None:
        """Below-threshold stdout must contain pass_rate, total_items, and deviations_count."""
        passing = [_make_passing_item("p1")]
        failing = [_make_failing_item(f"f{i}") for i in range(19)]
        artifact = _write_artifact(tmp_path, items=passing + failing)
        cfg = _write_config(tmp_path, closing_ratio="0.95")
        result = _run_pipeline(artifact, cfg)
        stdout_lower = result.stdout.lower()
        for field in ("pass_ratio:", "total_items:", "deviations_count:"):
            assert field in stdout_lower, (
                f"Expected '{field}' in stdout summary.\nstdout={result.stdout!r}"
            )


# --- Test 5: Item failing ONE rule appears in rationale.deviations with rule_id + reason ---


@pytest.mark.unit
class TestMainPipelineDeviationsOneRule:
    """Item failing one rule appears in rationale.deviations with rule_id and populated reason."""

    # [test_main_pipeline_deviations_single_rule_failure]
    def test_main_pipeline_deviations_single_rule_failure(self, tmp_path: Path) -> None:
        """Item with banned_words_found non-empty (others passing) appears in deviations."""
        item = {
            "id": "banned-only",
            "values": {
                "label": "Please utilize the portal.",  # 'utilize' is banned
                "hint": "Submit your form today.",
                "errors": {},
            },
            "rationale": {
                "rule_ids": [],
                "conflicts": [],
                "deviations": [],
            },
            "checks": {
                "fk_grade": 5,
                "banned_words_found": ["utilize"],
                "active_voice": True,
                "source": "llm",
            },
        }
        artifact = _write_artifact(tmp_path, items=[item])
        cfg = _write_config(tmp_path, closing_ratio="0.95")
        _run_pipeline(artifact, cfg)
        written = yaml.safe_load(artifact.read_text())
        deviations = written["items"][0]["rationale"]["deviations"]
        rule_ids = [d.get("rule_id") for d in deviations]
        assert "banned_words_found" in rule_ids, (
            f"Item with banned_words_found=['utilize'] must appear in deviations with "
            f"rule_id='banned_words_found'; got deviations={deviations!r}"
        )
        banned_dev = next(
            d for d in deviations if d.get("rule_id") == "banned_words_found"
        )
        assert banned_dev.get("reason"), (
            f"Deviation entry must have a non-empty reason; got {banned_dev!r}"
        )

    def test_main_pipeline_deviations_only_for_failing_rule(
        self, tmp_path: Path
    ) -> None:
        """Item failing banned_words_found only must NOT have active_voice or fk_grade deviations."""
        item = {
            "id": "banned-only-strict",
            "values": {
                "label": "Please utilize the portal.",
                "hint": "Submit your form today.",
                "errors": {},
            },
            "rationale": {
                "rule_ids": [],
                "conflicts": [],
                "deviations": [],
            },
            "checks": {
                "fk_grade": 5,
                "banned_words_found": ["utilize"],
                "active_voice": True,
                "source": "llm",
            },
        }
        artifact = _write_artifact(tmp_path, items=[item])
        cfg = _write_config(tmp_path, closing_ratio="0.95")
        _run_pipeline(artifact, cfg)
        written = yaml.safe_load(artifact.read_text())
        deviations = written["items"][0]["rationale"]["deviations"]
        rule_ids = [d.get("rule_id") for d in deviations]
        assert "fk_grade" not in rule_ids, (
            f"fk_grade must NOT be in deviations when fk_grade passes; got {rule_ids!r}"
        )
        assert "active_voice" not in rule_ids, (
            f"active_voice must NOT be in deviations when active_voice passes; got {rule_ids!r}"
        )


# --- Test 6: YAML write-back preserves non-touched sibling fields ---


@pytest.mark.unit
class TestMainPipelineYAMLWriteback:
    """Artifact written back to disk in YAML; non-touched fields preserved."""

    # [test_main_pipeline_yaml_writeback_preserves_sibling_keys]
    def test_main_pipeline_yaml_writeback_preserves_sibling_keys(
        self, tmp_path: Path
    ) -> None:
        """Arbitrary sibling top-level keys and item.id are preserved after pipeline run."""
        item = _make_passing_item("preserved-id")
        artifact = tmp_path / "artifact.yaml"
        artifact.write_text(
            yaml.dump(
                {
                    "schema_version": 1,
                    "arbitrary_sibling_key": "must-be-preserved",
                    "items": [item],
                }
            )
        )
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr={result.stderr!r}"
        )
        written = yaml.safe_load(artifact.read_text())
        assert written.get("arbitrary_sibling_key") == "must-be-preserved", (
            f"Sibling key 'arbitrary_sibling_key' must be preserved in written artifact; "
            f"got {written!r}"
        )
        assert written["items"][0]["id"] == "preserved-id", (
            f"Item id must be preserved; got {written['items'][0]['id']!r}"
        )

    def test_main_pipeline_yaml_writeback_valid_yaml(self, tmp_path: Path) -> None:
        """Artifact on disk must be valid YAML after pipeline run (atomic write)."""
        item = _make_passing_item("yaml-valid")
        artifact = _write_artifact(tmp_path, items=[item])
        cfg = _write_config(tmp_path)
        result = _run_pipeline(artifact, cfg)
        assert result.returncode == 0, (
            f"Expected exit 0; got {result.returncode}.\nstderr={result.stderr!r}"
        )
        content = artifact.read_text()
        # Must parse without exception
        parsed = yaml.safe_load(content)
        assert isinstance(parsed, dict), (
            f"Written artifact must be a valid YAML dict; got {type(parsed)!r}"
        )
        assert "items" in parsed, (
            f"Written artifact must contain 'items' key; got keys={list(parsed.keys())!r}"
        )


# --- Test 7: CLI contract ---


@pytest.mark.unit
class TestMainPipelineCLIContract:
    """CLI: --help exits 0; missing artifact_path → non-zero; missing --config-path → non-zero."""

    # [test_main_pipeline_help_exits_zero]
    def test_main_pipeline_help_exits_zero(self) -> None:
        """--help must exit 0 and include usage text in output."""
        repo_root = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "plugins.dso.scripts.gov_copy_postprocess",
                "--help",
            ],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=str(repo_root),
        )
        assert result.returncode == 0, (
            f"--help must exit 0; got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )
        combined = (result.stdout + result.stderr).lower()
        assert "usage" in combined or "artifact" in combined, (
            f"--help output must include usage text; got:\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )

    def test_main_pipeline_missing_artifact_path_exits_nonzero(self) -> None:
        """No artifact_path argument → exit non-zero with clear error."""
        repo_root = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [sys.executable, "-m", "plugins.dso.scripts.gov_copy_postprocess"],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=str(repo_root),
        )
        assert result.returncode != 0, (
            f"Missing artifact_path must exit non-zero; got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )

    def test_main_pipeline_missing_config_path_exits_nonzero(
        self, tmp_path: Path
    ) -> None:
        """No --config-path argument → exit non-zero with clear error."""
        artifact = _write_artifact(tmp_path, items=[_make_passing_item()])
        repo_root = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "plugins.dso.scripts.gov_copy_postprocess",
                str(artifact),
                # intentionally omit --config-path
            ],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=str(repo_root),
        )
        assert result.returncode != 0, (
            f"Missing --config-path must exit non-zero; got {result.returncode}.\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )
