"""Structural assertions for the PREPLANNING_CONTEXT ticket-comment migration.

The migration moves preplanning context storage from /tmp files to ticket comments,
affecting three skills: preplanning (writes), implementation-plan (reads), and
design-wireframe (reads). These tests verify that the storage/retrieval contract
is documented in each skill's SKILL.md and that the shared parsing/fallback
behaviors are consistent across all three consumers.

Covers:
  1. preplanning/SKILL.md writes PREPLANNING_CONTEXT to ticket comment
  2. implementation-plan/SKILL.md reads PREPLANNING_CONTEXT from ticket comment
  3. design-wireframe/SKILL.md reads PREPLANNING_CONTEXT from ticket comment
  4. Fallback behavior on JSON parse failure documented in each consumer
  5. Staleness check (7-day generatedAt) documented in each consumer
  6. ARG_MAX constraint boundary accurately attributed to ticket-comment.sh in
     the known-limitation note (not write_commit_event)
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PREPLANNING_SKILL = (
    REPO_ROOT / "plugins" / "dso" / "skills" / "preplanning" / "SKILL.md"
)
IMPL_PLAN_SKILL = (
    REPO_ROOT / "plugins" / "dso" / "skills" / "implementation-plan" / "SKILL.md"
)
DESIGN_WIREFRAME_SKILL = (
    REPO_ROOT / "plugins" / "dso" / "skills" / "design-wireframe" / "SKILL.md"
)


def _read(path: pathlib.Path) -> str:
    return path.read_text()


class TestPreplanningContextWrite:
    """preplanning/SKILL.md must document writing PREPLANNING_CONTEXT to a ticket comment."""

    def test_preplanning_writes_context_comment(self) -> None:
        """preplanning/SKILL.md must reference writing PREPLANNING_CONTEXT to a ticket comment."""
        content = _read(PREPLANNING_SKILL)
        assert "PREPLANNING_CONTEXT" in content, (
            "Expected preplanning/SKILL.md to mention 'PREPLANNING_CONTEXT' — the key prefix "
            "written to the epic ticket comment during Step 5a so that downstream skills can "
            "retrieve it across sessions."
        )

    def test_preplanning_uses_ticket_comment_command(self) -> None:
        """preplanning/SKILL.md must use .claude/scripts/dso ticket comment to write the context."""
        content = _read(PREPLANNING_SKILL)
        assert "ticket comment" in content or 'ticket", "comment"' in content, (
            "Expected preplanning/SKILL.md to reference the 'ticket comment' CLI subcommand "
            "for writing the PREPLANNING_CONTEXT payload to the epic ticket."
        )

    def test_preplanning_uses_python_subprocess(self) -> None:
        """preplanning/SKILL.md must use Python subprocess for the ticket comment write."""
        content = _read(PREPLANNING_SKILL)
        assert "subprocess" in content, (
            "Expected preplanning/SKILL.md to use Python subprocess to invoke the ticket comment "
            "command, avoiding the outer shell's ARG_MAX limit for large JSON payloads."
        )

    def test_preplanning_write_is_optional_cache(self) -> None:
        """preplanning/SKILL.md must document that the PREPLANNING_CONTEXT write is optional (non-fatal on failure)."""
        content = _read(PREPLANNING_SKILL)
        has_optional_note = (
            "optional cache" in content
            or "log a warning and continue" in content
            or "continuing without cache write" in content
        )
        assert has_optional_note, (
            "Expected preplanning/SKILL.md to document that the PREPLANNING_CONTEXT comment write "
            "is an optional cache — if the ticket CLI call fails, the skill must log a warning "
            "and continue rather than aborting the phase."
        )

    def test_preplanning_known_limitation_names_ticket_comment_sh(self) -> None:
        """The known-limitation note must identify ticket-comment.sh as the actual ARG_MAX boundary."""
        content = _read(PREPLANNING_SKILL)
        assert "ticket-comment.sh" in content, (
            "Expected preplanning/SKILL.md's known-limitation note to identify 'ticket-comment.sh' "
            "as the actual ARG_MAX constraint boundary. The Python subprocess call avoids the outer "
            "shell's ARG_MAX, but ticket-comment.sh passes the body as a shell argument to its "
            "internal python3 invocation, which is the real limit. The note previously attributed "
            "this to write_commit_event, which was inaccurate."
        )

    def test_preplanning_known_limitation_recommends_temp_file(self) -> None:
        """The known-limitation note must recommend a temp file approach as the proper fix."""
        content = _read(PREPLANNING_SKILL)
        assert "temp file" in content, (
            "Expected preplanning/SKILL.md's known-limitation note to recommend writing the payload "
            "to a temp file and passing the path instead of the body directly, as the proper fix "
            "for the ARG_MAX boundary in ticket-comment.sh."
        )


class TestImplementationPlanContextRead:
    """implementation-plan/SKILL.md must document reading PREPLANNING_CONTEXT from a ticket comment."""

    def test_impl_plan_reads_preplanning_context(self) -> None:
        """implementation-plan/SKILL.md must reference reading PREPLANNING_CONTEXT from ticket comments."""
        content = _read(IMPL_PLAN_SKILL)
        assert "PREPLANNING_CONTEXT" in content, (
            "Expected implementation-plan/SKILL.md to mention 'PREPLANNING_CONTEXT' — the key prefix "
            "that the skill reads from the parent epic's ticket comments to load cached planning context."
        )

    def test_impl_plan_reads_last_comment(self) -> None:
        """implementation-plan/SKILL.md must specify using the last PREPLANNING_CONTEXT comment."""
        content = _read(IMPL_PLAN_SKILL)
        assert "last" in content and "PREPLANNING_CONTEXT" in content, (
            "Expected implementation-plan/SKILL.md to specify reading the *last* comment whose body "
            "starts with 'PREPLANNING_CONTEXT:' (in case preplanning ran multiple times on the same epic)."
        )

    def test_impl_plan_strips_prefix_before_parse(self) -> None:
        """implementation-plan/SKILL.md must document stripping the PREPLANNING_CONTEXT: prefix before JSON parsing."""
        content = _read(IMPL_PLAN_SKILL)
        assert "strip" in content or "prefix" in content, (
            "Expected implementation-plan/SKILL.md to document stripping the 'PREPLANNING_CONTEXT: ' "
            "prefix from the comment body before parsing the JSON payload."
        )

    def test_impl_plan_falls_through_on_invalid_json(self) -> None:
        """implementation-plan/SKILL.md must document falling through to full analysis when JSON parse fails."""
        content = _read(IMPL_PLAN_SKILL)
        has_fallback = (
            "not valid JSON" in content
            or "invalid JSON" in content
            or "fall through" in content
            or "treat as not found" in content
        )
        assert has_fallback, (
            "Expected implementation-plan/SKILL.md to document fallback behavior when the "
            "PREPLANNING_CONTEXT comment body is not valid JSON: treat as not found and fall "
            "through to the full analysis path (step 4)."
        )

    def test_impl_plan_checks_staleness(self) -> None:
        """implementation-plan/SKILL.md must document the 7-day generatedAt staleness check."""
        content = _read(IMPL_PLAN_SKILL)
        assert "7 days" in content or "7-day" in content or "generatedAt" in content, (
            "Expected implementation-plan/SKILL.md to document checking the 'generatedAt' timestamp "
            "in the PREPLANNING_CONTEXT payload and treating it as stale if older than 7 days."
        )


class TestDesignWireframeContextRead:
    """design-wireframe/SKILL.md must document reading PREPLANNING_CONTEXT from a ticket comment."""

    def test_design_wireframe_reads_preplanning_context(self) -> None:
        """design-wireframe/SKILL.md must reference reading PREPLANNING_CONTEXT from ticket comments."""
        content = _read(DESIGN_WIREFRAME_SKILL)
        assert "PREPLANNING_CONTEXT" in content, (
            "Expected design-wireframe/SKILL.md to mention 'PREPLANNING_CONTEXT' — the key prefix "
            "that the skill reads from the parent epic's ticket comments to load cached planning context."
        )

    def test_design_wireframe_reads_last_comment(self) -> None:
        """design-wireframe/SKILL.md must specify using the last PREPLANNING_CONTEXT comment."""
        content = _read(DESIGN_WIREFRAME_SKILL)
        assert "last" in content and "PREPLANNING_CONTEXT" in content, (
            "Expected design-wireframe/SKILL.md to specify reading the *last* comment whose body "
            "starts with 'PREPLANNING_CONTEXT:' (in case preplanning ran multiple times on the same epic)."
        )

    def test_design_wireframe_strips_prefix_before_parse(self) -> None:
        """design-wireframe/SKILL.md must document stripping the PREPLANNING_CONTEXT: prefix before JSON parsing."""
        content = _read(DESIGN_WIREFRAME_SKILL)
        assert "strip" in content or "prefix" in content, (
            "Expected design-wireframe/SKILL.md to document stripping the 'PREPLANNING_CONTEXT: ' "
            "prefix from the comment body before parsing the JSON payload."
        )

    def test_design_wireframe_falls_through_on_invalid_json(self) -> None:
        """design-wireframe/SKILL.md must document falling through to full analysis when JSON parse fails."""
        content = _read(DESIGN_WIREFRAME_SKILL)
        has_fallback = (
            "not valid JSON" in content
            or "invalid JSON" in content
            or "fall through" in content
            or "treat as not found" in content
        )
        assert has_fallback, (
            "Expected design-wireframe/SKILL.md to document fallback behavior when the "
            "PREPLANNING_CONTEXT comment body is not valid JSON: treat as not found and fall "
            "through to the full fetch path."
        )

    def test_design_wireframe_checks_staleness(self) -> None:
        """design-wireframe/SKILL.md must document the 7-day generatedAt staleness check."""
        content = _read(DESIGN_WIREFRAME_SKILL)
        assert "7 days" in content or "7-day" in content or "generatedAt" in content, (
            "Expected design-wireframe/SKILL.md to document checking the 'generatedAt' timestamp "
            "in the PREPLANNING_CONTEXT payload and treating it as stale if older than 7 days."
        )
