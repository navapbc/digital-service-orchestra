#!/usr/bin/env bash
# lockpick-workflow/hooks/record-review.sh
# Utility: records that a code review passed for the current working tree state.
#
# Called after a successful /review run. Reads scores, findings, and summary
# directly from reviewer-findings.json (written by the code-reviewer sub-agent
# via write-reviewer-findings.sh). This ensures that only genuine sub-agent
# reviews can produce a valid review state — no orchestrator-constructed JSON
# is accepted.
#
# Usage:
#   record-review.sh --reviewer-hash HASH [--expected-hash HASH]
#
# Options:
#   --expected-hash HASH   If provided, the script computes the current diff hash
#                          and rejects if it differs from HASH. This prevents
#                          recording a review against a stale diff.
#   --reviewer-hash HASH   SHA256 hash of reviewer-findings.json as reported by
#                          the code-reviewer sub-agent. REQUIRED. Used to verify
#                          the file has not been tampered with after the sub-agent
#                          wrote it.
#
# reviewer-findings.json must contain (written by sub-agent):
#   - scores: object with code_hygiene, object_oriented_design, readability,
#             functionality, testing_coverage (each 1-5 or "N/A")
#   - summary: non-empty string (min 10 chars)
#   - findings: array of finding objects (may be empty)
#
# Writes review state to: /tmp/workflow-plugin-<hash>/review-status
# Format:
#   Line 1: "passed" or "failed"
#   Line 2: timestamp=<ISO8601>
#   Line 3: diff_hash=<sha256 of staged+unstaged diff>
#   Line 4: score=<min numeric score from review>
#   Line 5: review_hash=<sha256 of reviewer-findings.json>
#
# The diff_hash lets hooks detect whether code has changed since the review.
# The review_hash proves that structured review data was provided.

set -euo pipefail

# Source shared dependency library (provides get_artifacts_dir, hash_stdin, etc.)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# Pre-flight: python3 and shasum are required (integrity-critical hook).
# This hook hard-fails without shasum rather than cascading to weaker hashes,
# because the reviewer sub-agent also uses shasum -a 256. Both sides must use
# the same algorithm to avoid false-positive tamper alarms.
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 required for review recording (integrity-critical)" >&2
    exit 1
fi
if ! command -v shasum &>/dev/null; then
    echo "ERROR: shasum required for review recording (integrity-critical)" >&2
    exit 1
fi

# Parse arguments
EXPECTED_HASH=""
REVIEWER_HASH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expected-hash)
            EXPECTED_HASH="$2"
            shift 2
            ;;
        --reviewer-hash)
            REVIEWER_HASH="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "" >&2
            echo "Usage: record-review.sh --reviewer-hash HASH [--expected-hash HASH]" >&2
            echo "" >&2
            echo "This script reads directly from reviewer-findings.json (written by the" >&2
            echo "code-reviewer sub-agent). No stdin JSON is accepted." >&2
            exit 1
            ;;
    esac
done

# Drain stdin silently if anything was piped (backward compatibility — don't
# error on callers that still pipe, but don't use the input)
if [[ ! -t 0 ]]; then
    cat > /dev/null 2>&1 || true
fi

# Determine worktree name and artifacts directory
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    echo "ERROR: not in a git repository" >&2
    exit 1
fi

ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

# --- Locate and verify reviewer-findings.json (written by code-reviewer sub-agent) ---
FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"
if [[ ! -f "$FINDINGS_FILE" ]]; then
    echo "ERROR: reviewer-findings.json not found — review sub-agent must write this file" >&2
    echo "  Expected at: $FINDINGS_FILE" >&2
    echo "" >&2
    echo "The code-reviewer sub-agent writes this file via write-reviewer-findings.sh." >&2
    echo "Run /review to dispatch a sub-agent review." >&2
    exit 1
fi

# Verify --reviewer-hash is provided (mandatory)
if [[ -z "$REVIEWER_HASH" ]]; then
    echo "ERROR: --reviewer-hash is required — the code-reviewer sub-agent must report the hash" >&2
    echo "" >&2
    echo "Usage: record-review.sh --reviewer-hash HASH [--expected-hash HASH]" >&2
    exit 1
fi

# Verify file integrity via hash comparison
ACTUAL_HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
if [[ "$REVIEWER_HASH" != "$ACTUAL_HASH" ]]; then
    echo "ERROR: reviewer-findings.json hash mismatch — file was tampered with" >&2
    echo "  Expected: ${REVIEWER_HASH:0:12}..." >&2
    echo "  Actual:   ${ACTUAL_HASH:0:12}..." >&2
    exit 1
fi

# --- Validate and extract review data from reviewer-findings.json ---
# Read scores, summary, findings, and files from the sub-agent's findings file.
# Note: do NOT use || true here — we want to fail closed on Python errors.
# Instead, temporarily disable set -e for this block to capture exit code.
set +e
REVIEWER_SCORE=$(FINDINGS_PATH="$FINDINGS_FILE" python3 -c "
import sys, json, os

with open(os.environ['FINDINGS_PATH']) as f:
    data = json.load(f)

scores = data.get('scores', {})
required = ['code_hygiene', 'object_oriented_design', 'readability', 'functionality', 'testing_coverage']

# Normalize string digits to int so both '4' and 4 are accepted
for key in list(scores.keys()):
    val = scores[key]
    if isinstance(val, str) and val.isdigit():
        scores[key] = int(val)

for key in required:
    if key not in scores:
        print(f'ERROR: reviewer missing score dimension: {key}')
        print()
        print('Required schema for reviewer-findings.json:')
        print('{')
        print('  \"scores\": {')
        print('    \"code_hygiene\": <1-5 or \"N/A\">,')
        print('    \"object_oriented_design\": <1-5 or \"N/A\">,')
        print('    \"readability\": <1-5 or \"N/A\">,')
        print('    \"functionality\": <1-5 or \"N/A\">,')
        print('    \"testing_coverage\": <1-5 or \"N/A\">}')
        print('  },')
        print('  \"findings\": [{\"severity\": \"critical|important|minor\", \"category\": \"<one of 5 score dims>\", \"file\": \"path\", \"description\": \"...\"}],')
        print('  \"summary\": \"<10+ char assessment>\"')
        print('}')
        sys.exit(1)
    val = scores[key]
    if val != 'N/A':
        if not isinstance(val, (int, float)) or not (1 <= val <= 5):
            print(f'ERROR: reviewer score {key} must be 1-5 or N/A, got: {val}')
            sys.exit(1)

# Validate summary
summary = data.get('summary')
if not summary or not isinstance(summary, str) or len(summary.strip()) < 10:
    print('ERROR: missing or too short summary in reviewer-findings.json (min 10 chars)')
    sys.exit(1)

# Cross-validate findings against scores
valid_categories = set(required)
valid_severities = {'critical', 'important', 'minor'}
for finding in data.get('findings', []):
    severity = finding.get('severity', '')
    category = finding.get('category', '')
    if severity not in valid_severities:
        print(f'ERROR: finding has invalid severity: {severity} (must be one of {sorted(valid_severities)})')
        sys.exit(1)
    if category not in valid_categories:
        print(f'ERROR: finding has invalid category: {category} (must be one of {sorted(required)})')
        sys.exit(1)
    score = scores.get(category)
    if score == 'N/A' or not isinstance(score, (int, float)):
        continue
    if severity == 'critical' and score > 2:
        print(f'ERROR: {category}={score} but reviewer found critical issue — score must be 1-2')
        sys.exit(1)

numeric = [v for v in scores.values() if isinstance(v, (int, float))]
min_score = min(numeric) if numeric else 5
has_critical = any(f.get('severity') == 'critical' for f in data.get('findings', []))
critical_flag = 'yes' if has_critical else 'no'

# Extract files from findings for overlap check
files = set()
for finding in data.get('findings', []):
    f = finding.get('file', '')
    if f:
        files.add(f)

files_str = '\\n'.join(sorted(files)) if files else ''
print(f'OK:{min_score}:{critical_flag}:{files_str}')
" 2>&1)
REVIEWER_EXIT=$?
set -e

if [[ $REVIEWER_EXIT -ne 0 || "$REVIEWER_SCORE" == ERROR:* ]]; then
    echo "Reviewer findings validation failed: $REVIEWER_SCORE" >&2
    exit 1
fi

# Parse the OK response: OK:<score>:<critical_flag>:<files>
RESULT_BODY="${REVIEWER_SCORE#OK:}"
SCORE="${RESULT_BODY%%:*}"
REMAINDER="${RESULT_BODY#*:}"
HAS_CRITICAL="${REMAINDER%%:*}"
FILES_FROM_FINDINGS="${REMAINDER#*:}"

# --- Validate files overlap with actual changed files ---
CHANGED_FILES=$(
    {
        git diff --name-only HEAD -- ':!.checkpoint-needs-review' ':!.tickets/' ':!.sync-state.json' ':!app/tests/e2e/snapshots/*.png' ':!app/tests/unit/templates/snapshots/*.html' 2>/dev/null || true
        git diff --cached --name-only HEAD -- ':!.checkpoint-needs-review' ':!.tickets/' ':!.sync-state.json' ':!app/tests/e2e/snapshots/*.png' ':!app/tests/unit/templates/snapshots/*.html' 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null | { grep -v '^\.checkpoint-needs-review$' || true; } | { grep -v '^\.tickets/' || true; } | { grep -v '^\.sync-state\.json$' || true; } | { grep -v '^app/tests/e2e/snapshots/.*\.png$' || true; } | { grep -v '^app/tests/unit/templates/snapshots/.*\.html$' || true; }
    } | sort -u | { grep -v '^$' || true; }
)

if [[ -n "$CHANGED_FILES" ]] && [[ -n "$FILES_FROM_FINDINGS" ]]; then
    OVERLAP_FOUND=""
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        while IFS= read -r changed; do
            [[ -z "$changed" ]] && continue
            if [[ "$changed" == *"$target"* || "$target" == *"$changed"* ]]; then
                OVERLAP_FOUND="yes"
                break 2
            fi
        done <<< "$CHANGED_FILES"
    done <<< "$FILES_FROM_FINDINGS"

    if [[ -z "$OVERLAP_FOUND" ]]; then
        echo "ERROR: reviewer findings files do not overlap with any changed files in the diff" >&2
        echo "This suggests the review was not performed against the current changes." >&2
        exit 1
    fi
fi

REVIEW_STATE_FILE="$ARTIFACTS_DIR/review-status"

# Compute a hash of the current diff (staged + unstaged) to fingerprint the code state.
# Reuse untracked snapshot if available for deterministic hashing during review sessions.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SNAPSHOT_ARGS=()
if [[ -n "${ARTIFACTS_DIR:-}" && -f "$ARTIFACTS_DIR/untracked-snapshot.txt" ]]; then
    _SNAPSHOT_ARGS=(--snapshot "$ARTIFACTS_DIR/untracked-snapshot.txt")
fi
DIFF_HASH=$("$SCRIPT_DIR/compute-diff-hash.sh" "${_SNAPSHOT_ARGS[@]}")

# If --expected-hash was provided, reject if the diff has changed since the caller captured it
if [[ -n "$EXPECTED_HASH" && "$EXPECTED_HASH" != "$DIFF_HASH" ]]; then
    # Check if this is the pre-committed case (sub-agent PreCompact hook committed changes)
    # Use the same exclusion pathspecs as compute-diff-hash.sh to avoid false mismatches
    # when the diff includes images, snapshots, PDFs, or other non-reviewable file types.
    # Also hash untracked files that were part of the commit (shown as empty diff vs HEAD).
    LAST_COMMIT_DIFF_HASH=$(git diff HEAD~1 HEAD -- \
        ':!.tickets/' \
        ':!.sync-state.json' \
        ':!app/tests/e2e/snapshots/' \
        ':!app/tests/unit/templates/snapshots/*.html' \
        ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.gif' ':!*.svg' ':!*.ico' ':!*.webp' \
        ':!*.pdf' ':!*.docx' \
        2>/dev/null | shasum -a 256 | awk '{print $1}')
    if [[ "$EXPECTED_HASH" == "$LAST_COMMIT_DIFF_HASH" ]]; then
        echo "INFO: diff was pre-committed (sub-agent PreCompact hook) — accepting HEAD~1 diff hash match" >&2
        # Update DIFF_HASH to match what was reviewed so the review-status file is consistent
        DIFF_HASH="$EXPECTED_HASH"
    else
        echo "ERROR: diff hash mismatch — code changed between review dispatch and recording" >&2
        echo "  Expected: ${EXPECTED_HASH:0:12}..." >&2
        echo "  Current:  ${DIFF_HASH:0:12}..." >&2
        echo "" >&2
        echo "Do NOT re-record. Fix the issue and re-run /review from the start." >&2
        exit 1
    fi
fi

# Hash the reviewer-findings.json as proof of review
REVIEW_HASH="$ACTUAL_HASH"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine pass/fail: pass requires min score >= 4 AND no critical findings.
# Important findings may coexist with a passing score (reviewer uses judgment on 3-4 range).
# Critical findings always fail regardless of score.
STATUS="passed"
if [[ $(echo "$SCORE < 4" | bc -l 2>/dev/null || echo "1") == "1" ]] || [[ "$HAS_CRITICAL" == "yes" ]]; then
    STATUS="failed"
fi

# Preserve any existing checkpoint_cleared line across the overwrite below.
# On multi-session branches a review may run after the sentinel was already cleared;
# without this guard the checkpoint_cleared entry is silently lost.
_PREV_CHECKPOINT_CLEARED=""
if [[ -f "$REVIEW_STATE_FILE" ]]; then
    _PREV_CHECKPOINT_CLEARED=$(grep '^checkpoint_cleared=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 || true)
fi

# Write state file
cat > "$REVIEW_STATE_FILE" <<EOF
${STATUS}
timestamp=${TIMESTAMP}
diff_hash=${DIFF_HASH}
score=${SCORE}
review_hash=${REVIEW_HASH}
EOF

echo "Review status recorded: ${STATUS} (score=${SCORE}, diff_hash=${DIFF_HASH:0:12}...)"

# --- Detect and clear checkpoint review sentinel ---
# If pre-compact-checkpoint.sh wrote .checkpoint-needs-review, record that this
# review cleared it and remove the sentinel from the working tree so it is not
# committed. The recovery procedure (git reset --soft HEAD~1 + git rm --cached)
# leaves the file as untracked; record-review.sh handles the final removal here.
SENTINEL_FILE="$REPO_ROOT/.checkpoint-needs-review"
if [[ -f "$SENTINEL_FILE" ]]; then
    SENTINEL_NONCE=$(tr -d '[:space:]' < "$SENTINEL_FILE")
    if [[ -n "$SENTINEL_NONCE" ]]; then
        echo "checkpoint_cleared=${SENTINEL_NONCE}" >> "$REVIEW_STATE_FILE"
        # Remove the sentinel from the working tree (and index if it was staged).
        # Errors are suppressed — removal is best-effort; merge-to-main.sh verifies
        # the deletion commit exists in git history rather than relying on this.
        (cd "$REPO_ROOT" && git rm --force --cached ".checkpoint-needs-review" 2>/dev/null || true)
        rm -f "$SENTINEL_FILE" 2>/dev/null || true
        echo "INFO: Checkpoint sentinel cleared (nonce=${SENTINEL_NONCE:0:8}...)" >&2
    fi
elif [[ -n "$_PREV_CHECKPOINT_CLEARED" ]]; then
    # Sentinel already cleared by a previous review; re-append so subsequent reviews
    # don't lose the audit record.
    echo "$_PREV_CHECKPOINT_CLEARED" >> "$REVIEW_STATE_FILE"
fi
