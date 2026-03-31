"""Tests for content requirements of the fix-bug skill file.

TDD spec for task dso-k0yk (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must exist and contain:
  1. Frontmatter with 'name: fix-bug'
  2. 'user-invocable: true' in frontmatter
  3. Mechanical classification language ('mechanical', 'import error', 'lint violation')
  4. Severity scoring rubric language
  5. Complexity scoring rubric language
  6. Environment scoring rubric language
  7. Routing thresholds ('BASIC', 'INTERMEDIATE', 'ADVANCED') with threshold values
  8. RESULT report schema fields ('ROOT_CAUSE', 'confidence')
  9. Discovery file protocol reference
  10. Hypothesis testing phase reference
  11. TDD workflow config pattern (read-config.sh)

TDD spec for task 5727-a272 (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must contain LLM-behavioral path support:
  1. LLM-behavioral classification identified by dual signals (ticket content + file type)
  2. HARD-GATE block amended to cover LLM-behavioral bugs
  3. Step 5 / Step 5.5 RED-test-before-fix exemption for LLM-behavioral bugs
  4. SKILL.md dispatches bot-psychologist agent; plugins/dso/agents/bot-psychologist.md exists
  5. SUB-AGENT-GUARD block using Agent tool availability check with inline-read fallback
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"
CLUSTER_PROMPT_FILE = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "fix-bug"
    / "prompts"
    / "cluster-investigation.md"
)
FALLBACK_PROMPT_FILE = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "fix-bug"
    / "prompts"
    / "intermediate-investigation-fallback.md"
)


def _read_skill() -> str:
    return SKILL_FILE.read_text()


def test_fix_bug_skill_file_exists() -> None:
    """The fix-bug SKILL.md file must exist at the expected path."""
    assert SKILL_FILE.exists(), (
        f"Expected fix-bug skill file to exist at {SKILL_FILE}. "
        "This is a RED test — the file does not exist yet and must be created."
    )


def test_fix_bug_skill_frontmatter_name() -> None:
    """SKILL.md must declare 'name: fix-bug' in its frontmatter."""
    content = _read_skill()
    assert "name: fix-bug" in content, (
        "Expected SKILL.md to contain 'name: fix-bug' in the frontmatter "
        "to register the skill under its canonical invocation name."
    )


def test_fix_bug_skill_user_invocable() -> None:
    """SKILL.md must declare 'user-invocable: true' in its frontmatter."""
    content = _read_skill()
    assert "user-invocable: true" in content, (
        "Expected SKILL.md to contain 'user-invocable: true' so the skill "
        "is exposed as a directly invocable command for DSO practitioners."
    )


def test_fix_bug_skill_mechanical_classification() -> None:
    """SKILL.md must define mechanical bug classification with example types."""
    content = _read_skill()
    assert "mechanical" in content, (
        "Expected SKILL.md to contain 'mechanical' to name the simplest "
        "category of bugs that require no deep investigation."
    )
    assert "import error" in content, (
        "Expected SKILL.md to contain 'import error' as an example of a "
        "mechanical bug type in the classification section."
    )
    assert "lint violation" in content, (
        "Expected SKILL.md to contain 'lint violation' as an example of a "
        "mechanical bug type in the classification section."
    )


def test_fix_bug_skill_scoring_rubric_severity() -> None:
    """SKILL.md must contain severity scoring language in the rubric."""
    content = _read_skill()
    assert "severity" in content, (
        "Expected SKILL.md to contain 'severity' as a scoring dimension "
        "in the bug classification rubric."
    )


def test_fix_bug_skill_scoring_rubric_complexity() -> None:
    """SKILL.md must contain complexity scoring language in the rubric."""
    content = _read_skill()
    assert "complexity" in content, (
        "Expected SKILL.md to contain 'complexity' as a scoring dimension "
        "in the bug classification rubric."
    )


def test_fix_bug_skill_scoring_rubric_environment() -> None:
    """SKILL.md must contain environment scoring language in the rubric."""
    content = _read_skill()
    assert "environment" in content, (
        "Expected SKILL.md to contain 'environment' as a scoring dimension "
        "in the bug classification rubric (e.g., reproducibility context)."
    )


def test_fix_bug_skill_routing_thresholds() -> None:
    """SKILL.md must define BASIC, INTERMEDIATE, and ADVANCED routing tiers with thresholds."""
    content = _read_skill()
    assert "BASIC" in content, (
        "Expected SKILL.md to contain 'BASIC' as the lowest routing tier "
        "for straightforward bugs."
    )
    assert "INTERMEDIATE" in content, (
        "Expected SKILL.md to contain 'INTERMEDIATE' as the mid-tier routing "
        "category for moderately complex bugs."
    )
    assert "ADVANCED" in content, (
        "Expected SKILL.md to contain 'ADVANCED' as the highest routing tier "
        "for complex bugs requiring deep investigation."
    )


def test_fix_bug_skill_result_schema() -> None:
    """SKILL.md must define a RESULT report schema containing ROOT_CAUSE and confidence."""
    content = _read_skill()
    assert "ROOT_CAUSE" in content, (
        "Expected SKILL.md to contain 'ROOT_CAUSE' as a required field "
        "in the RESULT report schema output."
    )
    assert "confidence" in content, (
        "Expected SKILL.md to contain 'confidence' as a required field "
        "in the RESULT report schema output."
    )


def test_fix_bug_skill_discovery_file_protocol() -> None:
    """SKILL.md must reference the discovery file protocol for captured findings."""
    content = _read_skill()
    assert "discovery file" in content, (
        "Expected SKILL.md to contain 'discovery file' to describe the protocol "
        "for writing structured bug investigation findings to a shared artifact."
    )


def test_fix_bug_skill_hypothesis_testing_phase() -> None:
    """SKILL.md must include a hypothesis testing phase in the investigation workflow."""
    content = _read_skill()
    assert "hypothesis" in content, (
        "Expected SKILL.md to contain 'hypothesis' to describe the phase where "
        "the agent proposes and tests a root-cause theory before implementing a fix."
    )


def test_fix_bug_skill_tdd_workflow_config_pattern() -> None:
    """SKILL.md must reference read-config.sh for config resolution."""
    content = _read_skill()
    assert "read-config.sh" in content, (
        "Expected SKILL.md to contain 'read-config.sh' as the canonical way "
        "to resolve workflow configuration values (TDD workflow config pattern)."
    )


class TestBasicInvestigationSkillIntegration:
    """Tests asserting the BASIC investigation section of SKILL.md references
    the prompt template file and includes explicit context-assembly instructions.

    TDD spec for task w21-8yqq (RED task):
    - plugins/dso/skills/fix-bug/SKILL.md BASIC section must:
      1. Reference 'basic-investigation.md' prompt template file
      2. Use 'prompts/' directory convention
      3. Define explicit context-assembly slots (failing_tests, stack_trace, commit_history)
      4. Reference RESULT format conformance for the sub-agent output schema
    """

    def test_basic_section_references_prompt_template_file(self) -> None:
        """SKILL.md BASIC section must reference the 'basic-investigation.md' prompt template."""
        content = _read_skill()
        assert "basic-investigation.md" in content, (
            "Expected SKILL.md to contain 'basic-investigation.md' to reference "
            "the prompt template file for the BASIC investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )

    def test_basic_section_uses_prompts_directory_convention(self) -> None:
        """SKILL.md BASIC section must use the 'prompts/' directory convention."""
        content = _read_skill()
        assert "prompts/" in content, (
            "Expected SKILL.md to contain 'prompts/' to follow the standard "
            "prompts directory convention for referencing prompt template files. "
            "This is a RED test — SKILL.md does not yet use this convention."
        )

    def test_basic_section_defines_context_assembly_slots(self) -> None:
        """SKILL.md BASIC section must define named context slots for the dispatch."""
        content = _read_skill()
        assert "failing_tests" in content, (
            "Expected SKILL.md to contain 'failing_tests' as a named context slot "
            "in the BASIC dispatch assembly instructions. "
            "This is a RED test — SKILL.md does not yet define these context slots."
        )
        assert "stack_trace" in content, (
            "Expected SKILL.md to contain 'stack_trace' as a named context slot "
            "in the BASIC dispatch assembly instructions."
        )
        assert "commit_history" in content, (
            "Expected SKILL.md to contain 'commit_history' as a named context slot "
            "in the BASIC dispatch assembly instructions."
        )

    def test_basic_section_references_result_format_conformance(self) -> None:
        """SKILL.md BASIC section must reference RESULT format conformance for sub-agent output."""
        content = _read_skill()
        assert "RESULT" in content, (
            "Expected SKILL.md to contain 'RESULT' to reference the output schema "
            "that the BASIC investigation sub-agent must conform to. "
            "This is a RED test — SKILL.md does not yet reference RESULT format conformance."
        )


class TestIntermediateInvestigationSkillIntegration:
    """Tests asserting the INTERMEDIATE investigation section of SKILL.md references
    the prompt template file and defines dispatch context assembly.

    TDD spec for task w21-src2 (RED task):
    - plugins/dso/skills/fix-bug/SKILL.md INTERMEDIATE section must:
      1. Reference 'intermediate-investigation.md' prompt template file
      2. Use 'prompts/' directory convention
      3. Define context assembly slots: failing_tests, stack_trace, commit_history
      4. Reference fallback prompt or investigation-specific prompt for general-purpose fallback
    """

    def test_intermediate_section_references_prompt_template_file(self) -> None:
        """SKILL.md INTERMEDIATE section must reference the 'intermediate-investigation.md' prompt template."""
        content = _read_skill()
        assert "intermediate-investigation.md" in content, (
            "Expected SKILL.md to contain 'intermediate-investigation.md' to reference "
            "the prompt template file for the INTERMEDIATE investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )

    def test_intermediate_section_uses_prompts_directory_convention(self) -> None:
        """SKILL.md INTERMEDIATE section must use the 'prompts/' directory convention."""
        content = _read_skill()
        assert "prompts/" in content, (
            "Expected SKILL.md to contain 'prompts/' to follow the standard "
            "prompts directory convention for referencing prompt template files. "
            "This test passes as long as any prompt template reference uses 'prompts/'."
        )

    def test_intermediate_section_defines_context_assembly_slots(self) -> None:
        """SKILL.md INTERMEDIATE section must define named context slots for the dispatch."""
        content = _read_skill()
        assert "failing_tests" in content, (
            "Expected SKILL.md to contain 'failing_tests' as a named context slot "
            "in the INTERMEDIATE dispatch assembly instructions. "
            "This test passes if already defined in BASIC — both tiers share these slots."
        )
        assert "stack_trace" in content, (
            "Expected SKILL.md to contain 'stack_trace' as a named context slot "
            "in the INTERMEDIATE dispatch assembly instructions."
        )
        assert "commit_history" in content, (
            "Expected SKILL.md to contain 'commit_history' as a named context slot "
            "in the INTERMEDIATE dispatch assembly instructions."
        )

    def test_intermediate_section_references_fallback_prompt(self) -> None:
        """SKILL.md INTERMEDIATE section must reference fallback prompt for general-purpose agent."""
        content = _read_skill()
        assert "intermediate-investigation-fallback.md" in content, (
            "Expected SKILL.md to contain 'intermediate-investigation-fallback.md' as the "
            "fallback investigation prompt used when error-detective is unavailable. "
            "This is a RED test — SKILL.md does not yet reference this fallback prompt file."
        )


class TestAdvancedInvestigationSkillIntegration:
    """Tests asserting the ADVANCED investigation section of SKILL.md references
    the two-agent prompt template files and defines convergence scoring.

    TDD spec for task w21-pjhx (RED task):
    - plugins/dso/skills/fix-bug/SKILL.md ADVANCED section must:
      1. Reference 'advanced-investigation-agent-a.md' prompt template file
      2. Reference 'advanced-investigation-agent-b.md' prompt template file
      3. Use 'prompts/' directory convention (likely already passes — confirm)
      4. Define context assembly slots (failing_tests, stack_trace, commit_history)
      5. Reference convergence scoring language ('convergence_score' or 'convergence scoring')
    """

    def test_advanced_section_references_agent_a_prompt_template(self) -> None:
        """SKILL.md ADVANCED section must reference the 'advanced-investigation-agent-a.md' prompt template."""
        content = _read_skill()
        assert "advanced-investigation-agent-a.md" in content, (
            "Expected SKILL.md to contain 'advanced-investigation-agent-a.md' to reference "
            "the prompt template file for Agent A (Code Tracer) in the ADVANCED investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )

    def test_advanced_section_references_agent_b_prompt_template(self) -> None:
        """SKILL.md ADVANCED section must reference the 'advanced-investigation-agent-b.md' prompt template."""
        content = _read_skill()
        assert "advanced-investigation-agent-b.md" in content, (
            "Expected SKILL.md to contain 'advanced-investigation-agent-b.md' to reference "
            "the prompt template file for Agent B (Historical) in the ADVANCED investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )

    def test_advanced_section_uses_prompts_directory_convention(self) -> None:
        """SKILL.md ADVANCED section must use the 'prompts/' directory convention."""
        content = _read_skill()
        assert "prompts/" in content, (
            "Expected SKILL.md to contain 'prompts/' to follow the standard "
            "prompts directory convention for referencing prompt template files. "
            "This test passes as long as any prompt template reference uses 'prompts/'."
        )

    def test_advanced_section_defines_context_assembly_slots(self) -> None:
        """SKILL.md ADVANCED section must define named context slots for the dispatch."""
        content = _read_skill()
        assert "failing_tests" in content, (
            "Expected SKILL.md to contain 'failing_tests' as a named context slot "
            "in the ADVANCED dispatch assembly instructions. "
            "This test passes if already defined in BASIC or INTERMEDIATE — tiers share these slots."
        )
        assert "stack_trace" in content, (
            "Expected SKILL.md to contain 'stack_trace' as a named context slot "
            "in the ADVANCED dispatch assembly instructions."
        )
        assert "commit_history" in content, (
            "Expected SKILL.md to contain 'commit_history' as a named context slot "
            "in the ADVANCED dispatch assembly instructions."
        )

    def test_advanced_section_references_convergence_scoring(self) -> None:
        """SKILL.md ADVANCED section must reference convergence scoring language."""
        content = _read_skill()
        assert any(
            phrase in content for phrase in ("convergence_score", "convergence scoring")
        ), (
            "Expected SKILL.md to contain 'convergence_score' or 'convergence scoring' "
            "to describe the mechanism by which the orchestrator scores agreement between "
            "Agent A and Agent B in the ADVANCED investigation. "
            "This test should already pass — SKILL.md includes convergence scoring language."
        )


class TestHardGatePreamble:
    """Tests asserting the fix-bug SKILL.md contains a HARD-GATE block in the preamble
    that explicitly prohibits code modification before completing Steps 1-5.

    TDD spec for task 018a-0b5b:
    - plugins/dso/skills/fix-bug/SKILL.md must:
      1. Contain a HARD-GATE XML block
      2. The HARD-GATE block must explicitly prohibit code modification before Steps 1-5
    """

    def test_hard_gate_block_present(self) -> None:
        """SKILL.md must contain a HARD-GATE block in the preamble."""
        content = _read_skill()
        assert "HARD-GATE" in content, (
            "Expected fix-bug SKILL.md to contain a '<HARD-GATE>' block in the preamble "
            "to explicitly prohibit code modification before completing Steps 1-5. "
            "This is a RED test — the HARD-GATE block does not yet exist."
        )

    def test_hard_gate_prohibits_code_modification_before_steps(self) -> None:
        """The HARD-GATE block must explicitly prohibit code modification before Steps 1-5."""
        content = _read_skill()
        hard_gate_start = content.find("HARD-GATE")
        assert hard_gate_start != -1, "HARD-GATE block not found"
        # Extract context around the HARD-GATE block (up to 500 chars after)
        gate_context = content[hard_gate_start : hard_gate_start + 500].lower()
        has_step_ref = any(
            phrase in gate_context
            for phrase in (
                "step",
                "steps 1",
                "1 through 5",
                "1-5",
                "before",
            )
        )
        assert has_step_ref, (
            "Expected the HARD-GATE block in fix-bug SKILL.md to reference steps 1-5 "
            "and explicitly prohibit code modification before those steps complete. "
            "This is a RED test — the HARD-GATE block does not yet contain this language."
        )


class TestClusterInvestigation:
    """Tests asserting SKILL.md contains cluster investigation content.

    TDD spec for task dso-12ap (RED task):
    - plugins/dso/skills/fix-bug/SKILL.md must:
      1. Accept multiple bug IDs (cluster invocation)
      2. Investigate multiple bugs as a single problem
      3. Split into per-root-cause tracks only when independent root causes are identified
      4. Reference the 'cluster-investigation.md' prompt template
    """

    def test_skill_accepts_multiple_bug_ids(self) -> None:
        """SKILL.md must contain language indicating it accepts multiple bug IDs."""
        content = _read_skill()
        assert any(
            phrase in content
            for phrase in ("cluster", "multiple bug IDs", "cluster invocation")
        ), (
            "Expected SKILL.md to contain 'cluster', 'multiple bug IDs', or "
            "'cluster invocation' to indicate the skill accepts multiple bug IDs "
            "as a cluster invocation. "
            "This is a RED test — SKILL.md does not yet contain this language."
        )

    def test_skill_cluster_investigates_as_single_problem(self) -> None:
        """SKILL.md must specify that multiple bugs are investigated as a single problem."""
        content = _read_skill()
        assert any(
            phrase in content
            for phrase in (
                "single problem",
                "investigate as a single problem",
                "cluster investigation",
            )
        ), (
            "Expected SKILL.md to contain 'single problem', 'investigate as a single problem', "
            "or 'cluster investigation' to specify that multiple bugs are investigated together. "
            "This is a RED test — SKILL.md does not yet contain this language."
        )

    def test_skill_splits_on_independent_root_causes(self) -> None:
        """SKILL.md must describe splitting into per-root-cause tracks when applicable."""
        content = _read_skill()
        assert any(
            phrase in content
            for phrase in (
                "independent root cause",
                "per-root-cause track",
                "split into",
            )
        ), (
            "Expected SKILL.md to contain 'independent root cause', 'per-root-cause track', "
            "or 'split into' to describe splitting into per-root-cause tracks only when "
            "multiple independent root causes are identified. "
            "This is a RED test — SKILL.md does not yet contain this language."
        )

    def test_skill_cluster_references_prompt_template(self) -> None:
        """SKILL.md must reference the 'cluster-investigation.md' prompt template."""
        content = _read_skill()
        assert "cluster-investigation.md" in content, (
            "Expected SKILL.md to contain 'cluster-investigation.md' to reference "
            "the prompt template file for the cluster investigation dispatch. "
            "This is a RED test — SKILL.md does not yet reference this file."
        )


class TestClusterInvestigationPrompt:
    """Tests asserting cluster-investigation.md prompt template exists and contains required content.

    TDD spec for task dso-s3g4 (RED task):
    - plugins/dso/skills/fix-bug/prompts/cluster-investigation.md must exist and contain:
      1. File exists at the expected path
      2. {ticket_ids} placeholder for receiving multiple bug IDs
      3. Single-problem investigation instructions
      4. Splitting logic for independent root causes
      5. RESULT schema output instructions
    """

    def test_cluster_prompt_file_exists(self) -> None:
        """The cluster-investigation.md prompt file must exist at the expected path."""
        assert CLUSTER_PROMPT_FILE.exists(), (
            f"Expected cluster-investigation prompt to exist at {CLUSTER_PROMPT_FILE}. "
            "This is a RED test — the file does not exist yet and must be created."
        )

    def test_cluster_prompt_contains_multiple_ticket_ids_slot(self) -> None:
        """Prompt must contain {ticket_ids} placeholder for receiving multiple bug IDs."""
        content = CLUSTER_PROMPT_FILE.read_text()
        assert "{ticket_ids}" in content, (
            "Expected cluster-investigation.md to contain '{ticket_ids}' as a "
            "placeholder for receiving multiple bug IDs in the cluster invocation. "
            "This is a RED test — the file does not exist yet and must be created."
        )

    def test_cluster_prompt_contains_single_investigation_instruction(self) -> None:
        """Prompt must instruct investigation as a single problem."""
        content = CLUSTER_PROMPT_FILE.read_text()
        assert any(
            phrase in content
            for phrase in (
                "single problem",
                "investigate together",
                "unified investigation",
            )
        ), (
            "Expected cluster-investigation.md to contain 'single problem', "
            "'investigate together', or 'unified investigation' to instruct the "
            "sub-agent to treat multiple bugs as a single investigation. "
            "This is a RED test — the file does not exist yet and must be created."
        )

    def test_cluster_prompt_contains_split_instruction(self) -> None:
        """Prompt must contain splitting logic for independent root causes."""
        content = CLUSTER_PROMPT_FILE.read_text()
        assert any(
            phrase in content
            for phrase in ("independent root cause", "per-root-cause", "split")
        ), (
            "Expected cluster-investigation.md to contain 'independent root cause', "
            "'per-root-cause', or 'split' to describe the splitting logic when "
            "multiple independent root causes are identified. "
            "This is a RED test — the file does not exist yet and must be created."
        )

    def test_cluster_prompt_contains_result_schema_reference(self) -> None:
        """Prompt must contain RESULT schema output instructions."""
        content = CLUSTER_PROMPT_FILE.read_text()
        assert "RESULT" in content, (
            "Expected cluster-investigation.md to contain 'RESULT' as the output "
            "schema marker, conforming to the shared Investigation RESULT Report Schema. "
            "This is a RED test — the file does not exist yet and must be created."
        )


def test_hypothesis_tests_schema_in_skill() -> None:
    """SKILL.md must use hypothesis_tests (not tests_run) with sub-fields hypothesis, test, observed, verdict."""
    content = _read_skill()
    # Assert hypothesis_tests field is present with correct sub-fields
    assert "hypothesis_tests" in content, (
        "Expected SKILL.md to contain 'hypothesis_tests' as the field name for "
        "hypothesis test results in the RESULT schema. This replaces the old 'tests_run' field."
    )
    for sub_field in ("hypothesis", "test", "observed", "verdict"):
        assert sub_field in content, (
            f"Expected SKILL.md to contain '{sub_field}' as a sub-field of hypothesis_tests "
            "in the RESULT schema."
        )
    # Assert old field name tests_run is entirely absent
    assert "tests_run" not in content, (
        "Expected SKILL.md to NOT contain 'tests_run' — this field has been renamed to "
        "'hypothesis_tests'. All references to the old field name must be removed."
    )


def test_fallback_and_cluster_prompts_hypothesis_tests() -> None:
    """intermediate-investigation-fallback.md and cluster-investigation.md must use hypothesis_tests."""
    # --- intermediate-investigation-fallback.md ---
    fallback_content = FALLBACK_PROMPT_FILE.read_text()
    assert "hypothesis_tests" in fallback_content, (
        "Expected intermediate-investigation-fallback.md to contain 'hypothesis_tests' "
        "in its RESULT section."
    )
    # Instructional prose must reference hypothesis_tests (not just in schema block)
    # Look for hypothesis_tests appearing in instructional text, not just a YAML key
    fallback_lines_with_ht = [
        line
        for line in fallback_content.splitlines()
        if "hypothesis_tests" in line
        and not line.strip().startswith("hypothesis_tests:")
    ]
    assert len(fallback_lines_with_ht) > 0, (
        "Expected intermediate-investigation-fallback.md to contain instructional prose "
        "referencing 'hypothesis_tests' outside of the schema block."
    )
    assert "tests_run" not in fallback_content, (
        "Expected intermediate-investigation-fallback.md to NOT contain 'tests_run' — "
        "this field has been renamed to 'hypothesis_tests'."
    )

    # --- cluster-investigation.md ---
    cluster_content = CLUSTER_PROMPT_FILE.read_text()
    # Must contain hypothesis_tests (replaces 3 tests_run blocks)
    assert "hypothesis_tests" in cluster_content, (
        "Expected cluster-investigation.md to contain 'hypothesis_tests' "
        "in its RESULT section(s)."
    )
    # All 3 hypothesis_tests blocks must have correct sub-fields
    for sub_field in ("hypothesis", "test", "observed", "verdict"):
        assert sub_field in cluster_content, (
            f"Expected cluster-investigation.md to contain '{sub_field}' as a sub-field "
            "of hypothesis_tests in all RESULT schema blocks."
        )
    # Old sub-field names must be entirely absent
    for old_field in ("command", "result"):
        # 'result' as a standalone sub-field key (under tests_run) should not exist
        # but 'result' may appear in prose — we check for the YAML key pattern
        if old_field == "command":
            assert not any(
                line.strip().startswith("command:")
                for line in cluster_content.splitlines()
            ), (
                "Expected cluster-investigation.md to NOT contain 'command:' as a sub-field "
                "key — this old sub-field has been renamed to 'test'."
            )
    # Instructional prose must reference hypothesis_tests
    cluster_prose_lines = [
        line
        for line in cluster_content.splitlines()
        if "hypothesis_tests" in line
        and not line.strip().startswith("hypothesis_tests:")
    ]
    assert len(cluster_prose_lines) > 0, (
        "Expected cluster-investigation.md to contain instructional prose "
        "referencing 'hypothesis_tests' outside of the schema blocks."
    )
    # tests_run must be entirely absent
    assert "tests_run" not in cluster_content, (
        "Expected cluster-investigation.md to NOT contain 'tests_run' — "
        "all three occurrences must be replaced with 'hypothesis_tests'."
    )


class TestHypothesisValidationGate:
    """Tests asserting the fix-bug SKILL.md contains a hypothesis_tests validation gate
    between Step 2 (investigation) and Step 6 (fix implementation).

    TDD spec for task 91bf-a66b:
    - plugins/dso/skills/fix-bug/SKILL.md must:
      1. Contain language requiring hypothesis_tests validation before fix implementation
      2. Reject (escalate) investigation results with no hypothesis_tests entries
      3. Reject (escalate) investigation results where all verdicts are disproved
      4. Proceed to fix implementation only when at least one verdict=confirmed exists
    """

    def test_hypothesis_validation_gate_present(self) -> None:
        """SKILL.md must contain a hypothesis_tests validation gate before fix implementation."""
        content = _read_skill()
        assert any(
            phrase in content
            for phrase in (
                "hypothesis_tests validation",
                "Hypothesis Validation Gate",
                "hypothesis validation gate",
                "validate hypothesis_tests",
                "hypothesis_tests gate",
            )
        ), (
            "Expected SKILL.md to contain a hypothesis_tests validation gate section "
            "(e.g., 'Hypothesis Validation Gate' or 'hypothesis_tests validation') "
            "between Step 2 and Step 6. "
            "This is a RED test — the gate does not yet exist in SKILL.md."
        )

    def test_hypothesis_gate_escalates_on_missing_hypothesis_tests(self) -> None:
        """SKILL.md must escalate when hypothesis_tests is missing or empty."""
        content = _read_skill()
        # The gate must contain language about missing/empty hypothesis_tests → escalate
        assert any(
            phrase in content
            for phrase in (
                "missing or empty",
                "no hypothesis_tests",
                "hypothesis_tests is missing",
                "hypothesis_tests section is absent",
                "no entries",
                "empty hypothesis_tests",
            )
        ), (
            "Expected SKILL.md to contain language about escalating when hypothesis_tests "
            "is missing or empty (e.g., 'missing or empty', 'no hypothesis_tests', "
            "'no entries'). "
            "This is a RED test — the gate does not yet contain this language."
        )

    def test_hypothesis_gate_escalates_on_all_disproved(self) -> None:
        """SKILL.md must escalate when all hypothesis_tests verdicts are disproved."""
        content = _read_skill()
        assert any(
            phrase in content
            for phrase in (
                "all verdicts are disproved",
                "all hypotheses are disproved",
                "every verdict is disproved",
                "no confirmed verdict",
                "no confirmed hypothesis",
                "all disproved",
            )
        ), (
            "Expected SKILL.md to contain language about escalating when all "
            "hypothesis_tests verdicts are disproved (e.g., 'all verdicts are disproved', "
            "'all hypotheses are disproved', 'no confirmed verdict'). "
            "This is a RED test — the gate does not yet contain this language."
        )

    def test_hypothesis_gate_proceeds_on_confirmed_verdict(self) -> None:
        """SKILL.md must specify proceeding to fix implementation when at least one verdict=confirmed."""
        content = _read_skill()
        assert any(
            phrase in content
            for phrase in (
                "verdict=confirmed",
                "verdict: confirmed",
                "at least one confirmed",
                "one confirmed hypothesis",
                "confirmed verdict",
            )
        ), (
            "Expected SKILL.md to contain language specifying that the orchestrator proceeds "
            "to fix implementation when at least one hypothesis has verdict=confirmed "
            "(e.g., 'at least one confirmed', 'verdict=confirmed', 'confirmed verdict'). "
            "This is a RED test — the gate does not yet contain this language."
        )

    def test_hypothesis_gate_escalates_to_next_tier(self) -> None:
        """SKILL.md hypothesis gate must escalate to the next investigation tier (not terminate)."""
        content = _read_skill()
        # Check that the gate section references escalation or next tier
        # We look for "escalate" near the gate context
        gate_phrases = [
            "Hypothesis Validation Gate",
            "hypothesis validation gate",
            "hypothesis_tests validation",
        ]
        gate_pos = -1
        for phrase in gate_phrases:
            pos = content.find(phrase)
            if pos != -1:
                gate_pos = pos
                break

        assert gate_pos != -1, (
            "Could not find the hypothesis validation gate section in SKILL.md. "
            "This test requires the gate to be present first."
        )

        # Extract context around the gate (up to 600 chars)
        gate_context = content[gate_pos : gate_pos + 600].lower()
        assert any(
            phrase in gate_context
            for phrase in (
                "escalate",
                "next tier",
                "next investigation tier",
                "escalation",
            )
        ), (
            "Expected the hypothesis validation gate in SKILL.md to reference escalation "
            "to the next investigation tier when validation fails. "
            "The gate should escalate (not terminate) when no confirmed hypotheses exist."
        )


class TestRedBeforeFixGate:
    """Tests asserting the fix-bug SKILL.md contains a RED-before-fix gate
    between Step 5 (RED test) and Step 6 (fix implementation).

    TDD spec for story b094-3cf4:
    - plugins/dso/skills/fix-bug/SKILL.md must:
      1. Contain a RED-before-fix gate between Step 5 and Step 6
      2. The gate must block code modification / fix dispatch when no RED test is confirmed failing
      3. The gate must exempt mechanical bugs via the Mechanical Fix Path
      4. Gate language must reference Step 5 and Step 6 relationship
    """

    def test_red_before_fix_gate_present(self) -> None:
        """SKILL.md must contain a RED-before-fix gate section between Step 5 and Step 6."""
        content = _read_skill()
        assert any(
            phrase in content
            for phrase in (
                "RED-before-fix",
                "RED Before Fix",
                "red-before-fix",
                "RED test gate",
                "RED Test Gate",
            )
        ), (
            "Expected fix-bug SKILL.md to contain a 'RED-before-fix' gate section "
            "between Step 5 (RED test) and Step 6 (fix implementation) to enforce TDD discipline. "
            "This is a RED test — the gate does not yet exist in SKILL.md."
        )

    def test_red_before_fix_gate_blocks_fix_without_red_test(self) -> None:
        """The gate must block fix implementation when no RED test has been written and confirmed failing."""
        content = _read_skill()
        # Find the gate section
        gate_phrases = [
            "RED-before-fix",
            "RED Before Fix",
            "RED Test Gate",
        ]
        gate_pos = -1
        for phrase in gate_phrases:
            pos = content.find(phrase)
            if pos != -1:
                gate_pos = pos
                break

        assert gate_pos != -1, (
            "Could not find the RED-before-fix gate section in SKILL.md. "
            "This test requires the gate to be present first."
        )

        # Extract context around the gate (up to 800 chars)
        gate_context = content[gate_pos : gate_pos + 800].lower()
        has_blocking_language = any(
            phrase in gate_context
            for phrase in (
                "block",
                "do not proceed",
                "must not proceed",
                "cannot proceed",
                "blocked",
                "stop",
                "halt",
                "forbidden",
                "not allowed",
            )
        )
        assert has_blocking_language, (
            "Expected the RED-before-fix gate in SKILL.md to contain blocking language "
            "(e.g., 'block', 'do not proceed', 'must not proceed', 'cannot proceed') "
            "to prevent fix implementation when no RED test has been confirmed failing. "
            "This is a RED test — the gate does not yet contain this language."
        )

    def test_red_before_fix_gate_requires_confirmed_failing_test(self) -> None:
        """The gate must require that a RED test exists and has been confirmed failing."""
        content = _read_skill()
        gate_phrases = [
            "RED-before-fix",
            "RED Before Fix",
            "RED Test Gate",
        ]
        gate_pos = -1
        for phrase in gate_phrases:
            pos = content.find(phrase)
            if pos != -1:
                gate_pos = pos
                break

        assert gate_pos != -1, (
            "Could not find the RED-before-fix gate section in SKILL.md."
        )

        gate_context = content[gate_pos : gate_pos + 800].lower()
        has_failing_requirement = any(
            phrase in gate_context
            for phrase in (
                "confirmed failing",
                "confirmed fail",
                "must fail",
                "confirmed red",
                "failing test",
                "fail",
            )
        )
        assert has_failing_requirement, (
            "Expected the RED-before-fix gate to require that the RED test has been "
            "confirmed failing (e.g., 'confirmed failing', 'confirmed RED', 'must fail'). "
            "This is a RED test — the gate does not yet contain this requirement."
        )

    def test_red_before_fix_gate_exempts_mechanical_bugs(self) -> None:
        """The gate must exempt mechanical bugs via the Mechanical Fix Path."""
        content = _read_skill()
        gate_phrases = [
            "RED-before-fix",
            "RED Before Fix",
            "RED Test Gate",
        ]
        gate_pos = -1
        for phrase in gate_phrases:
            pos = content.find(phrase)
            if pos != -1:
                gate_pos = pos
                break

        assert gate_pos != -1, (
            "Could not find the RED-before-fix gate section in SKILL.md."
        )

        # Extract a wider context — mechanical exemption may be stated after the gate header
        gate_context = content[gate_pos : gate_pos + 1200].lower()
        has_mechanical_exemption = any(
            phrase in gate_context
            for phrase in (
                "mechanical",
                "mechanical fix path",
                "exempt",
                "bypass",
            )
        )
        assert has_mechanical_exemption, (
            "Expected the RED-before-fix gate in SKILL.md to exempt mechanical bugs "
            "via the Mechanical Fix Path (e.g., 'mechanical', 'exempt', 'bypass'). "
            "This is a RED test — the gate does not yet contain the mechanical exemption."
        )

    def test_red_before_fix_gate_positioned_between_step5_and_step6(self) -> None:
        """The RED-before-fix gate must appear between Step 5 and Step 6 in SKILL.md."""
        content = _read_skill()

        # Find Step 5 position
        step5_pos = content.find("### Step 5:")
        assert step5_pos != -1, "Could not find '### Step 5:' in SKILL.md"

        # Find Step 6 position
        step6_pos = content.find("### Step 6:")
        assert step6_pos != -1, "Could not find '### Step 6:' in SKILL.md"

        # Find the gate position
        gate_phrases = [
            "RED-before-fix",
            "RED Before Fix",
            "RED Test Gate",
        ]
        gate_pos = -1
        for phrase in gate_phrases:
            pos = content.find(phrase)
            if pos != -1:
                gate_pos = pos
                break

        assert gate_pos != -1, (
            "Could not find the RED-before-fix gate in SKILL.md. "
            "Expected it to be present between Step 5 and Step 6."
        )

        assert step5_pos < gate_pos < step6_pos, (
            f"Expected the RED-before-fix gate (pos={gate_pos}) to appear "
            f"after Step 5 (pos={step5_pos}) and before Step 6 (pos={step6_pos}). "
            "The gate must be positioned between those two steps to enforce TDD discipline. "
            "This is a RED test — the gate is not yet positioned correctly."
        )


# ---------------------------------------------------------------------------
# LLM-Behavioral Path Tests (task 5727-a272)
# ---------------------------------------------------------------------------

BOT_PSYCHOLOGIST_AGENT_FILE = (
    REPO_ROOT / "plugins" / "dso" / "agents" / "bot-psychologist.md"
)


def test_fix_bug_skill_llm_behavioral_classification() -> None:
    """SKILL.md must classify LLM-behavioral bugs using dual signals: ticket content AND file type.

    An LLM-behavioral bug is identified by two independent signals present together:
    (1) the bug description references LLM output, prompts, or model behavior, and
    (2) the affected file type is a skill (.md in skills/), agent (.md in agents/),
    or prompt template.

    This dual-signal requirement prevents over-classification of unrelated markdown
    changes as LLM-behavioral. The classification must appear in a dedicated
    LLM-Behavioral Errors section (analogous to the existing Mechanical Errors section).
    """
    content = _read_skill()
    # The classification must appear under a dedicated section — not just incidentally
    # in other parts of the file. Look for a section header naming the category.
    has_llm_behavioral_section = any(
        phrase in content
        for phrase in (
            "LLM-Behavioral Errors",
            "LLM-behavioral Errors",
            "LLM-Behavioral errors",
            "### LLM-Behavioral",
            "## LLM-Behavioral",
            "LLM-Behavioral Bug",
            "llm-behavioral bug",
        )
    )
    assert has_llm_behavioral_section, (
        "Expected SKILL.md to contain a dedicated LLM-Behavioral Errors section "
        "(e.g., 'LLM-Behavioral Errors', '### LLM-Behavioral', 'LLM-Behavioral Bug') "
        "that classifies this bug category using dual signals. This section is analogous "
        "to the existing 'Mechanical Errors' section. "
        "This is a RED test — SKILL.md does not yet have an LLM-behavioral classification section."
    )
    # Both signals must be described within the classification text
    # Find the section and look for dual-signal language in context
    section_pos = -1
    for phrase in (
        "LLM-Behavioral Errors",
        "LLM-behavioral Errors",
        "LLM-Behavioral errors",
        "### LLM-Behavioral",
        "LLM-Behavioral Bug",
    ):
        pos = content.find(phrase)
        if pos != -1:
            section_pos = pos
            break
    section_text = content[section_pos : section_pos + 800].lower()
    has_dual_signal = any(
        phrase in section_text
        for phrase in (
            "dual signal",
            "dual-signal",
            "two signal",
            "both signal",
            "ticket content",
            "file type",
        )
    )
    assert has_dual_signal, (
        "Expected the LLM-behavioral classification section in SKILL.md to reference "
        "the dual-signal detection approach (e.g., 'dual signal', 'dual-signal', "
        "'ticket content', 'file type'). Both a ticket-content signal AND a file-type signal "
        "must be described. "
        "This is a RED test — the section does not yet describe dual-signal classification."
    )


def test_fix_bug_skill_hard_gate_llm_behavioral() -> None:
    """The HARD-GATE block must be amended to cover LLM-behavioral bugs.

    The existing HARD-GATE prohibits code modification before Steps 1-5. For LLM-behavioral
    bugs, the HARD-GATE must also prohibit modifying skill files, agent files, or prompt
    templates before investigation completes — the same investigation discipline applies.
    """
    content = _read_skill()
    hard_gate_start = content.find("<HARD-GATE>")
    assert hard_gate_start != -1, (
        "Expected fix-bug SKILL.md to contain a '<HARD-GATE>' block. "
        "The HARD-GATE block must exist before it can be tested for LLM-behavioral coverage."
    )
    hard_gate_end = content.find("</HARD-GATE>", hard_gate_start)
    if hard_gate_end == -1:
        # Fall back to searching a wide window
        hard_gate_end = hard_gate_start + 1200
    gate_text = content[hard_gate_start:hard_gate_end].lower()
    has_llm_behavioral_coverage = any(
        phrase in gate_text
        for phrase in (
            "llm-behavioral",
            "llm behavioral",
            "skill file",
            "agent file",
            "prompt template",
            "model behavior",
        )
    )
    assert has_llm_behavioral_coverage, (
        "Expected the HARD-GATE block in fix-bug SKILL.md to be amended to cover "
        "LLM-behavioral bugs (e.g., 'LLM-behavioral', 'skill file', 'agent file', "
        "'prompt template'). The HARD-GATE must prohibit modifying skill/agent/prompt files "
        "before investigation completes, just as it prohibits code changes. "
        "This is a RED test — the HARD-GATE does not yet contain LLM-behavioral language."
    )


def test_fix_bug_skill_step5_llm_behavioral_exemption() -> None:
    """Step 5 and Step 5.5 must define an explicit exemption for LLM-behavioral bugs.

    LLM-behavioral bugs (prompt regressions, agent guidance gaps) cannot always have
    a traditional RED unit test written before the fix. SKILL.md must acknowledge this
    exemption explicitly: when the bug is classified as LLM-behavioral, the RED test
    requirement in Step 5 and the RED-before-fix gate in Step 5.5 are relaxed or replaced
    with an alternative verification approach (e.g., eval-based verification).

    The exemption must be LLM-behavioral-specific — not a general eval reference that
    happens to exist elsewhere in the file.
    """
    content = _read_skill()
    # Find Step 5.5 section — the RED-before-fix gate where the exemption belongs
    step55_pos = content.find("### Step 5.5:")
    assert step55_pos != -1, (
        "Could not find '### Step 5.5:' in SKILL.md. "
        "Step 5.5 must exist before its LLM-behavioral exemption can be tested."
    )
    # Find Step 6 as upper boundary
    step6_pos = content.find("### Step 6:")
    assert step6_pos != -1, "Could not find '### Step 6:' in SKILL.md."
    # Extract text in Step 5.5 section only (between Step 5.5 and Step 6)
    step55_text = content[step55_pos:step6_pos].lower()
    # Must reference LLM-behavioral specifically in the exemption section
    has_llm_behavioral_exemption = any(
        phrase in step55_text
        for phrase in (
            "llm-behavioral",
            "llm behavioral",
        )
    )
    assert has_llm_behavioral_exemption, (
        "Expected Step 5.5 (RED-before-fix gate) in fix-bug SKILL.md to contain an explicit "
        "exemption for LLM-behavioral bugs (referencing 'LLM-behavioral' or 'LLM behavioral'). "
        "When a bug is LLM-behavioral, the RED-before-fix gate must be relaxed or replaced "
        "with an alternative verification approach. The exemption must appear in the Step 5.5 "
        "section itself. "
        "This is a RED test — Step 5.5 does not yet contain an LLM-behavioral exemption."
    )


def test_fix_bug_skill_bot_psychologist_dispatch() -> None:
    """SKILL.md must reference dispatching the bot-psychologist agent for LLM-behavioral bugs,
    AND plugins/dso/agents/bot-psychologist.md must exist.

    The bot-psychologist agent is the specialist for LLM-behavioral investigation. SKILL.md
    must route LLM-behavioral bugs to this agent. The agent file must exist at the canonical
    path so it can be read directly (or inline when the Agent tool is unavailable).

    Per task spec: must assert SKILL.md dispatches bot-psychologist by reading
    plugins/dso/agents/bot-psychologist.md directly (or inline when Agent tool unavailable),
    NOT via discover-agents.sh.
    """
    content = _read_skill()
    # Assert SKILL.md references bot-psychologist dispatch
    has_bot_psychologist_ref = any(
        phrase in content
        for phrase in (
            "bot-psychologist",
            "bot_psychologist",
        )
    )
    assert has_bot_psychologist_ref, (
        "Expected fix-bug SKILL.md to contain a reference to 'bot-psychologist' as "
        "the investigation agent dispatched for LLM-behavioral bugs. "
        "This is a RED test — SKILL.md does not yet reference the bot-psychologist agent."
    )
    # Assert that the dispatch uses direct file read (not discover-agents.sh)
    has_direct_read_pattern = any(
        phrase in content
        for phrase in (
            "bot-psychologist.md",
            "Read: plugins/dso/agents/bot-psychologist",
            "agents/bot-psychologist",
        )
    )
    assert has_direct_read_pattern, (
        "Expected fix-bug SKILL.md to dispatch bot-psychologist by reading "
        "'plugins/dso/agents/bot-psychologist.md' directly (or inline when the Agent "
        "tool is unavailable), NOT via discover-agents.sh. The dispatch pattern must "
        "reference the agent file path directly (e.g., 'agents/bot-psychologist.md'). "
        "This is a RED test — SKILL.md does not yet use direct-read dispatch for bot-psychologist."
    )
    # Assert the agent file exists at the canonical path
    assert BOT_PSYCHOLOGIST_AGENT_FILE.exists(), (
        f"Expected the bot-psychologist agent file to exist at {BOT_PSYCHOLOGIST_AGENT_FILE}. "
        "The file must be created before SKILL.md can dispatch to it. "
        "This is a RED test — the agent file does not yet exist."
    )


def test_fix_bug_skill_llm_behavioral_subagent_guard() -> None:
    """SKILL.md must contain a SUB-AGENT-GUARD block using Agent tool availability check
    with inline-read fallback for LLM-behavioral investigation.

    The sub-agent guard pattern detects whether the skill is running as a sub-agent
    (by checking if the Agent tool is available). When the Agent tool is unavailable,
    the skill must fall back to reading bot-psychologist.md inline rather than dispatching
    a sub-agent. This ensures LLM-behavioral investigation degrades gracefully in sub-agent
    contexts where nested dispatch is prohibited.
    """
    content = _read_skill()
    has_sub_agent_guard = any(
        phrase in content
        for phrase in (
            "SUB-AGENT-GUARD",
            "<SUB-AGENT-GUARD>",
        )
    )
    assert has_sub_agent_guard, (
        "Expected fix-bug SKILL.md to contain a '<SUB-AGENT-GUARD>' block for the "
        "LLM-behavioral investigation path. The guard detects sub-agent context via "
        "Agent tool availability check and enables inline-read fallback. "
        "This is a RED test — SKILL.md does not yet contain a SUB-AGENT-GUARD block."
    )
    # The guard must reference Agent tool availability as the detection mechanism
    guard_start = content.find("SUB-AGENT-GUARD")
    guard_context = content[guard_start : guard_start + 600].lower()
    has_agent_tool_check = any(
        phrase in guard_context
        for phrase in (
            "agent tool",
            "agent tool availability",
            "agent tool is available",
            "agent tool unavailable",
        )
    )
    assert has_agent_tool_check, (
        "Expected the SUB-AGENT-GUARD block in fix-bug SKILL.md to reference the "
        "Agent tool availability check as the primary sub-agent detection method "
        "(e.g., 'Agent tool', 'Agent tool availability'). "
        "This is a RED test — the guard block does not yet use Agent tool detection."
    )
    # The guard must reference inline-read fallback
    has_inline_fallback = any(
        phrase in guard_context
        for phrase in (
            "inline",
            "read inline",
            "inline read",
            "fallback",
        )
    )
    assert has_inline_fallback, (
        "Expected the SUB-AGENT-GUARD block in fix-bug SKILL.md to define an inline-read "
        "fallback for when the Agent tool is unavailable (e.g., 'inline', 'read inline', "
        "'fallback'). When dispatching bot-psychologist is not possible, the skill must "
        "read the agent file inline instead. "
        "This is a RED test — the guard block does not yet specify the inline-read fallback."
    )


def test_fix_bug_skill_mechanical_excludes_skill_agent_prompt_files() -> None:
    """SKILL.md must explicitly prohibit mechanical classification for files in skills/, agents/, or prompts/.

    Bug f1ed-d7c8: agents misclassify LLM-behavioral bugs as mechanical by
    rationalizing skill/prompt changes as 'obvious text fixes'. The mechanical
    definition must include an explicit exclusion for files in these directories
    so the agent cannot exit the classification at the mechanical check before
    reaching the dual-signal llm-behavioral detection.
    """
    content = _read_skill()
    # The mechanical errors section must contain language that explicitly
    # excludes or prohibits mechanical classification when the affected file
    # is in skills/, agents/, or prompts/ directories.
    mechanical_section_start = content.find("### Mechanical Errors")
    if mechanical_section_start == -1:
        mechanical_section_start = content.find("Mechanical errors")
    assert mechanical_section_start != -1, (
        "Expected SKILL.md to contain a 'Mechanical Errors' section."
    )
    # Find the next section to bound the search
    next_section = content.find("###", mechanical_section_start + 10)
    if next_section == -1:
        next_section = len(content)
    mechanical_text = content[mechanical_section_start:next_section].lower()

    has_exclusion = any(
        phrase in mechanical_text
        for phrase in (
            "skills/",
            "agents/",
            "prompts/",
            "skill file",
            "agent file",
            "prompt file",
            "prompt template",
        )
    ) and any(
        phrase in mechanical_text
        for phrase in (
            "not mechanical",
            "never mechanical",
            "cannot be mechanical",
            "prohibit",
            "exclude",
            "disqualif",
            "must not be classified as mechanical",
        )
    )
    assert has_exclusion, (
        "Expected the Mechanical Errors section in SKILL.md to explicitly exclude "
        "files in skills/, agents/, or prompts/ directories from mechanical "
        "classification. The section must mention these directories AND include "
        "prohibition language (e.g., 'not mechanical', 'cannot be mechanical', "
        "'must not be classified as mechanical'). Without this exclusion, agents "
        "rationalize skill/prompt changes as 'obvious text fixes' and bypass "
        "LLM-behavioral investigation (bug f1ed-d7c8)."
    )
