#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# run-overlay-retrospective.sh
# Runs the complexity classifier over the last N merged commits and generates
# calibration baselines for security_overlay and performance_overlay trigger rates.
#
# Usage:
#   run-overlay-retrospective.sh [--limit N] [--output PATH] [--dry-run] [--help]
#
# This script does NOT run overlay review agents — it only runs the classifier
# to measure trigger rates. Intended as a one-time calibration tool.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# ── Defaults ──────────────────────────────────────────────────────────────────
LIMIT=20
OUTPUT="${REPO_ROOT}/docs/findings/overlay-calibration-baselines.md"
DRY_RUN=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit)
            if [[ -z "${2:-}" || ! "${2}" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --limit requires a positive integer" >&2
                exit 1
            fi
            LIMIT="$2"
            shift 2
            ;;
        --limit=*)
            LIMIT="${1#--limit=}"
            if [[ ! "$LIMIT" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --limit requires a positive integer" >&2
                exit 1
            fi
            shift
            ;;
        --output)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --output requires a path argument" >&2
                exit 1
            fi
            OUTPUT="$2"
            shift 2
            ;;
        --output=*)
            OUTPUT="${1#--output=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            cat <<'EOF'
Usage: run-overlay-retrospective.sh [OPTIONS]

Runs the complexity classifier over recent commits to measure security and
performance overlay trigger rates. Writes a calibration baselines report.

Options:
  --limit N       Number of recent commits to analyze (default: 20)
  --output PATH   Path to write the markdown report
                  (default: docs/findings/overlay-calibration-baselines.md)
  --dry-run       Print commits that would be analyzed without running classifier
  --help, -h      Show this help message

The script reads git history, generates each commit's diff, and passes it
through the complexity classifier. It does NOT invoke overlay review agents.

Output: A markdown calibration baselines report with trigger rates, file
path patterns, and summary statistics.
EOF
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# ── Locate classifier ─────────────────────────────────────────────────────────
CLASSIFIER=""
if [[ -x "$SCRIPT_DIR/review-complexity-classifier.sh" ]]; then
    CLASSIFIER="$SCRIPT_DIR/review-complexity-classifier.sh"
elif [[ -n "$REPO_ROOT" && -x "${_PLUGIN_ROOT}/scripts/review-complexity-classifier.sh" ]]; then
    CLASSIFIER="${_PLUGIN_ROOT}/scripts/review-complexity-classifier.sh"
else
    echo "ERROR: review-complexity-classifier.sh not found" >&2
    exit 1
fi

# ── Collect commits ───────────────────────────────────────────────────────────
# git log %H gives full SHAs; %h abbreviated; %s subject line
mapfile -t COMMITS < <(git log --format="%H %h %s" -n "$LIMIT" 2>/dev/null)

if [[ ${#COMMITS[@]} -eq 0 ]]; then
    echo "ERROR: no commits found in git history" >&2
    exit 1
fi

echo "Analyzing ${#COMMITS[@]} commits for overlay trigger rates..."

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "DRY RUN — commits that would be analyzed:"
    echo ""
    local_count=0
    for entry in "${COMMITS[@]}"; do
        sha="${entry%% *}"
        rest="${entry#* }"
        abbrev="${rest%% *}"
        subject="${rest#* }"
        echo "  $abbrev  $subject"
        local_count=$(( local_count + 1 ))
    done
    echo ""
    echo "Total: $local_count commits"
    echo "Classifier: $CLASSIFIER"
    echo "Output would be written to: $OUTPUT"
    exit 0
fi

# ── Pattern definitions for findings analysis ────────────────────────────────
# Security criteria patterns (matched against added lines in diff)
SECURITY_PATTERNS=(
    'auth.guard|authorize|authorization|@requires_auth|@login_required|@permission_required'
    'sql.*[+%]|exec\(|system\(|popen\(|subprocess\.|shell=True|os\.path\.join.*input|eval\('
    'except:$|except\s*:|catch.*pass|except.*pass|catch.*\{\}|rescue\s*$'
    'state.*transition|set_state|change_state|fsm|state_machine|\.state\s*='
    'privilege|escalat|setuid|sudo|root_required|is_admin|is_superuser|role.*admin'
    'crypto|encrypt|decrypt|cipher|hmac|hash\.|hashlib|digest|signing|verify_signature'
    'check.*then.*use|toctou|race.*condition|time.*of.*check|file.*exist.*open'
    'trust.*boundary|untrusted|sanitize|validate.*input|escape.*html|csrf|xss|cors'
)
SECURITY_PATTERN_NAMES=(
    "authorization/auth guard"
    "untrusted input to dangerous sink"
    "fail-open error handling"
    "state machine transitions"
    "privilege escalation"
    "crypto/encryption operations"
    "TOCTOU (check-then-use)"
    "trust boundary crossing"
)

# Performance criteria patterns (matched against added lines in diff)
PERFORMANCE_PATTERNS=(
    'SELECT|INSERT|UPDATE|DELETE.*for |for .*SELECT|for .*INSERT|while .*SELECT|while .*query'
    'read\(.*read\(|write\(.*write\(|open\(.*open\(|sequential.*io|sync.*read|sync.*write'
    'append\(|\.extend\(|\.add\(|accumulate|\+=.*list|\.push\('
    'SELECT \*|select \*|\.all\(\)|fetch_all|find\(\s*\{\}\s*\)'
    'sleep|wait|time\.sleep.*async|await.*sleep|blocking.*async|sync.*in.*async'
    'cache|Cache|@cached|lru_cache|memoize'
    'list\(|tuple\(|\[\*|list\(.*generator|list\(.*map|list\(.*filter'
    'create.*connection|connect\(|Connection\(|new.*connection|open.*connection'
)
PERFORMANCE_PATTERN_NAMES=(
    "SQL inside loop"
    "sequential I/O"
    "unbounded accumulation"
    "over-fetching (SELECT *)"
    "blocking in async"
    "cache without TTL"
    "materializing generators"
    "connection without pool"
)

# Bright-line severity: patterns involving loops or unbounded → important; others → minor
# Indices 0 (SQL in loop), 2 (unbounded accumulation), 4 (blocking in async) → important
# Others → minor
PERF_IMPORTANT_INDICES="0 2 4"

# ── Per-commit analysis ───────────────────────────────────────────────────────
# Accumulate results into parallel arrays
declare -a RESULT_SHA=()
declare -a RESULT_ABBREV=()
declare -a RESULT_SUBJECT=()
declare -a RESULT_FILES=()
declare -a RESULT_SECURITY=()
declare -a RESULT_PERFORMANCE=()
declare -a RESULT_TIER=()
declare -a RESULT_SEC_FINDINGS=()
declare -a RESULT_PERF_FINDINGS=()
declare -a RESULT_SEC_TEST_FINDINGS=()
declare -a RESULT_PERF_IMPORTANT=()
declare -a RESULT_PERF_MINOR=()

# Counters
TOTAL_ANALYZED=0
SECURITY_TRIGGERED=0
PERFORMANCE_TRIGGERED=0
BOTH_TRIGGERED=0

# Findings counters
TOTAL_SEC_FINDINGS=0
TOTAL_PERF_FINDINGS=0
TOTAL_SEC_TEST_FINDINGS=0
TOTAL_PERF_IMPORTANT=0
TOTAL_PERF_MINOR=0

# File-pattern accumulators (newline-separated path lists)
SECURITY_FILES_ALL=""
PERFORMANCE_FILES_ALL=""

for entry in "${COMMITS[@]}"; do
    sha="${entry%% *}"
    rest="${entry#* }"
    abbrev="${rest%% *}"
    subject="${rest#* }"

    # Determine parent — first-parent only to keep things simple for merge commits
    parent=$(git log --pretty=%P -n 1 "$sha" 2>/dev/null | awk '{print $1}')

    if [[ -z "$parent" ]]; then
        # Root commit — diff against empty tree
        parent=$(git hash-object -t tree /dev/null 2>/dev/null || echo "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    fi

    # Generate diff
    diff_content=$(git diff "${parent}..${sha}" 2>/dev/null || true)

    # Run classifier
    classifier_out=$(printf '%s' "$diff_content" | REPO_ROOT="${REPO_ROOT}" "$CLASSIFIER" 2>/dev/null || echo '{}')

    # Extract overlay dimensions via shared helper (single source-of-truth for
    # overlay schema — same script REVIEW-WORKFLOW.md Step 4 and record-review.sh
    # use). Then map dim membership to per-flag boolean strings the retrospective
    # tabulation expects.
    _retro_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/read-overlay-flags.sh"
    overlay_dims=""
    if [[ -x "$_retro_helper" ]]; then
        overlay_dims=$(printf '%s' "$classifier_out" | bash "$_retro_helper" --mode classifier 2>/dev/null || true)
    fi
    security_overlay=$(echo "$overlay_dims" | grep -qx security && echo true || echo false)
    performance_overlay=$(echo "$overlay_dims" | grep -qx performance && echo true || echo false)
    # selected_tier is not part of the overlay schema; retrospective still reads it directly.
    selected_tier=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('selected_tier','unknown'))" <<< "$classifier_out" 2>/dev/null || echo "unknown")

    # Extract changed files from diff
    changed_files=$(printf '%s\n' "$diff_content" | grep -E '^diff --git a/' | sed 's|^diff --git a/.* b/||' | tr '\n' ' ' | sed 's/ $//')

    RESULT_SHA+=("$sha")
    RESULT_ABBREV+=("$abbrev")
    RESULT_SUBJECT+=("$subject")
    RESULT_FILES+=("$changed_files")
    RESULT_SECURITY+=("$security_overlay")
    RESULT_PERFORMANCE+=("$performance_overlay")
    RESULT_TIER+=("$selected_tier")

    TOTAL_ANALYZED=$(( TOTAL_ANALYZED + 1 ))

    # Extract added lines from diff for pattern matching
    added_lines=$(printf '%s\n' "$diff_content" | grep -E '^\+[^+]' | sed 's/^\+//' || true)

    # ── Security findings analysis ───────────────────────────────────────
    commit_sec_findings=0
    commit_sec_test_findings=0
    if [[ "$security_overlay" == "True" || "$security_overlay" == "true" ]]; then
        SECURITY_TRIGGERED=$(( SECURITY_TRIGGERED + 1 ))
        # Record file paths that triggered security overlay
        for f in $changed_files; do
            SECURITY_FILES_ALL="${SECURITY_FILES_ALL}${f}"$'\n'
        done

        # Count security pattern matches in added lines
        for pat in "${SECURITY_PATTERNS[@]}"; do
            match_count=$(printf '%s\n' "$added_lines" | { grep -i -E "$pat" 2>/dev/null || true; } | wc -l | tr -d ' ')
            match_count="${match_count:-0}"
            if [[ "$match_count" -gt 0 ]]; then
                commit_sec_findings=$(( commit_sec_findings + match_count ))
            fi
        done

        # Estimate blue team dismissal: count findings from test-only files
        for f in $changed_files; do
            if [[ "$f" == tests/* || "$f" == test/* || "$f" == */tests/* || "$f" == */test/* ]]; then
                # Get added lines for this specific file from the diff
                file_added=$(printf '%s\n' "$diff_content" | \
                    awk -v file="b/$f" '/^diff --git/{found=0} /^diff --git.*'"$f"'/{found=1} found && /^\+[^+]/{print substr($0,2)}' 2>/dev/null || true)
                for pat in "${SECURITY_PATTERNS[@]}"; do
                    test_match_count=$(printf '%s\n' "$file_added" | { grep -i -E "$pat" 2>/dev/null || true; } | wc -l | tr -d ' ')
                    test_match_count="${test_match_count:-0}"
                    if [[ "$test_match_count" -gt 0 ]]; then
                        commit_sec_test_findings=$(( commit_sec_test_findings + test_match_count ))
                    fi
                done
            fi
        done

        TOTAL_SEC_FINDINGS=$(( TOTAL_SEC_FINDINGS + commit_sec_findings ))
        TOTAL_SEC_TEST_FINDINGS=$(( TOTAL_SEC_TEST_FINDINGS + commit_sec_test_findings ))
    fi
    RESULT_SEC_FINDINGS+=("$commit_sec_findings")
    RESULT_SEC_TEST_FINDINGS+=("$commit_sec_test_findings")

    # ── Performance findings analysis ────────────────────────────────────
    commit_perf_findings=0
    commit_perf_important=0
    commit_perf_minor=0
    if [[ "$performance_overlay" == "True" || "$performance_overlay" == "true" ]]; then
        PERFORMANCE_TRIGGERED=$(( PERFORMANCE_TRIGGERED + 1 ))
        for f in $changed_files; do
            PERFORMANCE_FILES_ALL="${PERFORMANCE_FILES_ALL}${f}"$'\n'
        done

        # Count performance pattern matches and classify severity
        for idx in "${!PERFORMANCE_PATTERNS[@]}"; do
            pat="${PERFORMANCE_PATTERNS[$idx]}"
            match_count=$(printf '%s\n' "$added_lines" | { grep -i -E "$pat" 2>/dev/null || true; } | wc -l | tr -d ' ')
            match_count="${match_count:-0}"
            if [[ "$match_count" -gt 0 ]]; then
                commit_perf_findings=$(( commit_perf_findings + match_count ))
                # Apply bright-line severity
                is_important=false
                for imp_idx in $PERF_IMPORTANT_INDICES; do
                    if [[ "$idx" -eq "$imp_idx" ]]; then
                        is_important=true
                        break
                    fi
                done
                if [[ "$is_important" == "true" ]]; then
                    commit_perf_important=$(( commit_perf_important + match_count ))
                else
                    commit_perf_minor=$(( commit_perf_minor + match_count ))
                fi
            fi
        done

        TOTAL_PERF_FINDINGS=$(( TOTAL_PERF_FINDINGS + commit_perf_findings ))
        TOTAL_PERF_IMPORTANT=$(( TOTAL_PERF_IMPORTANT + commit_perf_important ))
        TOTAL_PERF_MINOR=$(( TOTAL_PERF_MINOR + commit_perf_minor ))
    fi
    RESULT_PERF_FINDINGS+=("$commit_perf_findings")
    RESULT_PERF_IMPORTANT+=("$commit_perf_important")
    RESULT_PERF_MINOR+=("$commit_perf_minor")

    if { [[ "$security_overlay" == "True" || "$security_overlay" == "true" ]] && \
         [[ "$performance_overlay" == "True" || "$performance_overlay" == "true" ]]; }; then
        BOTH_TRIGGERED=$(( BOTH_TRIGGERED + 1 ))
    fi

    # Progress indicator
    printf '  [%d/%d] %s: sec=%s(%d findings) perf=%s(%d findings) tier=%s\n' \
        "$TOTAL_ANALYZED" "${#COMMITS[@]}" "$abbrev" \
        "$security_overlay" "$commit_sec_findings" \
        "$performance_overlay" "$commit_perf_findings" "$selected_tier"
done

echo ""
echo "Analysis complete. Generating report..."

# ── Compute percentages ───────────────────────────────────────────────────────
_pct() {
    local count="$1"
    local total="$2"
    if [[ "$total" -eq 0 ]]; then echo "0.0"; return; fi
    python3 -c "print(f'{100.0 * $count / $total:.1f}')" 2>/dev/null || echo "n/a"
}

SEC_PCT=$(_pct "$SECURITY_TRIGGERED" "$TOTAL_ANALYZED")
PERF_PCT=$(_pct "$PERFORMANCE_TRIGGERED" "$TOTAL_ANALYZED")
BOTH_PCT=$(_pct "$BOTH_TRIGGERED" "$TOTAL_ANALYZED")

# ── Compute findings metrics ─────────────────────────────────────────────────
_avg() {
    local total="$1"
    local count="$2"
    if [[ "$count" -eq 0 ]]; then echo "0.0"; return; fi
    python3 -c "print(f'{$total / $count:.1f}')" 2>/dev/null || echo "n/a"
}

SEC_AVG_FINDINGS=$(_avg "$TOTAL_SEC_FINDINGS" "$SECURITY_TRIGGERED")
PERF_AVG_FINDINGS=$(_avg "$TOTAL_PERF_FINDINGS" "$PERFORMANCE_TRIGGERED")

# Blue team dismissal rate: % of security findings that are in test-only files
BLUE_TEAM_DISMISSAL_PCT=$(_pct "$TOTAL_SEC_TEST_FINDINGS" "$TOTAL_SEC_FINDINGS")

# ── Build unique file pattern summaries ──────────────────────────────────────
# Top directory components
_top_dirs() {
    local file_list="$1"
    printf '%s' "$file_list" | grep -v '^$' | \
        awk -F'/' '{print $1}' | sort | uniq -c | sort -rn | head -10 | \
        awk '{printf "  - `%s` (%d files)\n", $2, $1}' 2>/dev/null || true
}

_unique_file_list() {
    local file_list="$1"
    printf '%s' "$file_list" | grep -v '^$' | sort -u | head -20 | \
        awk '{printf "  - `%s`\n", $0}' 2>/dev/null || true
}

SEC_TOP_DIRS=$(_top_dirs "$SECURITY_FILES_ALL")
PERF_TOP_DIRS=$(_top_dirs "$PERFORMANCE_FILES_ALL")
SEC_FILE_LIST=$(_unique_file_list "$SECURITY_FILES_ALL")
PERF_FILE_LIST=$(_unique_file_list "$PERFORMANCE_FILES_ALL")

# ── Generate timestamp ────────────────────────────────────────────────────────
GENERATED_AT=$(date -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "unknown")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# ── Build per-commit table ────────────────────────────────────────────────────
COMMIT_TABLE=""
for i in "${!RESULT_SHA[@]}"; do
    sec="${RESULT_SECURITY[$i]}"
    perf="${RESULT_PERFORMANCE[$i]}"
    [[ "$sec" == "True" || "$sec" == "true" ]] && sec_mark="yes" || sec_mark="no"
    [[ "$perf" == "True" || "$perf" == "true" ]] && perf_mark="yes" || perf_mark="no"
    sec_findings="${RESULT_SEC_FINDINGS[$i]}"
    perf_findings="${RESULT_PERF_FINDINGS[$i]}"
    # Truncate subject to 50 chars (shorter to fit new columns)
    subj="${RESULT_SUBJECT[$i]}"
    if [[ ${#subj} -gt 50 ]]; then
        subj="${subj:0:47}..."
    fi
    COMMIT_TABLE="${COMMIT_TABLE}| \`${RESULT_ABBREV[$i]}\` | ${subj} | ${sec_mark} | ${sec_findings} | ${perf_mark} | ${perf_findings} | ${RESULT_TIER[$i]} |"$'\n'
done

# ── Write report ──────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$OUTPUT")"

cat > "$OUTPUT" <<REPORT
# Overlay Calibration Baselines

Generated: ${GENERATED_AT}
Branch: \`${BRANCH}\`
Commits analyzed: ${TOTAL_ANALYZED} (limit: ${LIMIT})

## Summary Statistics

| Metric | Count | Rate |
|--------|-------|------|
| Total commits analyzed | ${TOTAL_ANALYZED} | 100% |
| Security overlay triggered | ${SECURITY_TRIGGERED} | ${SEC_PCT}% |
| Performance overlay triggered | ${PERFORMANCE_TRIGGERED} | ${PERF_PCT}% |
| Both overlays triggered | ${BOTH_TRIGGERED} | ${BOTH_PCT}% |

## Findings Per Overlay

Pattern-matched findings generated by scanning added lines in each triggered commit.

| Overlay | Total findings | Avg findings per trigger | Commits triggered |
|---------|---------------|------------------------|-------------------|
| Security | ${TOTAL_SEC_FINDINGS} | ${SEC_AVG_FINDINGS} | ${SECURITY_TRIGGERED} |
| Performance | ${TOTAL_PERF_FINDINGS} | ${PERF_AVG_FINDINGS} | ${PERFORMANCE_TRIGGERED} |

### Security pattern breakdown

Each pattern is matched against added lines in commits that triggered the security overlay:

| Pattern | Description |
|---------|-------------|
REPORT

# Append security pattern descriptions
for idx in "${!SECURITY_PATTERN_NAMES[@]}"; do
    printf '| %d | %s |\n' "$((idx + 1))" "${SECURITY_PATTERN_NAMES[$idx]}" >> "$OUTPUT"
done

cat >> "$OUTPUT" <<REPORT

### Performance pattern breakdown

| Pattern | Description |
|---------|-------------|
REPORT

for idx in "${!PERFORMANCE_PATTERN_NAMES[@]}"; do
    printf '| %d | %s |\n' "$((idx + 1))" "${PERFORMANCE_PATTERN_NAMES[$idx]}" >> "$OUTPUT"
done

cat >> "$OUTPUT" <<REPORT

## Blue Team Estimated Dismissal Rate

Estimates how many security findings the blue team would dismiss because they
appear only in test files (files matching \`tests/*\`, \`test/*\`, \`*/tests/*\`, \`*/test/*\`).

| Metric | Count |
|--------|-------|
| Total security findings | ${TOTAL_SEC_FINDINGS} |
| Findings in test-only files (would be dismissed) | ${TOTAL_SEC_TEST_FINDINGS} |
| **Estimated dismissal rate** | **${BLUE_TEAM_DISMISSAL_PCT}%** |

A high dismissal rate (>50%) suggests the security overlay is triggering heavily on
test code, which blue team reviewers would typically dismiss as false positives.

## Performance Severity Distribution

Bright-line severity rules: patterns involving loops (SQL inside loop), unbounded
accumulation, or blocking in async context are classified as **important**. All other
performance patterns are classified as **minor**. No findings are classified as
**critical** by automated pattern matching (critical requires human reviewer judgment).

| Severity | Count | Rate |
|----------|-------|------|
| Critical | 0 | 0.0% |
| Important | ${TOTAL_PERF_IMPORTANT} | $(_pct "$TOTAL_PERF_IMPORTANT" "$TOTAL_PERF_FINDINGS")% |
| Minor | ${TOTAL_PERF_MINOR} | $(_pct "$TOTAL_PERF_MINOR" "$TOTAL_PERF_FINDINGS")% |
| **Total** | **${TOTAL_PERF_FINDINGS}** | **100%** |

## Security Overlay

### Top directory patterns

${SEC_TOP_DIRS:-  *(no triggers)*}

### Files that triggered security overlay (unique, top 20)

${SEC_FILE_LIST:-  *(none)*}

## Performance Overlay

### Top directory patterns

${PERF_TOP_DIRS:-  *(no triggers)*}

### Files that triggered performance overlay (unique, top 20)

${PERF_FILE_LIST:-  *(none)*}

## Per-Commit Detail

| SHA | Subject | Security | Sec Findings | Performance | Perf Findings | Tier |
|-----|---------|----------|-------------|-------------|--------------|------|
${COMMIT_TABLE}

## Interpretation Notes

- **Security overlay** triggers when changed files match \`*/auth/*\`, \`*/security/*\`,
  \`*/crypto/*\`, \`*/encryption/*\`, \`*/session/*\`, \`*/oauth/*\`, or when added lines
  contain security-sensitive imports/keywords (password, secret, token, credential,
  certificate, cryptography imports).
- **Performance overlay** triggers when changed files match \`*/db/*\`, \`*/database/*\`,
  \`*/cache/*\`, \`*/query/*\`, \`*/pool/*\`, \`*/persistence/*\`, or when added lines
  contain SQL/async/concurrency keywords (SELECT, INSERT, UPDATE, DELETE, cursor,
  pool, async def, await, threading, multiprocessing).
- **Findings count** reflects pattern matches in added lines of triggered commits.
  Each regex match against added lines counts as one potential finding.
- **Blue team dismissal rate** estimates what percentage of security findings
  would be dismissed because they appear in test files only.
- **Performance severity** uses bright-line rules: loop-related and unbounded
  patterns are important; all others are minor. Critical severity requires
  human judgment and is never assigned by automated matching.
- Trigger rates above 30% suggest the overlay patterns are well-calibrated for
  this codebase. Rates below 5% may indicate the patterns don't match the
  project's naming conventions.

## How to Refresh

\`\`\`bash
bash \${_PLUGIN_ROOT}/scripts/run-overlay-retrospective.sh --limit 20
\`\`\`
REPORT

echo "Report written to: $OUTPUT"
