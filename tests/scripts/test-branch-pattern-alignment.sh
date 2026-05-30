#!/usr/bin/env bash
# tests/scripts/test-branch-pattern-alignment.sh
#
# Asserts the negative-list sub-PR ruleset design (PR-4 R9 redesign):
#
#   1. plugins/dso/config/sub-pr-branch-patterns.txt still exists and is
#      consumed by the dispatcher (llm-review-dispatch-or-skip.sh) for its
#      _FORCE_REVIEW regex. The patterns file's scope narrowed to
#      "force-review eligibility" only — it no longer drives ruleset scope.
#
#   2. The provisioner (provision-ruleset.sh) emits the "DSO Sub-PR Review
#      Enforcement" ruleset with the negative-list shape:
#        conditions.ref_name.include = ["~ALL"]
#        conditions.ref_name.exclude = ["refs/heads/main"]
#      This applies the ruleset to every PR whose base is NOT main, without
#      needing to enumerate every branch convention.
#
#   3. The workflow trigger (.github/workflows/review-sub-pr.yml) uses
#      branches-ignore: [main] (mirroring the ruleset). The workflow fires
#      on the same set of PRs the ruleset enforces.
#
# Together these assertions guarantee the workflow and ruleset stay in sync
# without enumerating branch patterns in three places.
#
# Usage: bash tests/scripts/test-branch-pattern-alignment.sh
# Returns: exit 0 if all assertions hold, exit 1 if any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATTERNS_FILE="$REPO_ROOT/plugins/dso/config/sub-pr-branch-patterns.txt"
DISPATCHER="$REPO_ROOT/plugins/dso/scripts/llm-review-dispatch-or-skip.sh"
PROVISIONER="$REPO_ROOT/plugins/dso/scripts/onboarding/provision-ruleset.sh"
# post-migration: review-sub-pr is now a job in ci.yml (was its own workflow
# file). Tests below assert the job-level if: predicate, not workflow-trigger
# level.
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-branch-pattern-alignment.sh ==="

# ── Test 1: patterns file present with non-comment entries ────────────────────
# The patterns file is still consumed by the dispatcher's force-review regex.
_snapshot_fail
patterns_file_present="no"
if [[ -f "$PATTERNS_FILE" ]]; then
    pattern_count=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "$PATTERNS_FILE" 2>/dev/null || echo 0)
    if (( pattern_count > 0 )); then
        patterns_file_present="yes"
    fi
fi
assert_eq "test_patterns_file_exists_with_entries: source-of-truth file present" \
    "yes" "$patterns_file_present"
assert_pass_if_clean "test_patterns_file_exists_with_entries"

# ── Test 2: dispatcher references the patterns file ───────────────────────────
_snapshot_fail
dispatcher_reads_file="no"
if grep -qF 'sub-pr-branch-patterns.txt' "$DISPATCHER" 2>/dev/null; then
    dispatcher_reads_file="yes"
fi
assert_eq "test_dispatcher_references_patterns_file: dispatcher reads source-of-truth file" \
    "yes" "$dispatcher_reads_file"
assert_pass_if_clean "test_dispatcher_references_patterns_file"

# ── Test 3: provisioner emits staged-* include in sub-PR ruleset payload ────
# Under the two-tier promotion model, sub-PR review fires only on PRs into
# staged-* branches. Feature branches (anything else) stay unrestricted.
_snapshot_fail
dryrun_output=$(DSO_DRY_RUN=1 bash "$PROVISIONER" 2>&1 || true)
has_staged_include="no"
if echo "$dryrun_output" | python3 -c '
import sys, json
text = sys.stdin.read()
lines = text.split("\n")
for start in [i for i, l in enumerate(lines) if l.strip() == "{"]:
    depth = 0
    for j in range(start, len(lines)):
        for ch in lines[j]:
            if ch == "{": depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads("\n".join(lines[start:j+1]))
                        if isinstance(obj, dict) and obj.get("name") == "DSO Sub-PR Review Enforcement":
                            inc = obj.get("conditions", {}).get("ref_name", {}).get("include", [])
                            sys.exit(0 if "refs/heads/staged-*" in inc else 1)
                    except json.JSONDecodeError:
                        pass
                    break
        if depth == 0 and j > start: break
sys.exit(1)
' 2>/dev/null; then
    has_staged_include="yes"
fi
assert_eq "test_provisioner_emits_staged_include: sub-PR ruleset include is [\"refs/heads/staged-*\"]" \
    "yes" "$has_staged_include"
assert_pass_if_clean "test_provisioner_emits_staged_include"

# ── Test 4: provisioner emits required_workflows rule (not required_status_checks) ──
# Under the new model, the sub-PR ruleset uses `required_workflows` instead
# of `required_status_checks` so the rule evaluates at PR-merge time (not at
# ref-update time). This is what unblocks raw pushes to staged-* branches.
_snapshot_fail
has_workflows_rule="no"
if echo "$dryrun_output" | python3 -c '
import sys, json
text = sys.stdin.read()
lines = text.split("\n")
for start in [i for i, l in enumerate(lines) if l.strip() == "{"]:
    depth = 0
    for j in range(start, len(lines)):
        for ch in lines[j]:
            if ch == "{": depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads("\n".join(lines[start:j+1]))
                        if isinstance(obj, dict) and obj.get("name") == "DSO Sub-PR Review Enforcement":
                            rules = obj.get("rules", [])
                            rule_types = [r.get("type") for r in rules]
                            sys.exit(0 if "workflows" in rule_types else 1)
                    except json.JSONDecodeError:
                        pass
                    break
        if depth == 0 and j > start: break
sys.exit(1)
' 2>/dev/null; then
    has_workflows_rule="yes"
fi
assert_eq "test_provisioner_emits_workflows_rule: sub-PR ruleset uses required_workflows rule type" \
    "yes" "$has_workflows_rule"
assert_pass_if_clean "test_provisioner_emits_workflows_rule"

# ── Test 5: llm-review-sub-pr job has `if: base_ref != 'main'` ───────────────
# Post-migration (workflow moved into ci.yml as a job): the review-sub-pr
# job must fire on every PR whose base is NOT main, gated by an if:
# predicate at job level (the workflow-trigger-level `branches-ignore` from
# the prior design no longer exists since ci.yml triggers on all PRs).
_snapshot_fail
job_uses_base_ref_check="no"
if python3 -c "
import sys, yaml
with open('$WORKFLOW') as f:
    data = yaml.safe_load(f)
jobs = data.get('jobs', {})
job = jobs.get('llm-review-sub-pr', {})
if_expr = job.get('if', '') or ''
# Accept any predicate that checks base_ref != main (or != default_branch).
ok = ('base_ref' in if_expr) and ('main' in if_expr) and ('!=' in if_expr)
sys.exit(0 if ok else 1)
" 2>/dev/null; then
    job_uses_base_ref_check="yes"
fi
assert_eq "test_job_uses_base_ref_not_main: llm-review-sub-pr job filters PRs whose base is not main" \
    "yes" "$job_uses_base_ref_check"
assert_pass_if_clean "test_job_uses_base_ref_not_main"

# ── Test 6: llm-review-sub-pr job name matches the ruleset's required check ──
# The sub-PR ruleset's required_status_check context is "review-sub-pr" — the
# job MUST expose that exact name or the ruleset deadlocks every sub-PR.
_snapshot_fail
job_name_matches="no"
if python3 -c "
import sys, yaml
with open('$WORKFLOW') as f:
    data = yaml.safe_load(f)
job = data.get('jobs', {}).get('llm-review-sub-pr', {})
sys.exit(0 if job.get('name') == 'review-sub-pr' else 1)
" 2>/dev/null; then
    job_name_matches="yes"
fi
assert_eq "test_job_name_matches_ruleset_check: llm-review-sub-pr job's name field is 'review-sub-pr'" \
    "yes" "$job_name_matches"
assert_pass_if_clean "test_job_name_matches_ruleset_check"

print_summary
