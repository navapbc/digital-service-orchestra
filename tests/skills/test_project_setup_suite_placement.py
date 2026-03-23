"""Tests for uncovered-suite placement section in the project-setup SKILL.md.

TDD spec for task dso-3mb3 (RED task):
- plugins/dso/skills/project-setup/SKILL.md Step 5 (CI Workflow section) must contain:
  1. Suite coverage detection — parsing .github/workflows/*.yml, substring-matching step
     run: values against known test suite command patterns
  2. Placement prompts — fast-gate, separate, skip options all present
  3. Skip placement config write — ci_placement=skip in dso-config.conf
  4. Non-interactive fallback — fast->fast-gate, slow/unknown->separate
  5. Append-to-existing workflow for fast-gate option
  6. New workflow file creation for separate option
  7. YAML validation before writing — actionlint if installed, else yaml.safe_load;
     temp path → validate → move pattern

All tests are expected to FAIL until the implementation task (dso-i867) adds the
uncovered-suite placement section to SKILL.md.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "project-setup" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


# ── Test 1: Suite coverage detection section ──────────────────────────────────


def test_skill_has_suite_coverage_detection_section() -> None:
    """SKILL.md Step 5 must contain a suite coverage detection section.

    The section must instruct the agent to parse .github/workflows/*.yml files
    and substring-match step run: values against known test suite command patterns
    to determine which suites are already covered by CI.
    This is a RED test — the section does not exist in SKILL.md yet.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "suite coverage detection",
            "uncovered suite",
            "uncovered-suite",
            "coverage detection",
            "suite.*covered",
            "suites.*covered",
            "covered.*suite",
            "substring-match",
            "substring match",
            "step run:",
            "run: values",
        )
    ), (
        "Expected SKILL.md to contain a suite coverage detection section "
        "(e.g., 'suite coverage detection', 'uncovered suite', or 'substring-match') "
        "in Step 5 that parses .github/workflows/*.yml to identify which test suites "
        "are already covered by CI. "
        "This is a RED test — SKILL.md does not yet contain this section."
    )


# ── Test 2: Placement prompts — fast-gate, separate, skip options ─────────────


def test_skill_has_placement_prompts_with_all_options() -> None:
    """SKILL.md must present placement prompt options: fast-gate, separate, and skip.

    When an uncovered suite is detected, the wizard must offer three placement
    options: add to the fast-gate workflow, create a separate workflow file, or
    skip placement. All three options must be documented in SKILL.md.
    This is a RED test — the placement prompts section does not exist yet.
    """
    content = _read_skill()
    # fast-gate option
    assert any(
        phrase in content
        for phrase in (
            "fast-gate",
            "fast gate",
            "fast_gate",
        )
    ), (
        "Expected SKILL.md to document a 'fast-gate' placement option for uncovered suites. "
        "This is a RED test — SKILL.md does not yet contain this placement option."
    )
    # separate option
    assert any(
        phrase in content
        for phrase in (
            "separate workflow",
            "separate file",
            "new workflow",
            "placement.*separate",
            "separate.*placement",
        )
    ), (
        "Expected SKILL.md to document a 'separate' placement option (create a separate "
        "workflow file) for uncovered suites. "
        "This is a RED test — SKILL.md does not yet contain this placement option."
    )
    # skip option
    assert any(
        phrase in content
        for phrase in (
            "skip placement",
            "ci_placement=skip",
            "placement.*skip",
            "skip.*placement",
        )
    ), (
        "Expected SKILL.md to document a 'skip' placement option for uncovered suites. "
        "This is a RED test — SKILL.md does not yet contain this skip placement option."
    )


# ── Test 3: Skip placement writes ci_placement=skip to dso-config.conf ────────


def test_skill_documents_ci_placement_skip_config_write() -> None:
    """SKILL.md must document writing ci_placement=skip to dso-config.conf.

    When the user chooses to skip suite placement, SKILL.md must instruct the agent
    to write ci_placement=skip to dso-config.conf so the choice is persisted and
    not re-prompted on subsequent runs.
    This is a RED test — the ci_placement config key is not referenced in SKILL.md.
    """
    content = _read_skill()
    assert "ci_placement=skip" in content or "ci_placement" in content, (
        "Expected SKILL.md to document writing 'ci_placement=skip' (or reference the "
        "'ci_placement' config key) to dso-config.conf when the user skips suite placement. "
        "This is a RED test — SKILL.md does not yet reference the ci_placement config key."
    )


# ── Test 4: Non-interactive fallback behavior ──────────────────────────────────


def test_skill_documents_non_interactive_fallback() -> None:
    """SKILL.md must document non-interactive fallback placement rules.

    When running non-interactively (e.g., in CI or with --non-interactive flag),
    the agent must apply default placement: fast suites go to fast-gate, slow or
    unknown suites go to a separate workflow. This fallback must be documented.
    This is a RED test — the non-interactive fallback rules are not in SKILL.md yet.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "non-interactive",
            "non_interactive",
            "fallback",
            "default placement",
            "fast.*fast-gate",
            "slow.*separate",
            "unknown.*separate",
        )
    ), (
        "Expected SKILL.md to document non-interactive fallback placement rules — "
        "fast suites → fast-gate, slow/unknown suites → separate workflow. "
        "This is a RED test — SKILL.md does not yet contain non-interactive fallback rules."
    )


# ── Test 5: Append-to-existing workflow for fast-gate option ──────────────────


def test_skill_documents_append_to_existing_for_fast_gate() -> None:
    """SKILL.md must document appending to an existing workflow for the fast-gate option.

    When the user chooses the fast-gate placement, SKILL.md must instruct the agent
    to append the new suite step to the existing fast-gate workflow file rather than
    creating a new file. The append-to-existing pattern must be documented.
    This is a RED test — the append-to-existing workflow pattern is not in SKILL.md yet.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "append.*existing",
            "append.*workflow",
            "existing.*workflow.*append",
            "append to",
            "add.*existing workflow",
        )
    ), (
        "Expected SKILL.md to document appending to an existing workflow file for the "
        "fast-gate placement option (rather than creating a new file). "
        "This is a RED test — SKILL.md does not yet document the append-to-existing pattern."
    )


# ── Test 6: New workflow file creation for separate option ────────────────────


def test_skill_documents_new_workflow_file_creation() -> None:
    """SKILL.md must document creating a new workflow file for the separate option.

    When the user chooses the separate placement option, SKILL.md must instruct the
    agent to create a new .github/workflows/ YAML file for the uncovered suite.
    This is a RED test — the new workflow file creation pattern is not in SKILL.md yet.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "create.*workflow file",
            "new workflow file",
            "create.*new.*workflow",
            "workflow file.*create",
            ".github/workflows/.*yml",
            "new.*yml",
        )
    ), (
        "Expected SKILL.md to document creating a new .github/workflows/ YAML file "
        "for the separate placement option. "
        "This is a RED test — SKILL.md does not yet document new workflow file creation."
    )


# ── Test 7: YAML validation before writing ────────────────────────────────────


def test_skill_documents_yaml_validation_before_writing() -> None:
    """SKILL.md must document YAML validation before writing workflow files.

    Before writing any workflow YAML, SKILL.md must instruct the agent to validate
    the YAML using actionlint (if installed) or yaml.safe_load as a fallback.
    The pattern must be: write to temp path → validate → move to final path.
    This is a RED test — the YAML validation step is not documented in SKILL.md yet.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "yaml_validation",
            "yaml.safe_load",
            "actionlint",
            "validate.*workflow",
            "workflow.*validat",
            "YAML validation",
            "yaml validation",
        )
    ), (
        "Expected SKILL.md to document YAML validation before writing workflow files — "
        "using actionlint if installed, else yaml.safe_load as fallback. "
        "This is a RED test — SKILL.md does not yet document workflow YAML validation."
    )
    # Check for the temp path → validate → move pattern
    assert any(
        phrase in content
        for phrase in (
            "temp path",
            "temp.*validate.*move",
            "validate.*move",
            "temporary",
            ".tmp",
        )
    ), (
        "Expected SKILL.md to document the temp-path → validate → move pattern for safe "
        "YAML file writes (write to temp, validate, then move to final path). "
        "This is a RED test — SKILL.md does not yet reference this safe-write pattern."
    )
