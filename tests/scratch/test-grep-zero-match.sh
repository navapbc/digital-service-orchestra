#!/usr/bin/env bash
# tests/scratch/test-grep-zero-match.sh
#
# SC-2 gate (epic 1d8b): asserts zero --artifact sub-agent-prompt handoffs
# remain in the 3 migrated skill files.
#
# Epic context: 1d8b-0cad-8d19-45ad (--artifact sub-agent-prompt migration to
# scratch CLI). Task: ec72-846d-bae1-46b8.
#
# Design intent:
#   After migration, all sub-agent output handoffs that previously used
#   --artifact <path> arguments must use the scratch CLI instead. The only
#   remaining --artifact occurrences in these skill files must be helper-script
#   flag references (append_review_cycle.py --artifact ...), which are
#   carve-outs per the epic acceptance criteria.
#
# Carve-out rule (from AC): a --artifact line is ACCEPTED if the line or any
# line within a 5-line context window also contains:
#   - "python3" (helper script invocation), OR
#   - "append_review_cycle.py" (the specific helper), OR
#   - "--artifact-file=" (related helper flag, not a sub-agent-prompt handoff), OR
#   - "--artifacts-dir" (related helper flag, not a sub-agent-prompt handoff)
# Any remaining --artifact match that does NOT satisfy a carve-out is a FAIL.
#
# Synthetic regression test: injects a bare "--artifact /tmp/out.json" line into
# a tmpfile copy and verifies the gate catches it.
#
# Usage: bash tests/scratch/test-grep-zero-match.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

PREPLANNING_SKILL="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"
IMPL_PLAN_SKILL="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"
SPRINT_SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-grep-zero-match.sh: SC-2 gate — zero --artifact sub-agent-prompt handoffs ==="

# ── Preflight ────────────────────────────────────────────────────────────────
for skill_file in "$PREPLANNING_SKILL" "$IMPL_PLAN_SKILL" "$SPRINT_SKILL"; do
    if [ ! -f "$skill_file" ]; then
        echo "FATAL: skill file not found: $skill_file" >&2
        exit 1
    fi
done

# ── Core gate logic ───────────────────────────────────────────────────────────
# check_artifact_handoffs <file>
#
# For every line containing '--artifact ' in the file, examine a context window
# of ±5 lines. If ANY line in that window matches a carve-out pattern, the hit
# is accepted. Otherwise it is reported as a sub-agent-prompt handoff violation.
#
# Returns: number of violating (non-carve-out) --artifact hits via stdout.
# Prints diagnostic to stderr for each violation.
check_artifact_handoffs() {
    local file="$1"
    local violations=0
    local total_lines
    total_lines=$(wc -l < "$file")

    # Collect line numbers of --artifact hits
    local hit_lines=()
    while IFS= read -r line_num; do
        hit_lines+=("$line_num")
    done < <(grep -n -- '--artifact ' "$file" | cut -d: -f1)

    for lineno in "${hit_lines[@]:-}"; do
        [[ -z "$lineno" ]] && continue

        # Build context window [lineno-5 .. lineno+5], clamped to file bounds
        local ctx_start=$(( lineno - 5 ))
        local ctx_end=$(( lineno + 5 ))
        [[ $ctx_start -lt 1 ]] && ctx_start=1
        [[ $ctx_end -gt $total_lines ]] && ctx_end=$total_lines

        # Extract context window text
        local ctx
        ctx=$(sed -n "${ctx_start},${ctx_end}p" "$file")

        # Check carve-out patterns
        local is_carveout=0
        if echo "$ctx" | grep -qE 'python3|append_review_cycle\.py|--artifact-file=|--artifacts-dir'; then
            is_carveout=1
        fi

        if [[ "$is_carveout" -eq 0 ]]; then
            (( violations++ )) || true
            local hit_line_content
            hit_line_content=$(sed -n "${lineno}p" "$file")
            printf "VIOLATION: %s:%d: %s\n" "$file" "$lineno" "$hit_line_content" >&2
            printf "  Context (lines %d-%d):\n" "$ctx_start" "$ctx_end" >&2
            sed -n "${ctx_start},${ctx_end}p" "$file" | while IFS= read -r ctx_line; do
                printf "    %s\n" "$ctx_line" >&2
            done
        fi
    done

    echo "$violations"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: preplanning/SKILL.md — zero sub-agent-prompt --artifact handoffs
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: preplanning/SKILL.md — no --artifact sub-agent-prompt handoffs ──"
_snapshot_fail
violations_pre=$(check_artifact_handoffs "$PREPLANNING_SKILL")
assert_eq "preplanning SKILL.md: zero sub-agent-prompt --artifact handoffs" "0" "$violations_pre"
assert_pass_if_clean "Test 1: preplanning/SKILL.md SC-2 gate"

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: implementation-plan/SKILL.md — zero sub-agent-prompt --artifact handoffs
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: implementation-plan/SKILL.md — no --artifact sub-agent-prompt handoffs ──"
_snapshot_fail
violations_impl=$(check_artifact_handoffs "$IMPL_PLAN_SKILL")
assert_eq "implementation-plan SKILL.md: zero sub-agent-prompt --artifact handoffs" "0" "$violations_impl"
assert_pass_if_clean "Test 2: implementation-plan/SKILL.md SC-2 gate"

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: sprint/SKILL.md — zero sub-agent-prompt --artifact handoffs
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: sprint/SKILL.md — no --artifact sub-agent-prompt handoffs ──"
_snapshot_fail
violations_sprint=$(check_artifact_handoffs "$SPRINT_SKILL")
assert_eq "sprint SKILL.md: zero sub-agent-prompt --artifact handoffs" "0" "$violations_sprint"
assert_pass_if_clean "Test 3: sprint/SKILL.md SC-2 gate"

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: Synthetic regression — gate detects injected bare --artifact handoff
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: synthetic regression — gate detects injected bare --artifact handoff ──"
_snapshot_fail

# Create a tmpfile with an injected bare --artifact line (no python3/helper context)
_tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-grep-zero-match-XXXXXX".md)
cat > "$_tmpfile" <<'FIXTURE'
# Synthetic fixture for SC-2 regression test
## Phase A

Dispatch sub-agent with:
```
--output-dir /tmp/results
--artifact /tmp/results/plan.json
--timeout 120
```

Output: read from /tmp/results/plan.json
FIXTURE

synthetic_violations=$(check_artifact_handoffs "$_tmpfile" 2>/dev/null)
assert_ne "synthetic regression: gate detects bare --artifact handoff (non-zero violations)" "0" "$synthetic_violations"
rm -f "$_tmpfile"
assert_pass_if_clean "Test 4: synthetic regression detection"

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: Synthetic negative — carve-out accepted (append_review_cycle.py)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 5: synthetic negative — carve-out (append_review_cycle.py) is NOT flagged ──"
_snapshot_fail

# Create a tmpfile with only a legitimate helper-script --artifact reference
_tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-grep-zero-match-XXXXXX".md)
cat > "$_tmpfile" <<'FIXTURE'
# Synthetic fixture — helper-script carve-out only
## Review cycle update

After each cycle, run:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/append_review_cycle.py" \
  --artifact "$ARTIFACTS_DIR/review.json" \
  --n 1 \
  --verdict pass
```
FIXTURE

carveout_violations=$(check_artifact_handoffs "$_tmpfile" 2>/dev/null)
assert_eq "carve-out fixture: append_review_cycle.py --artifact not flagged" "0" "$carveout_violations"
rm -f "$_tmpfile"
assert_pass_if_clean "Test 5: carve-out accepted (append_review_cycle.py)"

print_summary
