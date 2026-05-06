#!/usr/bin/env bash
# hooks/record-review.sh
# Utility: records that a code review passed for the current working tree state.
#
# Called after a successful /dso:review run. Reads findings and summary
# directly from reviewer-findings.json (written by the code-reviewer sub-agent
# via write-reviewer-findings.sh). This ensures that only genuine sub-agent
# reviews can produce a valid review state — no orchestrator-constructed JSON
# is accepted.
#
# Derives STATUS (passed/failed) from findings[].severity:
#   critical/important/fragile = failed, minor/empty = passed
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
#   - summary: non-empty string (min 10 chars)
#   - findings: array of finding objects (may be empty)
#
# Writes review state to: /tmp/workflow-plugin-<hash>/review-status
# Format:
#   Line 1: "passed" or "failed"
#   Line 2: timestamp=<ISO8601>
#   Line 3: diff_hash=<sha256 of staged+unstaged diff>
#   Line 4: review_hash=<sha256 of reviewer-findings.json>
#
# The diff_hash lets hooks detect whether code has changed since the review.
# The review_hash proves that structured review data was provided.

set -euo pipefail

# Source shared dependency library (provides get_artifacts_dir, hash_stdin, etc.)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# Source config-driven path resolver (provides CFG_VISUAL_BASELINE_PATH, CFG_UNIT_SNAPSHOT_PATH, etc.)
source "$HOOK_DIR/lib/config-paths.sh"

# Source merge-state library for merge/rebase-aware overlap check (28c4-3fed).
source "$HOOK_DIR/lib/merge-state.sh"

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
FINDINGS_FILE_OVERRIDE=""
ATTEST_SOURCE_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expected-hash)
            EXPECTED_HASH="$2"
            shift 2
            ;;
        --expected-hash=*)
            EXPECTED_HASH="${1#*=}"
            shift
            ;;
        --reviewer-hash)
            REVIEWER_HASH="$2"
            shift 2
            ;;
        --reviewer-hash=*)
            REVIEWER_HASH="${1#*=}"
            shift
            ;;
        --findings-file)
            FINDINGS_FILE_OVERRIDE="$2"
            shift 2
            ;;
        --findings-file=*)
            FINDINGS_FILE_OVERRIDE="${1#*=}"
            shift
            ;;
        --attest)
            ATTEST_SOURCE_DIR="$2"
            shift 2
            ;;
        --attest=*)
            ATTEST_SOURCE_DIR="${1#*=}"
            shift
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "" >&2
            echo "Usage: record-review.sh --reviewer-hash HASH [--expected-hash HASH] [--findings-file PATH]" >&2
            echo "       record-review.sh --attest <worktree-artifacts-dir>" >&2
            echo "" >&2
            echo "This script reads directly from reviewer-findings.json (written by the" >&2
            echo "code-reviewer sub-agent). No stdin JSON is accepted." >&2
            echo "" >&2
            echo "  --findings-file PATH  Explicit path to reviewer-findings.json (use when the" >&2
            echo "                        reviewer wrote to a different ARTIFACTS_DIR, e.g., in a" >&2
            echo "                        sub-agent worktree with a different REPO_ROOT hash)." >&2
            echo "  --attest DIR          Attest a review from a worktree artifacts dir. Reads the" >&2
            echo "                        source review-status and transfers it to the session." >&2
            exit 1
            ;;
    esac
done

# Drain stdin silently if anything was piped (backward compatibility — don't
# error on callers that still pipe, but don't use the input).
# Use timeout to avoid hanging when called from non-interactive shells (e.g.,
# Claude Code background task runner) that have no tty but also no piped data.
if [[ ! -t 0 ]]; then
    timeout 1 cat > /dev/null 2>&1 || true
fi

# Determine worktree name and artifacts directory
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    echo "ERROR: not in a git repository" >&2
    exit 1
fi

ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

# --- Attest mode: transfer review from a worktree artifacts dir ---
# When --attest is provided, bypass the entire reviewer-findings.json pipeline.
# Instead, read the source review-status, verify it passed, and write a new
# review-status with the current diff hash and an attest_source field.
if [[ -n "$ATTEST_SOURCE_DIR" ]]; then
    SOURCE_STATUS_FILE="$ATTEST_SOURCE_DIR/review-status"
    if [[ ! -f "$SOURCE_STATUS_FILE" ]]; then
        echo "ERROR: source review-status not found at: $SOURCE_STATUS_FILE" >&2
        exit 1
    fi

    # Verify source status is "passed"
    SOURCE_STATUS=$(head -1 "$SOURCE_STATUS_FILE")
    if [[ "$SOURCE_STATUS" != "passed" ]]; then
        echo "ERROR: source review status is '$SOURCE_STATUS', expected 'passed'" >&2
        exit 1
    fi

    # Extract review_hash from source
    SOURCE_REVIEW_HASH=$(grep '^review_hash=' "$SOURCE_STATUS_FILE" | head -1 | cut -d= -f2)

    # Validate extracted fields are non-empty
    if [[ -z "$SOURCE_REVIEW_HASH" ]]; then
        echo "ERROR: source review-status missing review_hash= field" >&2
        exit 1
    fi

    # Compute the current session diff hash
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DIFF_HASH=$("$SCRIPT_DIR/compute-diff-hash.sh")

    # Extract worktree ID from basename of the artifacts dir path
    WORKTREE_ID=$(basename "$ATTEST_SOURCE_DIR")

    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    REVIEW_STATE_FILE="$ARTIFACTS_DIR/review-status"

    # Preserve any existing checkpoint_cleared line
    _PREV_CHECKPOINT_CLEARED=""
    if [[ -f "$REVIEW_STATE_FILE" ]]; then
        _PREV_CHECKPOINT_CLEARED=$(grep '^checkpoint_cleared=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 || true)
    fi

    # Write review-status with attest_source
    cat > "$REVIEW_STATE_FILE" <<EOF
passed
timestamp=${TIMESTAMP}
diff_hash=${DIFF_HASH}
review_hash=${SOURCE_REVIEW_HASH}
attest_source=${WORKTREE_ID}
EOF

    # Re-append checkpoint_cleared if it existed
    if [[ -n "$_PREV_CHECKPOINT_CLEARED" ]]; then
        echo "$_PREV_CHECKPOINT_CLEARED" >> "$REVIEW_STATE_FILE"
    fi

    echo "Review status attested from worktree ${WORKTREE_ID}: passed (diff_hash=${DIFF_HASH:0:12}...)"
    exit 0
fi

# --- Locate and verify reviewer-findings.json (written by code-reviewer sub-agent) ---
if [[ -n "$FINDINGS_FILE_OVERRIDE" ]]; then
    FINDINGS_FILE="$FINDINGS_FILE_OVERRIDE"
else
    FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"
    # Fallback: if not found in the primary artifacts dir, check $REPO_ROOT/.claude/artifacts/
    # This handles the case where the code-reviewer sub-agent resolved a different REPO_ROOT
    # (or WORKFLOW_PLUGIN_ARTIFACTS_DIR was not propagated), causing it to write
    # reviewer-findings.json to the relative .claude/artifacts/ path. (a74e-1671)
    if [[ ! -f "$FINDINGS_FILE" && -n "$REPO_ROOT" ]]; then
        _FALLBACK_FINDINGS="$REPO_ROOT/.claude/artifacts/reviewer-findings.json"
        if [[ -f "$_FALLBACK_FINDINGS" ]]; then
            echo "INFO: reviewer-findings.json not found in primary artifacts dir; using fallback: $_FALLBACK_FINDINGS"
            FINDINGS_FILE="$_FALLBACK_FINDINGS"
        fi
    fi
fi
if [[ ! -f "$FINDINGS_FILE" ]]; then
    echo "REVIEW BLOCKED: reviewer-findings.json not found — commit cannot proceed." >&2
    echo "  Expected at: $FINDINGS_FILE" >&2
    echo "" >&2
    echo "  This is an ERROR, not guidance. The pre-commit gate will block until this is resolved." >&2
    echo "  Recovery: run /dso:review to dispatch a code-reviewer sub-agent, which writes this file." >&2
    if [[ -z "$FINDINGS_FILE_OVERRIDE" ]]; then
        echo "  Hint: if the reviewer ran in a different worktree, pass --findings-file <path>." >&2
        echo "  Hint: also checked fallback: \$REPO_ROOT/.claude/artifacts/reviewer-findings.json" >&2
    fi
    exit 1
fi

# Prefer the sidecar hash file written by write-reviewer-findings.sh — robust
# against LLM output truncation that historically corrupted the stdout-transcribed
# REVIEWER_HASH (bug 8073-783f). Fall back to --reviewer-hash flag for callers
# that pre-date the sidecar (host projects on older plugin versions).
SIDECAR_HASH_FILE="${FINDINGS_FILE}.sha256"
if [[ -f "$SIDECAR_HASH_FILE" ]]; then
    REVIEWER_HASH=$(tr -d '[:space:]' < "$SIDECAR_HASH_FILE")
fi

# Verify --reviewer-hash is provided (mandatory; from sidecar or flag)
if [[ -z "$REVIEWER_HASH" ]]; then
    echo "ERROR: reviewer hash unavailable — neither sidecar (${SIDECAR_HASH_FILE}) nor --reviewer-hash flag was provided" >&2
    echo "" >&2
    echo "Usage: record-review.sh --reviewer-hash HASH [--expected-hash HASH]" >&2
    echo "" >&2
    echo "Where to get REVIEWER_HASH:" >&2
    echo "  The code-reviewer sub-agent (dso:code-reviewer-light, dso:code-reviewer-standard," >&2
    echo "  or dso:code-reviewer-deep-arch) writes reviewer-findings.json + .sha256 sidecar." >&2
    echo "  Newer plugin versions read the sidecar automatically; older callers can pass" >&2
    echo "  the hash via --reviewer-hash <hash>." >&2
    exit 1
fi

# Validate hash is a 64-char SHA-256 hex (catches LLM output truncation early
# with a clear message instead of the generic 'tampered with' error)
if ! [[ "$REVIEWER_HASH" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "ERROR: REVIEWER_HASH is not a valid 64-char SHA-256 hex value (got ${#REVIEWER_HASH} chars)" >&2
    echo "  This usually means the reviewer sub-agent's output was truncated when transcribing the hash." >&2
    echo "  Recovery: re-dispatch the code-reviewer sub-agent (it will re-write the sidecar)." >&2
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
# Read summary, findings, and files from the sub-agent's findings file.
# Derives STATUS from findings[].severity: critical/important/fragile = failed,
# minor or empty findings = passed.
# Note: do NOT use || true here — we want to fail closed on Python errors.
# Instead, temporarily disable set -e for this block to capture exit code.
set +e
REVIEWER_VALIDATION_OUTPUT=$(FINDINGS_PATH="$FINDINGS_FILE" python3 -c "
import sys, json, os, re

with open(os.environ['FINDINGS_PATH']) as f:
    data = json.load(f)

# Validate summary
summary = data.get('summary')
if not summary or not isinstance(summary, str) or len(summary.strip()) < 10:
    print('ERROR: missing or too short summary in reviewer-findings.json (min 10 chars)')
    sys.exit(1)

# Validate findings severity values
valid_severities = {'critical', 'important', 'minor', 'fragile'}
valid_categories = {'hygiene', 'design', 'maintainability', 'correctness', 'verification'}
findings = data.get('findings', [])
for finding in findings:
    severity = finding.get('severity', '')
    category = finding.get('category', '')
    if severity not in valid_severities:
        print(f'ERROR: finding has invalid severity: {severity} (must be one of {sorted(valid_severities)})')
        sys.exit(1)
    if category not in valid_categories:
        print(f'ERROR: finding has invalid category: {category} (must be one of {sorted(valid_categories)})')
        sys.exit(1)

# Determine STATUS from severity (text of descriptions must NOT affect STATUS)
blocking = {'critical', 'important', 'fragile'}
status = 'failed' if any(f.get('severity') in blocking for f in findings) else 'passed'
has_critical = any(f.get('severity') == 'critical' for f in findings)
critical_flag = 'yes' if has_critical else 'no'

# Extract files from findings for overlap check
files = set()
for finding in findings:
    fpath = finding.get('file', '')
    if fpath:
        files.add(fpath)

files_str = '\n'.join(sorted(files)) if files else ''
review_tier = data.get('review_tier', '')
# Sanitize review_tier: only lowercase letters allowed to prevent colon-delimiter corruption
review_tier = re.sub(r'[^a-z]', '', review_tier) if review_tier else ''
selected_tier = data.get('selected_tier', '')
selected_tier = re.sub(r'[^a-z]', '', selected_tier) if selected_tier else ''
# Emit selected_tier before files_str (files_str is the tail — everything after the last expected colon).
print(f'OK:{status}:{critical_flag}:{review_tier}:{selected_tier}:{files_str}')
" 2>&1)
REVIEWER_EXIT=$?
set -e

if [[ $REVIEWER_EXIT -ne 0 || "$REVIEWER_VALIDATION_OUTPUT" == ERROR:* ]]; then
    echo "Reviewer findings validation failed: $REVIEWER_VALIDATION_OUTPUT" >&2
    exit 1
fi

# Parse the OK response: OK:<status>:<critical_flag>:<review_tier>:<selected_tier>:<files>
RESULT_BODY="${REVIEWER_VALIDATION_OUTPUT#OK:}"
STATUS_FROM_FINDINGS="${RESULT_BODY%%:*}"  # "passed" or "failed"
REMAINDER="${RESULT_BODY#*:}"
HAS_CRITICAL="${REMAINDER%%:*}"
REMAINDER="${REMAINDER#*:}"
REVIEW_TIER="${REMAINDER%%:*}"
REMAINDER="${REMAINDER#*:}"
FINDINGS_SELECTED_TIER="${REMAINDER%%:*}"
FILES_FROM_FINDINGS="${REMAINDER#*:}"

# --- Validate files overlap with actual changed files ---
# Build pathspec exclusions from config
_RR_EXCLUDE=(':!.checkpoint-needs-review' ':!.sync-state.json' ':!.tickets-tracker/')
if [[ -n "$CFG_VISUAL_BASELINE_PATH" ]]; then
    _RR_EXCLUDE+=(":!${CFG_VISUAL_BASELINE_PATH}*.png")
fi
if [[ -n "$CFG_UNIT_SNAPSHOT_PATH" ]]; then
    _RR_EXCLUDE+=(":!${CFG_UNIT_SNAPSHOT_PATH}*.html")
fi

# Allow tests to inject changed files without writing to the repo.
# isolation-ok: test-only override for overlap check
if [[ -n "${RECORD_REVIEW_CHANGED_FILES:-}" ]]; then
    CHANGED_FILES="$RECORD_REVIEW_CHANGED_FILES"
elif ms_is_merge_in_progress 2>/dev/null || ms_is_rebase_in_progress 2>/dev/null; then
    # During merge/rebase, scope to worktree-only files — matching compute-diff-hash.sh.
    # Without this, git diff HEAD shows ALL merge changes (including the incoming branch),
    # causing false overlap failures for findings that reference only the worktree files. (28c4-3fed)
    CHANGED_FILES=$(ms_get_worktree_only_files 2>/dev/null | sort -u | { grep -v '^$' || true; })
else
    # Only include tracked file changes (staged + unstaged). Untracked files are
    # excluded because compute-diff-hash.sh excludes them — the overlap check
    # must match the scope of the reviewed diff. (Bug dso-lm92)
    CHANGED_FILES=$(
        {
            git diff --name-only HEAD -- "${_RR_EXCLUDE[@]}" 2>/dev/null || true
            git diff --cached --name-only HEAD -- "${_RR_EXCLUDE[@]}" 2>/dev/null || true
        } | sort -u | { grep -v '^$' || true; }
    )
fi

# Fix ff09-69a2: build a separate OVERLAP_CHECK_FILES variable that includes ALL staged
# files for the overlap check (not just worktree-only files).  CHANGED_FILES keeps its
# worktree-only scope for diff-hash alignment; the overlap check needs the full staged set
# so that valid findings against incoming-branch files are not incorrectly rejected.
if [[ -n "${RECORD_REVIEW_CHANGED_FILES:-}" ]]; then
    # Test-injected override — use it for both CHANGED_FILES and OVERLAP_CHECK_FILES.
    OVERLAP_CHECK_FILES="$RECORD_REVIEW_CHANGED_FILES"
elif ms_is_merge_in_progress 2>/dev/null || ms_is_rebase_in_progress 2>/dev/null; then
    # During merge/rebase, the overlap check must accept findings against incoming-branch
    # files that are in the index (staged) even though they are not in CHANGED_FILES.
    OVERLAP_CHECK_FILES=$(git diff --cached --name-only 2>/dev/null | sort -u | { grep -v '^$' || true; })
    # Fall back to CHANGED_FILES if cached diff is empty (e.g., pre-staged merge)
    if [[ -z "$OVERLAP_CHECK_FILES" ]]; then
        OVERLAP_CHECK_FILES="$CHANGED_FILES"
    fi
else
    OVERLAP_CHECK_FILES="$CHANGED_FILES"
fi

# Fix c751-600d: per-finding strip — remove findings whose file is not in OVERLAP_CHECK_FILES.
# Set-level overlap (any match lets all findings through) allowed hallucinated out-of-diff
# findings to spuriously set has_critical.  After stripping, STATUS_FROM_FINDINGS and
# HAS_CRITICAL are re-derived so the recorded state reflects only legitimate in-diff findings.
# Skip when --findings-file override is set (cross-worktree findings are already trusted)
# and when OVERLAP_CHECK_FILES is empty (no scope to filter against).
if [[ -z "$FINDINGS_FILE_OVERRIDE" ]] && [[ -n "$OVERLAP_CHECK_FILES" ]] && [[ -s "$FINDINGS_FILE" ]]; then
    set +e
    _FILTERED_FINDINGS=$(python3 -c "
import json, os, sys

findings_file = sys.argv[1]
changed_str = sys.argv[2]

def _normalize(p):
    # Normalize for cross-format comparison. Strip leading './', collapse
    # redundant separators, normalize separators to '/' (handles git output on
    # Windows runners), and lowercase only on case-insensitive filesystems we
    # do not currently support — keep case intact for portability.
    if not p:
        return ''
    p = p.strip()
    p = p.replace('\\\\', '/')
    p = os.path.normpath(p)
    if p.startswith('./'):
        p = p[2:]
    return p

changed = set(_normalize(f) for f in changed_str.split('\n') if f.strip())

with open(findings_file) as fh:
    data = json.load(fh)

findings = data.get('findings', [])

# Partition into in-diff and out-of-diff findings.
# A finding is in-diff if its file field matches (substring) any changed file
# after path normalization (handles './' prefixes, redundant separators, and
# Windows-style backslashes that may appear in cross-platform diffs).
in_diff = []
stripped = []
for f in findings:
    fpath_raw = f.get('file', '')
    if not fpath_raw:
        in_diff.append(f)  # no file field — keep (global findings)
        continue
    fpath = _normalize(fpath_raw)
    matched = any(c and (c in fpath or fpath in c) for c in changed)
    if matched:
        in_diff.append(f)
    else:
        stripped.append(f)

if not stripped:
    # Nothing to strip — emit sentinel so the shell skips the rewrite
    print('NO_STRIP')
    sys.exit(0)

data['findings'] = in_diff
print(json.dumps(data))
" "$FINDINGS_FILE" "$OVERLAP_CHECK_FILES" 2>/dev/null)
    _FILTER_EXIT=$?
    set -e

    if [[ $_FILTER_EXIT -eq 0 && -n "$_FILTERED_FINDINGS" && "$_FILTERED_FINDINGS" != "NO_STRIP" ]]; then
        echo "$_FILTERED_FINDINGS" > "$FINDINGS_FILE"

        # Re-derive STATUS_FROM_FINDINGS and HAS_CRITICAL from the filtered findings file
        # so the rest of the script operates on the cleaned data.
        set +e
        _REPARSED=$(python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
findings = data.get('findings', [])
blocking = {'critical', 'important', 'fragile'}
status = 'failed' if any(f.get('severity') in blocking for f in findings) else 'passed'
has_critical = any(f.get('severity') == 'critical' for f in findings)
print(status + ':' + ('yes' if has_critical else 'no'))
" "$FINDINGS_FILE" 2>/dev/null)
        _REPARSE_EXIT=$?
        set -e
        if [[ $_REPARSE_EXIT -eq 0 && -n "$_REPARSED" ]]; then
            STATUS_FROM_FINDINGS="${_REPARSED%%:*}"
            HAS_CRITICAL="${_REPARSED#*:}"
        fi

        # Re-extract FILES_FROM_FINDINGS from the filtered file so the overlap check
        # uses the post-strip file list.  When all findings were stripped (all hallucinated),
        # FILES_FROM_FINDINGS becomes empty and the overlap check is correctly skipped. (c751-600d)
        set +e
        _FILES_AFTER_STRIP=$(python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
files = sorted(set(f.get('file','') for f in data.get('findings',[]) if f.get('file','')))
print('\n'.join(files))
" "$FINDINGS_FILE" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            FILES_FROM_FINDINGS="$_FILES_AFTER_STRIP"
        fi
        set -e
    fi
fi

# Skip overlap check when --findings-file was used from a different artifacts dir (cross-worktree
# scenario). The caller explicitly declared the findings came from a different context, so the
# current working tree's changed files may not match the reviewed diff. (6361-9c5b)
if [[ -n "$FINDINGS_FILE_OVERRIDE" ]]; then
    : # overlap check skipped — cross-worktree findings
elif [[ -n "$OVERLAP_CHECK_FILES" ]] && [[ -n "$FILES_FROM_FINDINGS" ]]; then
    # Normalize both sides before comparison: strip leading './', collapse
    # redundant separators (e.g. 'a//b'), and convert backslashes. Without this,
    # 'foo/bar.py' (in OVERLAP_CHECK_FILES) and './foo/bar.py' (from a finding)
    # would fail to overlap. Reviewer-reported defect: filter previously matched
    # against the `file` field with no normalization.
    OVERLAP_FOUND=""
    _normalize_path() {
        local _p="${1#./}"
        _p="${_p//\\//}"
        # Collapse runs of slashes
        while [[ "$_p" == *//* ]]; do _p="${_p//\/\//\/}"; done
        printf '%s' "$_p"
    }
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        target=$(_normalize_path "$target")
        while IFS= read -r changed; do
            [[ -z "$changed" ]] && continue
            changed=$(_normalize_path "$changed")
            if [[ "$changed" == *"$target"* || "$target" == *"$changed"* ]]; then
                OVERLAP_FOUND="yes"
                break 2
            fi
        done <<< "$OVERLAP_CHECK_FILES"
    done <<< "$FILES_FROM_FINDINGS"

    if [[ -z "$OVERLAP_FOUND" ]]; then
        echo "ERROR: reviewer findings files do not overlap with any changed files in the diff" >&2
        echo "This suggests the review was not performed against the current changes." >&2
        exit 1
    fi
fi

REVIEW_STATE_FILE="$ARTIFACTS_DIR/review-status"

# Compute a hash of the current diff (staged + unstaged) to fingerprint the code state.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF_HASH=$("$SCRIPT_DIR/compute-diff-hash.sh")

# If --expected-hash was provided, reject if the diff has changed since the caller captured it
if [[ -n "$EXPECTED_HASH" && "$EXPECTED_HASH" != "$DIFF_HASH" ]]; then
    # Check if this is the pre-committed case (sub-agent PreCompact hook committed changes)
    # Use the same exclusion pathspecs as compute-diff-hash.sh to avoid false mismatches
    # when the diff includes images, snapshots, PDFs, or other non-reviewable file types.
    # Also hash untracked files that were part of the commit (shown as empty diff vs HEAD).
    # Build exclusion pathspecs from config
    _LC_EXCLUDE=(':!.sync-state.json'
        ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.gif' ':!*.svg' ':!*.ico' ':!*.webp'
        ':!*.pdf' ':!*.docx')
    if [[ -n "$CFG_VISUAL_BASELINE_PATH" ]]; then
        _LC_EXCLUDE+=(":!${CFG_VISUAL_BASELINE_PATH}")
    fi
    if [[ -n "$CFG_UNIT_SNAPSHOT_PATH" ]]; then
        _LC_EXCLUDE+=(":!${CFG_UNIT_SNAPSHOT_PATH}*.html")
    fi
    LAST_COMMIT_DIFF_HASH=$(git diff HEAD~1 HEAD -- \
        "${_LC_EXCLUDE[@]}" \
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
        echo "Do NOT re-record. Fix the issue and re-run /dso:review from the start." >&2

        # Write diagnostic dump (same format as hook_review_gate in pre-bash-functions.sh)
        _DIAG_FILE="$ARTIFACTS_DIR/mismatch-diagnostics-$(date -u +%Y%m%dT%H%M%SZ).log"
        _DIAG_BREADCRUMB="NOT FOUND"
        if [[ -f "$ARTIFACTS_DIR/commit-breadcrumbs.log" ]]; then
            _DIAG_BREADCRUMB=$(cat "$ARTIFACTS_DIR/commit-breadcrumbs.log" 2>/dev/null || echo "READ ERROR")
        fi
        {
            printf 'source=record-review.sh\n'
            printf 'expected_hash=%s\n' "$EXPECTED_HASH"
            printf 'current_hash=%s\n' "$DIFF_HASH"
            printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'git_status=%s\n' "$(git status --short 2>/dev/null | tr '\n' ',' || echo "ERROR")"
            printf 'git_diff_names=%s\n' "$(git diff --name-only 2>/dev/null | tr '\n' ',' || echo "ERROR")"
            printf 'staged_diff_names=%s\n' "$(git diff --cached --name-only 2>/dev/null | tr '\n' ',' || echo "ERROR")"
            printf 'untracked_files=%s\n' "$(git ls-files --others --exclude-standard 2>/dev/null | head -20 | tr '\n' ',' || echo "ERROR")"
            printf 'untracked_count=%s\n' "$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
            printf 'breadcrumb_log=%s\n' "$(echo "$_DIAG_BREADCRUMB" | tr '\n' ',')"
        } > "$_DIAG_FILE" 2>/dev/null || true
        echo "  Diagnostics written to: $_DIAG_FILE" >&2

        exit 1
    fi
fi

# Hash the reviewer-findings.json as proof of review
REVIEW_HASH="$ACTUAL_HASH"

# --- Tier enforcement: verify review tier matches or exceeds classified tier ---
# Verification sources (bug 21d7-b84a):
#   1. findings.selected_tier — hash-integrity-covered, always co-located with
#      findings, but agent-self-reported (a compromised reviewer could self-
#      declare a lower tier).
#   2. classifier-telemetry.jsonl — written by the classifier (not the reviewer)
#      so trust-authoritative, but under worktree dispatch may live in a
#      different artifacts dir (closed by WORKFLOW_PLUGIN_ARTIFACTS_DIR export
#      in single-agent-integrate.md and per-worktree-review-commit.md).
#
# Precedence: when both are present, use max(rank) so an agent cannot
# self-declare a lower selected_tier to escape a higher classified tier.
# When only one is present, use it. When neither, fail-open.
#
# Tier rank: light=1, standard=2, deep=3
_tier_rank() {
    case "$1" in
        light)    echo 1 ;;
        standard) echo 2 ;;
        deep)     echo 3 ;;
        *)        echo 0 ;;
    esac
}

TIER_VERIFIED="true"
TELEMETRY_FILE="$ARTIFACTS_DIR/classifier-telemetry.jsonl"
TELEMETRY_SELECTED_TIER=""
if [[ -f "$TELEMETRY_FILE" ]]; then
    # Filter telemetry by current $DIFF_HASH before extracting selected_tier.
    # classifier-telemetry.jsonl is append-only across runs in the same artifacts
    # dir; reading bare `tail -1` would return a stale record from a prior review
    # on a different diff and could spuriously trigger TIER IMMUTABILITY VIOLATION
    # at lines 685-690 when the prior record's tier outranks the current run's.
    # Falls back to bare tail -1 only when the diff_hash field is absent (legacy
    # records emitted before review-complexity-classifier.sh embedded diff_hash).
    TELEMETRY_SELECTED_TIER=$(python3 -c "
import sys, json
records = [json.loads(l) for l in sys.stdin if l.strip()]
matches = [r for r in records if r.get('diff_hash') == '$DIFF_HASH']
if matches:
    print(matches[-1].get('selected_tier', ''))
elif records and not any('diff_hash' in r for r in records):
    print(records[-1].get('selected_tier', ''))
" < "$TELEMETRY_FILE" 2>/dev/null || echo "")
fi

SELECTED_TIER=""
SELECTED_TIER_SOURCE=""

if [[ -n "${FINDINGS_SELECTED_TIER:-}" && -n "$TELEMETRY_SELECTED_TIER" ]]; then
    # Both present — use max(rank) so the agent cannot self-downgrade.
    F_RANK=$(_tier_rank "$FINDINGS_SELECTED_TIER")
    T_RANK=$(_tier_rank "$TELEMETRY_SELECTED_TIER")
    if [[ "$F_RANK" -ge "$T_RANK" ]]; then
        SELECTED_TIER="$FINDINGS_SELECTED_TIER"
        SELECTED_TIER_SOURCE="findings"
    else
        SELECTED_TIER="$TELEMETRY_SELECTED_TIER"
        SELECTED_TIER_SOURCE="telemetry(max)"
    fi
elif [[ -n "${FINDINGS_SELECTED_TIER:-}" ]]; then
    SELECTED_TIER="$FINDINGS_SELECTED_TIER"
    SELECTED_TIER_SOURCE="findings"
elif [[ -n "$TELEMETRY_SELECTED_TIER" ]]; then
    SELECTED_TIER="$TELEMETRY_SELECTED_TIER"
    SELECTED_TIER_SOURCE="telemetry"
fi

if [[ -z "$SELECTED_TIER" ]]; then
    echo "WARNING: selected_tier not found in reviewer-findings.json or classifier-telemetry.jsonl — cannot verify tier; allowing review (fail-open)" >&2
    TIER_VERIFIED="false"
elif [[ -z "${REVIEW_TIER// /}" ]]; then
    echo "WARNING: review_tier missing or empty in reviewer-findings.json — cannot verify tier; allowing review (fail-open)" >&2
    TIER_VERIFIED="false"
else
    REVIEW_RANK=$(_tier_rank "$REVIEW_TIER")
    SELECTED_RANK=$(_tier_rank "$SELECTED_TIER")
    if [[ "$REVIEW_RANK" -lt "$SELECTED_RANK" ]]; then
        echo "TIER IMMUTABILITY VIOLATION: review tier '${REVIEW_TIER}' is a downgrade from classified tier '${SELECTED_TIER}' (source: ${SELECTED_TIER_SOURCE}). Re-run /dso:review." >&2
        exit 1
    fi
fi

# --- Overlay enforcement: every overlay flagged true in classifier telemetry
# (for the CURRENT diff hash) must have a corresponding reviewer-findings-<dim>.json
# file alongside the canonical findings. This guards against the orchestrator
# skipping Step 4 overlay dispatch — without this gate, a tier review records
# successfully even when an overlay (test_quality, security, performance) was
# flagged but never dispatched, silently allowing unreviewed code through.
#
# Telemetry filtering: classifier-telemetry.jsonl is append-only across runs in
# the same artifacts dir, so reading `tail -1` would consume stale records from
# prior reviews. read-overlay-flags.sh filters JSONL by --diff-hash before
# extracting flags, ensuring we only enforce against the current diff's record.
# The same script is used by REVIEW-WORKFLOW.md Step 4 (in classifier mode) so
# the dispatch decision and the post-commit gate cannot disagree on overlay state.
if [[ -f "$TELEMETRY_FILE" ]]; then
    # HOOK_DIR is set at script init (line 43). Plugin root is its parent.
    _READ_OVERLAY_SCRIPT="$(dirname "$HOOK_DIR")/scripts/read-overlay-flags.sh"
    if [[ ! -x "$_READ_OVERLAY_SCRIPT" ]]; then
        # Fail-closed: if telemetry exists but the helper does not, the gate
        # cannot enforce. Allowing the commit through would silently disable
        # overlay coverage — the exact failure mode this gate was added to
        # prevent. Surface the misconfiguration to the user instead.
        echo "OVERLAY_GATE_UNAVAILABLE: read-overlay-flags.sh not found at $_READ_OVERLAY_SCRIPT — overlay enforcement cannot run. Sync the plugin and re-run the commit workflow." >&2  # shim-exempt: error message text
        exit 1
    fi
    _OVERLAY_FLAGS=$(bash "$_READ_OVERLAY_SCRIPT" --mode telemetry --diff-hash "$DIFF_HASH" < "$TELEMETRY_FILE" 2>/dev/null || true)
    _OVERLAY_MISSING=()
    while IFS= read -r _dim; do
        [[ -z "$_dim" ]] && continue
        if [[ ! -f "$ARTIFACTS_DIR/reviewer-findings-${_dim}.json" ]]; then
            _OVERLAY_MISSING+=("$_dim")
        fi
    done <<< "$_OVERLAY_FLAGS"
    if (( ${#_OVERLAY_MISSING[@]} > 0 )); then
        echo "OVERLAY_MISSING: classifier flagged overlay(s) [${_OVERLAY_MISSING[*]}] for diff_hash $DIFF_HASH but no reviewer-findings-<dim>.json file recorded for them. Overlay dispatch was skipped. Re-run /dso:review and ensure every flagged overlay agent is dispatched in parallel with the tier reviewer (REVIEW-WORKFLOW.md Step 4)." >&2
        exit 1
    fi
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine pass/fail from severity-based STATUS already computed by Python validator.
STATUS="$STATUS_FROM_FINDINGS"  # already determined by severity in Python

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
review_hash=${REVIEW_HASH}
EOF

# Append tier_verified if fail-open occurred
if [[ "$TIER_VERIFIED" == "false" ]]; then
    echo "tier_verified=false" >> "$REVIEW_STATE_FILE"
fi

echo "Review status recorded: ${STATUS} (diff_hash=${DIFF_HASH:0:12}...)" >&2

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
