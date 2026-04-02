"""Tests for CI auto-detection wizard section in the onboarding SKILL.md.

Verifies that plugins/dso/skills/onboarding/SKILL.md (the successor to
project-setup) contains:
  1. A CI configuration sub-section that reads detection output from project-detect.sh
  2. Reference to ci_workflow_names (from project-detect.sh output schema)
  3. Config keys: ci.workflow_name, ci.fast_gate_job, ci.fast_fail_job,
     ci.test_ceil_job, ci.integration_workflow
  4. A deprecation notice for merge.ci_workflow_name
  5. Reference to .github/workflows/ as the detection source

All CI keys are present in onboarding/SKILL.md (added in Phase 3 config generation).
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "onboarding" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


# ── Test 1: CI configuration sub-section exists ───────────────────────────────


def test_skill_has_ci_configuration_section() -> None:
    """SKILL.md Step 3 must contain a CI configuration sub-section.

    The section must exist and must prompt for ci.workflow_name (the primary CI key).
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "ci.workflow_name",
            "CI workflow",
            "### CI",
            "CI configuration",
            "CI auto-detection",
            "CI workflows",
        )
    ), (
        "Expected SKILL.md to contain a CI configuration sub-section "
        "(e.g., '### CI', 'ci.workflow_name', or 'CI workflow') in Step 3. "
        "This section should be added by task dso-bwtp."
    )


# ── Test 2: References project-detect.sh / .github/workflows/ ────────────────


def test_skill_references_github_workflows_or_project_detect() -> None:
    """SKILL.md must reference .github/workflows/ or project-detect as the CI detection source.

    The CI wizard step must tell the agent where auto-detected values come from.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            ".github/workflows",
            "project-detect",
            "ci_workflow_names",
        )
    ), (
        "Expected SKILL.md to reference '.github/workflows/', 'project-detect', "
        "or 'ci_workflow_names' as the source of CI auto-detection. "
        "This is a RED test — SKILL.md does not yet reference CI detection sources."
    )


# ── Test 3: Deprecation notice for merge.ci_workflow_name ────────────────────


def test_skill_mentions_merge_ci_workflow_name_deprecation() -> None:
    """SKILL.md must include a deprecation notice for merge.ci_workflow_name.

    The CI section must tell the agent: if merge.ci_workflow_name is found in
    existing config, show a deprecation notice and suggest migrating to ci.workflow_name.
    """
    content = _read_skill()
    # Both the deprecated key name and 'deprecated' must appear together.
    assert "merge.ci_workflow_name" in content, (
        "Expected SKILL.md to mention 'merge.ci_workflow_name' (the deprecated key). "
        "This is a RED test — SKILL.md does not yet reference merge.ci_workflow_name."
    )
    assert any(
        phrase in content
        for phrase in (
            "deprecated",
            "deprecation",
            "migrate",
        )
    ), (
        "Expected SKILL.md to include a deprecation notice or migration guidance for "
        "merge.ci_workflow_name. "
        "This is a RED test — SKILL.md does not yet contain this notice."
    )


# ── Test 4: Prompts for all required ci.* keys ────────────────────────────────


def test_skill_prompts_for_ci_fast_gate_job() -> None:
    """SKILL.md must prompt for ci.fast_gate_job."""
    content = _read_skill()
    assert "ci.fast_gate_job" in content, (
        "Expected SKILL.md to prompt for 'ci.fast_gate_job'. "
        "This is a RED test — SKILL.md does not yet reference this key."
    )


def test_skill_prompts_for_ci_fast_fail_job() -> None:
    """SKILL.md must prompt for ci.fast_fail_job."""
    content = _read_skill()
    assert "ci.fast_fail_job" in content, (
        "Expected SKILL.md to prompt for 'ci.fast_fail_job'. "
        "This is a RED test — SKILL.md does not yet reference this key."
    )


def test_skill_prompts_for_ci_test_ceil_job() -> None:
    """SKILL.md must prompt for ci.test_ceil_job."""
    content = _read_skill()
    assert "ci.test_ceil_job" in content, (
        "Expected SKILL.md to prompt for 'ci.test_ceil_job'. "
        "This is a RED test — SKILL.md does not yet reference this key."
    )


def test_skill_prompts_for_ci_integration_workflow() -> None:
    """SKILL.md must prompt for ci.integration_workflow."""
    content = _read_skill()
    assert "ci.integration_workflow" in content, (
        "Expected SKILL.md to prompt for 'ci.integration_workflow'. "
        "This is a RED test — SKILL.md does not yet reference this key."
    )


# ── Test SC3: Deprecation notice exists with migration guidance ───────────────


def test_sc3_merge_ci_workflow_name_deprecation_notice() -> None:
    """SKILL.md must include a deprecation notice block for merge.ci_workflow_name (SC3).

    The notice must contain both the deprecated key name and guidance indicating
    that it is deprecated and should be migrated to ci.workflow_name.
    """
    content = _read_skill()
    assert "merge.ci_workflow_name" in content, (
        "Expected SKILL.md to contain 'merge.ci_workflow_name' (the deprecated key). "
        "SC3 requires a deprecation notice for this key."
    )
    assert (
        "deprecated" in content or "deprecation" in content or "migrate" in content
    ), (
        "Expected SKILL.md to contain a deprecation notice or migration guidance "
        "alongside merge.ci_workflow_name. SC3 requires this notice."
    )
    # Both should co-occur: confirm the deprecated key is mentioned in context
    # with the migration guidance (not just in passing)
    assert "ci.workflow_name" in content, (
        "Expected SKILL.md to reference 'ci.workflow_name' as the replacement key "
        "for the deprecated merge.ci_workflow_name. SC3 requires the migration target."
    )


# ── Test SC5: Negative assertions — wrong key names must NOT appear ───────────


def test_sc5_jira_project_key_absent() -> None:
    """SKILL.md must NOT contain 'jira.project_key' (SC5 negative assertion).

    The correct config key is 'jira.project', not 'jira.project_key'.
    This is a regression guard.
    """
    content = _read_skill()
    assert "jira.project_key" not in content, (
        "SKILL.md must NOT contain 'jira.project_key'. "
        "The correct key is 'jira.project'. "
        "SC5 regression guard: found the wrong key name."
    )


def test_sc5_design_system_bare_key_absent() -> None:
    """SKILL.md must NOT contain 'design.system' as a bare key without '_name' (SC5 negative).

    The correct config key is 'design.system_name', not 'design.system'.
    Matches 'design.system' followed by a non-underscore character.
    """
    import re

    content = _read_skill()
    # Exclude comment lines (starting with #) from the check
    non_comment_lines = [
        line for line in content.splitlines() if not line.lstrip().startswith("#")
    ]
    bare_occurrences = [
        line for line in non_comment_lines if re.search(r"design\.system[^_]", line)
    ]
    assert not bare_occurrences, (
        "SKILL.md must NOT contain 'design.system' as a bare key (without '_name' suffix). "
        f"SC5 regression guard: found {len(bare_occurrences)} occurrence(s): "
        + "\n".join(bare_occurrences[:3])
    )
