#!/usr/bin/env bash
# plugins/dso/scripts/run-overlay-retrospective.sh
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
OUTPUT="${REPO_ROOT}/plugins/dso/docs/overlay-calibration-baselines.md"
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
                  (default: plugins/dso/docs/overlay-calibration-baselines.md)
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
elif [[ -n "$REPO_ROOT" && -x "$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh" ]]; then
    CLASSIFIER="$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh"
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

# ── Per-commit analysis ───────────────────────────────────────────────────────
# Accumulate results into parallel arrays
declare -a RESULT_SHA=()
declare -a RESULT_ABBREV=()
declare -a RESULT_SUBJECT=()
declare -a RESULT_FILES=()
declare -a RESULT_SECURITY=()
declare -a RESULT_PERFORMANCE=()
declare -a RESULT_TIER=()

# Counters
TOTAL_ANALYZED=0
SECURITY_TRIGGERED=0
PERFORMANCE_TRIGGERED=0
BOTH_TRIGGERED=0

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

    # Extract fields using python3 (jq-free as per hook architecture conventions)
    security_overlay=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('security_overlay','false'))" <<< "$classifier_out" 2>/dev/null || echo "false")
    performance_overlay=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('performance_overlay','false'))" <<< "$classifier_out" 2>/dev/null || echo "false")
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

    if [[ "$security_overlay" == "True" || "$security_overlay" == "true" ]]; then
        SECURITY_TRIGGERED=$(( SECURITY_TRIGGERED + 1 ))
        # Record file paths that triggered security overlay
        for f in $changed_files; do
            SECURITY_FILES_ALL="${SECURITY_FILES_ALL}${f}"$'\n'
        done
    fi

    if [[ "$performance_overlay" == "True" || "$performance_overlay" == "true" ]]; then
        PERFORMANCE_TRIGGERED=$(( PERFORMANCE_TRIGGERED + 1 ))
        for f in $changed_files; do
            PERFORMANCE_FILES_ALL="${PERFORMANCE_FILES_ALL}${f}"$'\n'
        done
    fi

    if { [[ "$security_overlay" == "True" || "$security_overlay" == "true" ]] && \
         [[ "$performance_overlay" == "True" || "$performance_overlay" == "true" ]]; }; then
        BOTH_TRIGGERED=$(( BOTH_TRIGGERED + 1 ))
    fi

    # Progress indicator
    printf '  [%d/%d] %s: sec=%s perf=%s tier=%s\n' \
        "$TOTAL_ANALYZED" "${#COMMITS[@]}" "$abbrev" \
        "$security_overlay" "$performance_overlay" "$selected_tier"
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
    # Truncate subject to 60 chars
    subj="${RESULT_SUBJECT[$i]}"
    if [[ ${#subj} -gt 60 ]]; then
        subj="${subj:0:57}..."
    fi
    COMMIT_TABLE="${COMMIT_TABLE}| \`${RESULT_ABBREV[$i]}\` | ${subj} | ${sec_mark} | ${perf_mark} | ${RESULT_TIER[$i]} |"$'\n'
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

| SHA | Subject | Security | Performance | Tier |
|-----|---------|----------|-------------|------|
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
- Trigger rates above 30% suggest the overlay patterns are well-calibrated for
  this codebase. Rates below 5% may indicate the patterns don't match the
  project's naming conventions.

## How to Refresh

\`\`\`bash
bash plugins/dso/scripts/run-overlay-retrospective.sh --limit 20
\`\`\`
REPORT

echo "Report written to: $OUTPUT"
