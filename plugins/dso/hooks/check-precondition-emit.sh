#!/usr/bin/env bash
# check-precondition-emit.sh
# Pre-commit hook: detect graceful-degradation trigger keywords added to skill
# files without a nearby EMIT-PRECONDITIONS landmark (within 10 lines in the hunk).
#
# Trigger keywords (case-insensitive):
#   fall through, safe fallback, log a warning and continue,
#   continue without, fall back, graceful degradation
#
# Suppression: append '# precondition-emit-ok' to the offending line.
# Override diff source: set DSO_STAGED_DIFF_FILE to a diff file path.
#
# Exit codes:
#   0 — no violations (or suppressed)
#   1 — one or more violations found

set -uo pipefail

_DIFF_FILE="${DSO_STAGED_DIFF_FILE:-}"
_tmp_diff=$(mktemp /tmp/check-precondition-emit-diff.XXXXXX)
trap 'rm -f "$_tmp_diff"' EXIT

if [[ -n "$_DIFF_FILE" ]]; then
    cp "$_DIFF_FILE" "$_tmp_diff"
else
    git diff --cached > "$_tmp_diff"
fi

python3 - "$_tmp_diff" <<'PYEOF'
import sys

# Matched by suffix so the hook works regardless of where the plugin is installed.
_TARGET_SUFFIXES = {
    "skills/brainstorm/SKILL.md",
    "skills/brainstorm/phases/approval-gate.md",
    "skills/sprint/SKILL.md",
    "skills/sprint/prompts/auto-resume.md",
    "skills/sprint/prompts/test-failure-dispatch-protocol.md",
    "skills/preplanning/SKILL.md",
    "skills/implementation-plan/SKILL.md",
    "skills/debug-everything/SKILL.md",
    "skills/fix-bug/SKILL.md",
    "skills/validate-work/SKILL.md",
    "skills/shared/workflows/epic-scrutiny-pipeline.md",
}


def _is_target(path):
    return any(path.endswith(s) for s in _TARGET_SUFFIXES)

TRIGGER_KEYWORDS = [
    'fall through',
    'safe fallback',
    'log a warning and continue',
    'continue without',
    'fall back',
    'graceful degradation',
]
WINDOW = 10


def has_trigger(line):
    lower = line.lower()
    return any(kw in lower for kw in TRIGGER_KEYWORDS)


def is_suppressed(line):
    return '# precondition-emit-ok' in line


def has_landmark(line):
    return '<!-- EMIT-PRECONDITIONS' in line


def check_hunk(hunk_lines, current_file):
    """Check a list of (pos, raw_diff_line) pairs from one hunk."""
    ec = 0
    for pos, line in hunk_lines:
        # Only check added lines ('+' prefix, not '+++' header)
        if not line.startswith('+') or line.startswith('+++'):
            continue
        content = line[1:]
        if not has_trigger(content):
            continue
        if is_suppressed(content):
            continue
        # Search within WINDOW lines in either direction
        found_landmark = False
        for other_pos, other_line in hunk_lines:
            if abs(other_pos - pos) <= WINDOW and has_landmark(other_line):
                found_landmark = True
                break
        if not found_landmark:
            print(
                f"ERROR: {current_file}: trigger keyword found without nearby "
                f"EMIT-PRECONDITIONS landmark (within {WINDOW} lines). "
                f"Add <!-- EMIT-PRECONDITIONS: ... --> within {WINDOW} lines, "
                f"or add # precondition-emit-ok to suppress.",
                file=sys.stderr,
            )
            ec = 1
    return ec


exit_code = 0
diff_text = open(sys.argv[1]).read()
lines = diff_text.split('\n')

current_file = None
in_target = False
hunk_lines = []  # list of (hunk_relative_pos, raw_diff_line)
hunk_pos = 0

for line in lines:
    if line.startswith('+++ b/'):
        # Flush previous hunk
        if hunk_lines and in_target and current_file:
            exit_code |= check_hunk(hunk_lines, current_file)
        current_file = line[6:]
        in_target = _is_target(current_file)
        hunk_lines = []
        hunk_pos = 0
    elif line.startswith('--- ') or line.startswith('diff --git'):
        pass
    elif line.startswith('@@'):
        # Flush previous hunk on new hunk header
        if hunk_lines and in_target and current_file:
            exit_code |= check_hunk(hunk_lines, current_file)
        hunk_lines = []
        hunk_pos = 0
    elif in_target and (line.startswith('+') or line.startswith(' ') or line.startswith('-')):
        if not line.startswith('-'):
            # Track added and context lines (checked for triggers and landmarks)
            hunk_lines.append((hunk_pos, line))
        # Advance counter for all lines including deletions so window distance
        # is measured over total diff lines, not just added/context lines.
        hunk_pos += 1

# Flush last hunk
if hunk_lines and in_target and current_file:
    exit_code |= check_hunk(hunk_lines, current_file)

sys.exit(exit_code)
PYEOF
exit $?
