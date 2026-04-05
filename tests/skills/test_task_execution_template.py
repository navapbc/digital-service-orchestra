"""Tests for the task-execution.md prompt template.

Verifies the template contains required sections and placeholders
for sub-agent dispatch.
"""

import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Add tests/lib to sys.path for shared helpers
_TESTS_LIB = os.path.join(REPO_ROOT, "tests", "lib")
if _TESTS_LIB not in sys.path:
    sys.path.insert(0, _TESTS_LIB)

from markdown_helpers import extract_section as _extract_section_from_template  # noqa: E402

TEMPLATE_PATH = os.path.join(
    REPO_ROOT,
    "plugins",
    "dso",
    "skills",
    "sprint",
    "prompts",
    "task-execution.md",
)


def _read_template() -> str:
    with open(TEMPLATE_PATH) as f:
        return f.read()


class TestTaskExecutionContainsFileOwnershipSection:
    """The template must include file-ownership boundaries for sub-agents."""

    def test_contains_file_ownership_heading(self) -> None:
        content = _read_template()
        assert "### File Ownership Boundaries" in content

    def test_contains_file_ownership_context_placeholder(self) -> None:
        content = _read_template()
        assert "{file_ownership_context}" in content

    def test_contains_other_agents_own_guidance(self) -> None:
        content = _read_template()
        assert "Other agents own" in content

    def test_existing_content_not_disturbed(self) -> None:
        """Existing template content must remain intact."""
        content = _read_template()
        assert "ticket show {id}" in content
        assert "### Rules" in content
        assert "### Instructions" in content


class TestTaskExecutionDiscoveredBugType:
    """Sub-agents must use '-t bug' when creating tickets for discovered bugs.

    CLAUDE.md rule 'Always Do #9' instructs sub-agents to search for the same
    anti-pattern elsewhere and create tracking tickets. Those tickets must use
    type 'bug', not the default 'task'. The template's discovered-work example
    must use '-t bug' so sub-agents follow the correct convention.
    """

    def test_discovered_work_uses_bug_type_not_task(self) -> None:
        """The ticket create example in the Discovered work section must use bug type.

        The old template used '-t task' for all discovered work, causing orphan
        bug tickets to be misclassified. Sub-agents must use 'bug' as the ticket
        type when creating tickets for discovered defects or anti-patterns.
        Accepted forms: positional 'ticket create bug' or flag '-t bug' / '--type bug'.
        """
        content = _read_template()
        assert (
            "ticket create bug" in content
            or "-t bug" in content
            or "--type bug" in content
        ), (
            "task-execution.md must instruct sub-agents to create bug-typed tickets "
            "for discovered bugs. Found no 'ticket create bug', '-t bug', or "
            "'--type bug' in the template."
        )

    def test_discovered_work_does_not_use_task_type_for_bugs(self) -> None:
        """The ticket create example for discovered bugs must not use '-t task'.

        Using '-t task' as the type for bug ticket creation causes orphan bug
        tickets to appear as tasks, making triage harder.
        """
        import re

        content = _read_template()
        # The ticket create line in the Discovered work section (step 8) must not
        # instruct sub-agents to use '-t task' when creating tracking tickets
        # for discovered defects.
        # Match lines that actually invoke ticket create with -t task as the type
        # argument (not lines that merely mention '-t task' in a comment).
        # The pattern looks for: ticket create followed (possibly with other args)
        # by -t task where 'task' is a positional value (not part of a longer word).
        bad_pattern = re.compile(r"ticket create\b.*?\B-t task\b")
        lines = content.splitlines()
        for i, line in enumerate(lines):
            if bad_pattern.search(line):
                context = "\n".join(lines[max(0, i - 3) : i + 3])
                assert False, (
                    f"task-execution.md line {i + 1} uses 'ticket create ... -t task' "
                    "which causes discovered bug tickets to be misclassified as tasks. "
                    f"Context:\n{context}"
                )


class TestTaskExecutionProhibitedFixPatterns:
    """task-execution.md must contain a Prohibited Fix Patterns section.

    TDD spec for task 2eae-abec (RED task):
    The template dispatched to sub-agents must include a section documenting
    5 anti-patterns that sub-agents must never use to make tests pass by hiding
    failures rather than fixing root causes:
      1. Skipping or removing failing tests
      2. Loosening assertions to make tests pass
      3. Adding broad exception handlers to swallow errors
      4. Downgrading error severity (e.g., assert → warning)
      5. Commenting out failing code
    """

    def _get_section(self) -> str:
        """Return the Prohibited Fix Patterns section content from the template."""
        content = _read_template()
        for prefix in ("## Prohibited Fix Patterns", "### Prohibited Fix Patterns"):
            section = _extract_section_from_template(content, prefix)
            if section:
                return section
        return ""

    def test_prohibited_fix_patterns_section_exists(self) -> None:
        """The template must contain a 'Prohibited Fix Patterns' section heading."""
        content = _read_template()
        assert (
            "## Prohibited Fix Patterns" in content
            or "### Prohibited Fix Patterns" in content
        ), (
            "Expected task-execution.md to contain a 'Prohibited Fix Patterns' section "
            "heading (## or ###). This section documents anti-patterns that sub-agents "
            "must never use to make tests pass by hiding failures rather than fixing "
            "root causes."
        )

    def test_anti_pattern_1_skip_tests_present(self) -> None:
        """The section must document the 'skipping/removing tests' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert (
            "pytest.mark.skip" in section
            or "@skip" in section
            or "skip" in section.lower()
        ), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'skipping or removing tests' anti-pattern."
        )
        assert "```" in section, (
            "Expected 'Prohibited Fix Patterns' section to use fenced code blocks (```) "
            "for anti-pattern code examples."
        )

    def test_anti_pattern_2_loosen_assertions_present(self) -> None:
        """The section must document the 'loosening assertions' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert "loosen" in section.lower() or "assertion" in section.lower(), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'loosening assertions' anti-pattern."
        )

    def test_anti_pattern_3_broad_exception_present(self) -> None:
        """The section must document the 'broad exception handlers' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert "except" in section or "exception" in section.lower(), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'broad exception handlers' anti-pattern."
        )

    def test_anti_pattern_4_downgrade_severity_present(self) -> None:
        """The section must document the 'downgrading error severity' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert (
            "warning" in section.lower()
            or "severity" in section.lower()
            or "downgrade" in section.lower()
        ), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'downgrading error severity' anti-pattern."
        )

    def test_anti_pattern_5_comment_out_present(self) -> None:
        """The section must document the 'commenting out failing code' anti-pattern."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert (
            "comment" in section.lower()
            or "# assert" in section
            or "# check" in section
        ), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to document "
            "the 'commenting out failing code' anti-pattern."
        )

    def test_do_this_instead_alternatives_present(self) -> None:
        """The section must include 'Do this instead' alternatives for anti-patterns."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert "Do this instead" in section or "Instead" in section, (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to provide "
            "'Do this instead' alternatives so sub-agents know the correct approach."
        )

    def test_rationale_present(self) -> None:
        """The section must include rationale explaining why these patterns are prohibited."""
        section = self._get_section()
        assert section, "Prohibited Fix Patterns section not found in task-execution.md"
        assert any(
            phrase in section.lower()
            for phrase in [
                "root cause",
                "hides",
                "masks",
                "cover",
                "real failure",
                "genuine",
            ]
        ), (
            "Expected 'Prohibited Fix Patterns' section in task-execution.md to include "
            "rationale for why each anti-pattern is prohibited (e.g., 'hides the root cause')."
        )


class TestConfidenceSignalInReportOutput:
    """task-execution.md must include CONFIDENT/UNCERTAIN signal in the step 9 report output.

    The confidence signal contract (plugins/dso/docs/contracts/confidence-signal.md) requires
    implementation sub-agents to emit CONFIDENT or UNCERTAIN:<reason> in their final report
    alongside STATUS:, FILES_MODIFIED:, etc. The instruction must appear in the report output
    section (step 9), not just as a general instruction elsewhere in the template.
    """

    @staticmethod
    def _get_report_section(content: str) -> str:
        """Extract the step 9 report output section from the template.

        The report output section starts at the line containing 'Report output:'
        and ends at the next heading or numbered step.
        """
        lines = content.splitlines()
        in_section = False
        section_lines: list[str] = []
        for line in lines:
            if "Report output:" in line:
                in_section = True
                section_lines.append(line)
                continue
            if in_section:
                # Stop at the next heading or next numbered step
                stripped = line.strip()
                if stripped.startswith("#") or (
                    stripped and stripped[0].isdigit() and "." in stripped[:4]
                ):
                    break
                section_lines.append(line)
        return "\n".join(section_lines)

    def test_confident_signal_present_in_report_output_section(self) -> None:
        """The step 9 report output block must include the CONFIDENT signal."""
        content = _read_template()
        report_section = self._get_report_section(content)
        assert report_section, (
            "Could not find 'Report output:' section in task-execution.md"
        )
        assert "CONFIDENT" in report_section, (
            "The step 9 report output section in task-execution.md must include 'CONFIDENT' "
            "as a signal line. The sprint orchestrator parses this from the sub-agent output."
        )

    def test_uncertain_signal_present_in_report_output_section(self) -> None:
        """The step 9 report output block must include the UNCERTAIN signal."""
        content = _read_template()
        report_section = self._get_report_section(content)
        assert report_section, (
            "Could not find 'Report output:' section in task-execution.md"
        )
        assert "UNCERTAIN:" in report_section, (
            "The step 9 report output section in task-execution.md must include 'UNCERTAIN:' "
            "as a signal line. The sprint orchestrator parses this from the sub-agent output."
        )

    def test_confidence_signal_not_only_elsewhere_in_file(self) -> None:
        """The confidence signal must appear in the report output section, not just elsewhere.

        This catches the case where someone adds confidence instructions in a general
        section but forgets to add the actual signal lines to the report output block.
        """
        content = _read_template()
        report_section = self._get_report_section(content)
        assert report_section, (
            "Could not find 'Report output:' section in task-execution.md"
        )
        # Both signals must be in the report section specifically
        has_confident_in_report = "CONFIDENT" in report_section
        has_uncertain_in_report = "UNCERTAIN:" in report_section
        assert has_confident_in_report and has_uncertain_in_report, (
            "Both CONFIDENT and UNCERTAIN: signals must appear in the step 9 report output "
            "section of task-execution.md (not just in a general instruction section). "
            f"CONFIDENT in report: {has_confident_in_report}, "
            f"UNCERTAIN: in report: {has_uncertain_in_report}"
        )


class TestCLIUserTagProhibitionPropagation:
    """Highest-traffic prompt files must propagate the CLI_user tag prohibition.

    TDD spec for task 0d64-0eab: Sub-agent prompt files that contain
    'ticket create bug' examples must ensure sub-agents know not to use
    --tags CLI_user on autonomously-created bug tickets. This is enforced
    either by referencing SUB-AGENT-BOUNDARIES.md (which contains the
    prohibition) or by including explicit CLI_user prohibition text near
    the ticket create bug command.
    """

    PROMPT_FILES = {
        "sprint/task-execution.md": os.path.join(
            REPO_ROOT,
            "plugins",
            "dso",
            "skills",
            "sprint",
            "prompts",
            "task-execution.md",
        ),
        "debug-everything/triage-and-create.md": os.path.join(
            REPO_ROOT,
            "plugins",
            "dso",
            "skills",
            "debug-everything",
            "prompts",
            "triage-and-create.md",
        ),
        "debug-everything/fix-task-tdd.md": os.path.join(
            REPO_ROOT,
            "plugins",
            "dso",
            "skills",
            "debug-everything",
            "prompts",
            "fix-task-tdd.md",
        ),
        "debug-everything/test-failure-fix.md": os.path.join(
            REPO_ROOT,
            "plugins",
            "dso",
            "skills",
            "debug-everything",
            "prompts",
            "test-failure-fix.md",
        ),
    }

    def _check_propagation(self, file_path: str) -> bool:
        """Return True if the file references SUB-AGENT-BOUNDARIES or contains CLI_user prohibition.

        A bare mention of CLI_user is insufficient — the mention must appear within 3 lines of
        prohibition language (Do NOT / MUST NOT / must not / autonomously) to distinguish
        'do not use CLI_user for autonomous bugs' from 'use CLI_user for user-reported bugs'.
        """
        with open(file_path) as f:
            content = f.read()
        if "SUB-AGENT-BOUNDARIES" in content:
            return True
        lines = content.splitlines()
        prohibition_words = (
            "Do NOT",
            "MUST NOT",
            "must not",
            "not use",
            "autonomously",
        )
        for i, line in enumerate(lines):
            if "CLI_user" in line:
                context = "\n".join(lines[max(0, i - 3) : i + 4])
                if any(word in context for word in prohibition_words):
                    return True
        return False

    def test_sprint_task_execution_propagates_cli_user_prohibition(self) -> None:
        """sprint/task-execution.md must reference SUB-AGENT-BOUNDARIES or mention CLI_user."""
        path = self.PROMPT_FILES["sprint/task-execution.md"]
        assert self._check_propagation(path), (
            "sprint/prompts/task-execution.md contains 'ticket create bug' examples but "
            "neither references SUB-AGENT-BOUNDARIES.md nor contains explicit CLI_user "
            "prohibition. Sub-agents dispatched via this template may incorrectly apply "
            "--tags CLI_user to autonomously-discovered bug tickets."
        )

    def test_triage_and_create_propagates_cli_user_prohibition(self) -> None:
        """debug-everything/triage-and-create.md must reference SUB-AGENT-BOUNDARIES or mention CLI_user."""
        path = self.PROMPT_FILES["debug-everything/triage-and-create.md"]
        assert self._check_propagation(path), (
            "debug-everything/prompts/triage-and-create.md contains 'ticket create bug' "
            "examples but neither references SUB-AGENT-BOUNDARIES.md nor contains explicit "
            "CLI_user prohibition. Triage agents dispatched via this template may "
            "incorrectly apply --tags CLI_user to autonomously-discovered bug tickets."
        )

    def test_fix_task_tdd_propagates_cli_user_prohibition(self) -> None:
        """debug-everything/fix-task-tdd.md must reference SUB-AGENT-BOUNDARIES or mention CLI_user."""
        path = self.PROMPT_FILES["debug-everything/fix-task-tdd.md"]
        assert self._check_propagation(path), (
            "debug-everything/prompts/fix-task-tdd.md contains 'ticket create bug' "
            "examples but neither references SUB-AGENT-BOUNDARIES.md nor contains explicit "
            "CLI_user prohibition. Fix agents dispatched via this template may "
            "incorrectly apply --tags CLI_user to autonomously-discovered bug tickets."
        )

    def test_test_failure_fix_propagates_cli_user_prohibition(self) -> None:
        """debug-everything/test-failure-fix.md must reference SUB-AGENT-BOUNDARIES or mention CLI_user."""
        path = self.PROMPT_FILES["debug-everything/test-failure-fix.md"]
        assert self._check_propagation(path), (
            "debug-everything/prompts/test-failure-fix.md contains 'ticket create bug' "
            "examples but neither references SUB-AGENT-BOUNDARIES.md nor contains explicit "
            "CLI_user prohibition. Fix agents dispatched via this template may "
            "incorrectly apply --tags CLI_user to autonomously-discovered bug tickets."
        )


class TestTaskExecutionReadFirstGate:
    """task-execution.md must include a mandatory file-list reading instruction (read_first gate).

    TDD spec for the read_first gate: Before implementing, sub-agents must be
    instructed to read a list of impacted files so they understand the full
    context of what they are changing. The template must contain an explicit
    instruction directing agents to read the files listed in the task's file
    impact section before beginning implementation.
    """

    def test_read_first_gate_instruction_present(self) -> None:
        """The template must contain a mandatory file-reading instruction.

        The instruction must direct agents to read files before starting work
        so they understand existing patterns and do not duplicate logic.
        """
        content = _read_template()
        assert any(
            phrase in content
            for phrase in [
                "read_first",
                "file_impact",
                "file impact",
                "mandatory.*read",
                "must read",
                "Read each file",
                "read each file",
                "read the files",
                "Read the files",
            ]
        ), (
            "task-execution.md must contain a mandatory file-reading instruction "
            "(read_first gate) directing agents to read impacted files before "
            "beginning implementation. Found none of: read_first, file_impact, "
            "'must read', 'Read each file', 'read the files'."
        )

    def test_read_first_gate_precedes_implementation_step(self) -> None:
        """The file-reading instruction must appear before the implementation step (step 5).

        The read_first gate is only effective if agents read files before
        they start implementing, not after. The instruction must appear in
        steps 1–4 or in the context-loading step.
        """
        content = _read_template()
        # Find position of the read_first gate instruction
        read_first_markers = [
            "read_first",
            "file_impact",
            "must read",
            "Read each file",
            "read each file",
            "read the files",
            "Read the files",
        ]
        gate_pos = -1
        for marker in read_first_markers:
            idx = content.find(marker)
            if idx != -1:
                gate_pos = idx
                break

        # Find the implementation step (step 5)
        impl_pos = content.find("5. Implement the task")
        if impl_pos == -1:
            impl_pos = content.find("5. Implement")

        assert gate_pos != -1, (
            "task-execution.md must contain a read_first gate instruction. "
            "Expected one of: read_first, file_impact, must read, Read each file, "
            "read the files."
        )
        assert impl_pos != -1, (
            "task-execution.md must contain an implementation step (step 5)."
        )
        assert gate_pos < impl_pos, (
            "The read_first gate instruction must appear before the implementation "
            f"step. Gate found at position {gate_pos}, implementation at {impl_pos}."
        )


class TestTaskExecutionExemplarDiscovery:
    """task-execution.md must instruct agents to discover suffix-matched exemplars.

    TDD spec: When a task involves creating a new file (create-action), agents
    must be directed to find exemplar files — existing files with the same suffix
    (e.g., test_*.py, *_handler.sh) — to understand naming conventions and
    patterns before implementing. The template must include this suffix-based
    exemplar discovery instruction.
    """

    def test_exemplar_discovery_instruction_present(self) -> None:
        """The template must contain an exemplar discovery instruction for create-action tasks."""
        content = _read_template()
        assert any(
            phrase in content
            for phrase in [
                "exemplar",
                "suffix match",
                "suffix-match",
                "sibling file",
                "sibling files",
                "same suffix",
                "existing.*similar",
            ]
        ), (
            "task-execution.md must instruct agents to find exemplar files (suffix-matched "
            "sibling files) when creating new files. Found no mention of: exemplar, "
            "'suffix match', 'sibling file', 'same suffix'."
        )

    def test_exemplar_discovery_applies_to_create_action(self) -> None:
        """The exemplar discovery instruction must specifically mention create-action files.

        This gate applies when the task creates a new file — not when it modifies
        an existing one. The template must distinguish the create-action case.
        """
        content = _read_template()
        # The create-action context should appear near the exemplar instruction
        assert any(
            phrase in content
            for phrase in [
                "create",
                "new file",
                "creating",
            ]
        ) and any(
            phrase in content
            for phrase in [
                "exemplar",
                "suffix",
                "sibling",
            ]
        ), (
            "task-execution.md must mention both create-action context and exemplar/suffix "
            "discovery together, so agents know to look for sibling files when creating "
            "new files."
        )


class TestTaskExecutionNamingConventions:
    """task-execution.md must instruct agents to handle multiple naming conventions.

    TDD spec: When discovering exemplars or reading file lists, agents must be
    aware that different file types use different naming conventions. The template
    must explicitly mention PascalCase, snake_case, and kebab-case so agents
    check for all convention variants when searching for exemplars.
    """

    def test_pascal_case_naming_convention_mentioned(self) -> None:
        """The template must mention PascalCase naming convention."""
        content = _read_template()
        assert "PascalCase" in content, (
            "task-execution.md must mention PascalCase naming convention so agents "
            "know to check for PascalCase file names when discovering exemplars."
        )

    def test_snake_case_naming_convention_mentioned(self) -> None:
        """The template must mention snake_case naming convention."""
        content = _read_template()
        assert "snake_case" in content, (
            "task-execution.md must mention snake_case naming convention so agents "
            "know to check for snake_case file names when discovering exemplars."
        )

    def test_kebab_case_naming_convention_mentioned(self) -> None:
        """The template must mention kebab-case naming convention."""
        content = _read_template()
        assert "kebab" in content or "kebab-case" in content, (
            "task-execution.md must mention kebab-case naming convention so agents "
            "know to check for kebab-case file names when discovering exemplars."
        )

    def test_naming_conventions_appear_near_exemplar_or_read_first(self) -> None:
        """Naming convention guidance must appear near the exemplar discovery or read_first gate.

        Naming conventions mentioned far from the file-reading context are unhelpful.
        They must appear within the same logical step or block.
        """
        content = _read_template()
        # Find any naming convention mention
        pascal_pos = content.find("PascalCase")
        snake_pos = content.find("snake_case")
        kebab_pos = content.find("kebab")

        # Find exemplar or read_first gate
        gate_markers = [
            "exemplar",
            "suffix",
            "read_first",
            "file_impact",
            "read the files",
        ]
        gate_pos = -1
        for marker in gate_markers:
            idx = content.find(marker)
            if idx != -1:
                gate_pos = idx
                break

        # At least one convention must be near the gate (within 1000 chars)
        assert gate_pos != -1, (
            "task-execution.md must contain a read_first or exemplar gate "
            "for this proximity check to be meaningful."
        )
        positions = [p for p in [pascal_pos, snake_pos, kebab_pos] if p != -1]
        assert any(abs(p - gate_pos) < 1000 for p in positions), (
            "Naming convention guidance (PascalCase, snake_case, kebab) must appear "
            f"within 1000 characters of the exemplar/read_first gate (gate at {gate_pos}). "
            f"Positions: PascalCase={pascal_pos}, snake_case={snake_pos}, kebab={kebab_pos}."
        )


class TestTaskExecutionStep4ValidatesExistingTests:
    """task-execution.md Step 4 must instruct agents to validate existing RED tests.

    TDD spec: Step 4 of the template currently says 'Write unit tests ... before
    implementing'. For tasks that are GREEN implementations of RED test tasks,
    this is wrong — there are already RED tests waiting to be satisfied. Step 4
    must be updated to instruct agents to first check for existing RED tests and
    validate them, rather than always writing new tests.
    """

    def test_step4_mentions_existing_tests(self) -> None:
        """Step 4 must direct agents to check for existing RED tests before writing new ones."""
        content = _read_template()
        # Find step 4 content (between "4." and "5.")
        step4_start = content.find("4.")
        step5_start = content.find("5.", step4_start + 2) if step4_start != -1 else -1

        assert step4_start != -1, "task-execution.md must contain a step 4."
        step4_content = (
            content[step4_start:step5_start]
            if step5_start != -1
            else content[step4_start : step4_start + 500]
        )

        assert any(
            phrase in step4_content
            for phrase in [
                "existing test",
                "existing RED test",
                "RED test",
                "validate.*test",
                "check for.*test",
                "already.*test",
            ]
        ), (
            "task-execution.md Step 4 must instruct agents to check for and validate "
            "existing RED tests before writing new ones. This ensures GREEN implementation "
            "tasks satisfy already-written RED tests rather than writing duplicate tests. "
            f"Step 4 content: {step4_content[:300]!r}"
        )

    def test_step4_does_not_unconditionally_require_new_tests(self) -> None:
        """Step 4 must not unconditionally require writing new tests for all tasks.

        Some tasks are GREEN implementations — writing new tests would duplicate
        the existing RED tests. Step 4 must make test-writing conditional on
        whether RED tests already exist.
        """
        content = _read_template()
        step4_start = content.find("4.")
        step5_start = content.find("5.", step4_start + 2) if step4_start != -1 else -1

        assert step4_start != -1, "task-execution.md must contain a step 4."
        step4_content = (
            content[step4_start:step5_start]
            if step5_start != -1
            else content[step4_start : step4_start + 500]
        )

        # The step should have conditional language (if, when, only if)
        # OR explicitly mention validating existing tests
        assert any(
            phrase in step4_content.lower()
            for phrase in [
                "if no",
                "if existing",
                "only if",
                "when no",
                "validate existing",
                "check for existing",
                "run existing",
            ]
        ), (
            "task-execution.md Step 4 must use conditional language for test writing "
            "(e.g., 'only if no existing RED tests', 'validate existing RED tests first'). "
            "Unconditionally requiring new tests causes GREEN implementation tasks to write "
            f"duplicate tests. Step 4 content: {step4_content[:300]!r}"
        )


class TestTaskExecutionCheckpoint2RecordsFilesAndExemplars:
    """task-execution.md CHECKPOINT 2/6 must record files and exemplars read.

    TDD spec: The current CHECKPOINT 2/6 text ('Code patterns understood') is
    too vague. It must be updated to explicitly instruct agents to record which
    files and exemplars they read in the checkpoint note. This makes it easy for
    the orchestrator to audit what context the sub-agent had when implementing.
    """

    def test_checkpoint_2_mentions_files_read(self) -> None:
        """CHECKPOINT 2/6 comment text must mention recording files read."""
        content = _read_template()
        # Find the checkpoint 2 line
        ckpt2_idx = content.find("CHECKPOINT 2/6")
        assert ckpt2_idx != -1, (
            "task-execution.md must contain a CHECKPOINT 2/6 instruction."
        )
        # Check within 200 chars of the checkpoint marker for files/exemplars mention
        ckpt2_context = content[ckpt2_idx : ckpt2_idx + 300]
        assert any(
            phrase in ckpt2_context
            for phrase in [
                "files",
                "exemplar",
                "read",
            ]
        ) and any(
            phrase in ckpt2_context
            for phrase in [
                "files read",
                "exemplars read",
                "files and exemplar",
                "exemplar.*read",
                "read.*files",
            ]
        ), (
            "task-execution.md CHECKPOINT 2/6 must instruct agents to record which "
            "files and exemplars they read. Current text is too vague — the checkpoint "
            "comment should say something like 'CHECKPOINT 2/6: Code patterns understood "
            "(read: file1.py, file2.sh; exemplars: test_foo.py)'. "
            f"Found checkpoint 2/6 context: {ckpt2_context!r}"
        )

    def test_checkpoint_2_template_includes_exemplar_placeholder(self) -> None:
        """The CHECKPOINT 2/6 sample comment must include a placeholder for exemplars.

        Sub-agents follow the template literally. If the sample checkpoint comment
        does not show where to list exemplars, agents will not include them.
        """
        content = _read_template()
        ckpt2_idx = content.find("CHECKPOINT 2/6")
        assert ckpt2_idx != -1, (
            "task-execution.md must contain a CHECKPOINT 2/6 instruction."
        )
        ckpt2_context = content[ckpt2_idx : ckpt2_idx + 400]
        assert "exemplar" in ckpt2_context or "files read" in ckpt2_context, (
            "task-execution.md CHECKPOINT 2/6 sample comment must include 'exemplar' "
            "or 'files read' as a placeholder so agents know to list the files and "
            "exemplars they read when writing this checkpoint. "
            f"Found: {ckpt2_context!r}"
        )
