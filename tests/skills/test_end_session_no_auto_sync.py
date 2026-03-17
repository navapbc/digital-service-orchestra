"""Test that end-session/SKILL.md does not contain an unconditional tk sync instruction.

TDD spec: grep end-session/SKILL.md for unconditional tk sync invocations outside
comments/notes; assert zero matches.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "skills" / "end-session" / "SKILL.md"


def test_end_session_no_auto_sync() -> None:
    """End-session skill must not contain active (non-comment) tk sync instructions.

    Active means: the line is not a comment (does not start with '#' after stripping
    whitespace) and is not inside a note/warning block that marks sync as manual/disabled.
    """
    content = SKILL_MD.read_text()

    # Lines that contain 'tk sync' and are not comments/disabled markers
    active_sync_lines = []
    for lineno, line in enumerate(content.splitlines(), start=1):
        stripped = line.strip()
        # Skip blank lines
        if not stripped:
            continue
        # Skip pure comment lines (markdown or shell)
        if stripped.startswith("#") or stripped.startswith("<!--"):
            continue
        if "tk sync" in line:
            active_sync_lines.append((lineno, line))

    # If there are active tk sync lines, verify they are annotated as manual/disabled
    unannotated = []
    lines = content.splitlines()
    for lineno, line in active_sync_lines:
        # Check the line itself and the preceding line for a disabled/manual annotation
        preceding = lines[lineno - 2] if lineno >= 2 else ""
        annotation_present = any(
            marker in (line + preceding).lower()
            for marker in ("manual", "disabled", "temporarily", "manually")
        )
        if not annotation_present:
            unannotated.append((lineno, line))

    assert not unannotated, (
        f"end-session/SKILL.md contains {len(unannotated)} unconditional active tk sync "
        f"invocation(s). Either disable them or annotate with 'manual'/'disabled':\n"
        + "\n".join(f"  line {ln}: {line_text}" for ln, line_text in unannotated)
    )
