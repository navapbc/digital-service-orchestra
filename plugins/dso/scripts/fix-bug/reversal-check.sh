#!/usr/bin/env bash
# reversal-check.sh
# Reversal Gate: Reversal Check
#
# Detects whether proposed working-tree changes (git diff) undo or reverse a
# recent committed change. Used by the /dso:fix-bug escalation router (Story
# a2f0-9641) as a post-investigation signal.
#
# Usage:
#   reversal-check.sh [--intent-aligned] <file> [<file> ...]
#
# Flags:
#   --intent-aligned   Suppresses reversal detection. When Intent Gate reported
#                      intent-aligned, a reversal is expected and intentional.
#                      Always emits triggered:false when present.
#
# Output: single JSON object on stdout conforming to gate-signal-schema.md
#   gate_id      = "reversal"
#   signal_type  = "primary"
#   triggered    = true | false
#   evidence     = human-readable explanation
#   confidence   = "high" | "medium" | "low"
#
# Exit codes:
#   0   success (stdout contains valid JSON)
#   1   internal error (missing dependencies, etc.)
#
# Reversal detection algorithm:
#   For each file, compare the lines added in the working-tree diff against
#   lines removed in recent commits (git log -20), and vice versa.
#   A reversal is detected when >50% of a recent commit's changed lines are
#   inverted by the proposed fix (added in WD ↔ removed in commit, or vice
#   versa). This threshold (50%) is intentionally conservative to reduce
#   false positives on minor text changes.
#
# Revert-of-revert recognition:
#   If the most-recent commit touching the file has a message matching the
#   pattern "Revert.*Revert" (case-insensitive), the inversion is treated as
#   an intentional re-application, not a problematic reversal. triggered=false
#   and evidence notes "revert-of-revert detected".
#
# Requires: bash, git, python3 (stdlib only)

set -uo pipefail

# ── JSON emitter ────────────────────────────────────────────────────────────────

# _emit_signal triggered evidence confidence
# Prints the gate signal JSON to stdout and exits 0.
_emit_signal() {
    local triggered="$1" evidence="$2" confidence="$3"
    python3 - "$triggered" "$evidence" "$confidence" <<'PYEOF'
import sys, json
triggered_str, evidence, confidence = sys.argv[1], sys.argv[2], sys.argv[3]
triggered = triggered_str.lower() == "true"
obj = {
    "gate_id": "reversal",
    "triggered": triggered,
    "signal_type": "primary",
    "evidence": evidence,
    "confidence": confidence,
}
print(json.dumps(obj))
PYEOF
    exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────────

INTENT_ALIGNED=false
FILES=()

for arg in "$@"; do
    if [[ "$arg" == "--intent-aligned" ]]; then
        INTENT_ALIGNED=true
    else
        FILES+=("$arg")
    fi
done

# ── Intent-aligned suppression ──────────────────────────────────────────────────

if [[ "$INTENT_ALIGNED" == "true" ]]; then
    _emit_signal "false" \
        "Reversal check suppressed: --intent-aligned flag passed (Intent Gate reported intent-aligned; reversal is expected and intentional)" \
        "high"
fi

# ── No files provided ───────────────────────────────────────────────────────────

if [[ "${#FILES[@]}" -eq 0 ]]; then
    _emit_signal "false" \
        "No files provided; nothing to check" \
        "high"
fi

# ── Git repo check ──────────────────────────────────────────────────────────────

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    _emit_signal "false" \
        "Not inside a git repository; reversal check cannot run" \
        "high"
fi

# ── Per-file reversal detection ─────────────────────────────────────────────────

# _get_working_tree_diff_lines file
# Returns lines from the working-tree diff for a single file (added and removed).
# Output format: "A:<line>" for added, "R:<line>" for removed.
_get_working_tree_diff_lines() {
    local file="$1"
    git diff -- "$file" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            +*)  # added in working tree (not the +++ header)
                [[ "$line" == "+++"* ]] && continue
                printf 'A:%s\n' "${line:1}"
                ;;
            -*)  # removed in working tree (not the --- header)
                [[ "$line" == "---"* ]] && continue
                printf 'R:%s\n' "${line:1}"
                ;;
        esac
    done
}

# _get_commit_diff_lines file commit_hash
# Returns lines from the diff introduced by a specific commit for a file.
# Output format: "A:<line>" for added, "R:<line>" for removed.
_get_commit_diff_lines() {
    local file="$1" commit="$2"
    git diff "${commit}^" "$commit" -- "$file" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            +*)
                [[ "$line" == "+++"* ]] && continue
                printf 'A:%s\n' "${line:1}"
                ;;
            -*)
                [[ "$line" == "---"* ]] && continue
                printf 'R:%s\n' "${line:1}"
                ;;
        esac
    done
}

# _count_inversions wd_lines commit_lines
# Counts how many lines in commit_lines are inverted by wd_lines.
# An inversion: a line added in commit appears as removed in WD (or vice versa).
# Reads wd_lines from $1 (newline-separated) and commit_lines from $2.
# Prints: "inversion_count total_commit_lines"
_count_inversions() {
    local wd_lines="$1" commit_lines="$2"
    python3 - "$wd_lines" "$commit_lines" <<'PYEOF'
import sys

wd_raw = sys.argv[1]
commit_raw = sys.argv[2]

# Parse working-tree diff lines: A:<content> / R:<content>
wd_added = set()
wd_removed = set()
for line in wd_raw.splitlines():
    if line.startswith("A:"):
        wd_added.add(line[2:])
    elif line.startswith("R:"):
        wd_removed.add(line[2:])

# Parse commit diff lines
commit_added = []
commit_removed = []
for line in commit_raw.splitlines():
    if line.startswith("A:"):
        commit_added.append(line[2:])
    elif line.startswith("R:"):
        commit_removed.append(line[2:])

total = len(commit_added) + len(commit_removed)
if total == 0:
    print("0 0")
    sys.exit(0)

inversions = 0
# Lines the commit added that the WD now removes → inversion
for l in commit_added:
    if l and l in wd_removed:
        inversions += 1
# Lines the commit removed that the WD now adds back → inversion
for l in commit_removed:
    if l and l in wd_added:
        inversions += 1

print(f"{inversions} {total}")
PYEOF
}

OVERALL_TRIGGERED=false
OVERALL_EVIDENCE=""
OVERALL_CONFIDENCE="high"

for file in "${FILES[@]}"; do
    # Get recent commits for this file (up to 20)
    mapfile -t COMMITS < <(git log --oneline -20 -- "$file" 2>/dev/null | awk '{print $1}')

    if [[ "${#COMMITS[@]}" -eq 0 ]]; then
        # No git history for this file — cannot determine reversal
        OVERALL_EVIDENCE="${OVERALL_EVIDENCE}${file}: no git history, skip; "
        continue
    fi

    # Get working-tree diff lines for this file
    WD_LINES="$(_get_working_tree_diff_lines "$file")"

    if [[ -z "$WD_LINES" ]]; then
        # No working-tree changes for this file
        OVERALL_EVIDENCE="${OVERALL_EVIDENCE}${file}: no working-tree diff, skip; "
        continue
    fi

    # Check each recent commit for a reversal
    FILE_REVERSED=false
    FILE_EVIDENCE=""

    for commit in "${COMMITS[@]}"; do
        # Get commit message
        COMMIT_MSG="$(git log -1 --format="%s" "$commit" 2>/dev/null)"

        # Get commit diff lines for this file
        COMMIT_LINES="$(_get_commit_diff_lines "$file" "$commit")"

        if [[ -z "$COMMIT_LINES" ]]; then
            continue
        fi

        # Count inversions
        read -r inversion_count total_lines <<< "$(_count_inversions "$WD_LINES" "$COMMIT_LINES")"

        if [[ "$total_lines" -eq 0 ]]; then
            continue
        fi

        # Check if >50% of commit lines are inverted by the proposed fix
        is_reversal=$(python3 -c "print('yes' if int('$inversion_count') > int('$total_lines') * 0.5 else 'no')" 2>/dev/null)

        if [[ "$is_reversal" == "yes" ]]; then
            # Check for revert-of-revert: the commit being reversed is itself a revert
            # commit (message starts with "Revert", case-insensitive — e.g. "Revert: ...",
            # "Revert 'foo'", "Revert \"Revert bar\""). Re-applying the original change
            # after a revert is intentional, not problematic. The stricter pattern
            # "Revert.*Revert" also matches compound revert messages like
            # "Revert 'Revert foo'", which are a subset of this broader check.
            if echo "$COMMIT_MSG" | grep -qiE "^Revert"; then
                FILE_EVIDENCE="revert-of-revert detected for ${file}: commit ${commit} ('${COMMIT_MSG}') is itself a revert; re-applying original change is intentional"
                OVERALL_CONFIDENCE="high"
                break
            fi

            FILE_REVERSED=true
            FILE_EVIDENCE="${file}: working-tree diff inverts ${inversion_count}/${total_lines} lines from commit ${commit} ('${COMMIT_MSG}')"
            OVERALL_CONFIDENCE="high"
            break
        fi
    done

    if [[ -n "$FILE_EVIDENCE" && "$FILE_EVIDENCE" == *"revert-of-revert"* ]]; then
        OVERALL_EVIDENCE="${OVERALL_EVIDENCE}${FILE_EVIDENCE}; "
        # revert-of-revert does not set triggered
        continue
    fi

    if [[ "$FILE_REVERSED" == "true" ]]; then
        OVERALL_TRIGGERED=true
        OVERALL_EVIDENCE="${OVERALL_EVIDENCE}${FILE_EVIDENCE}; "
    else
        if [[ -z "$FILE_EVIDENCE" ]]; then
            OVERALL_EVIDENCE="${OVERALL_EVIDENCE}${file}: no reversal detected in recent ${#COMMITS[@]} commits; "
        else
            OVERALL_EVIDENCE="${OVERALL_EVIDENCE}${file}: no reversal detected; "
        fi
    fi
done

# Clean up trailing separator
OVERALL_EVIDENCE="${OVERALL_EVIDENCE%; }"
if [[ -z "$OVERALL_EVIDENCE" ]]; then
    OVERALL_EVIDENCE="No reversal detected across ${#FILES[@]} file(s)"
fi

_emit_signal "$OVERALL_TRIGGERED" "$OVERALL_EVIDENCE" "$OVERALL_CONFIDENCE"
