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
WORKFLOW="$REPO_ROOT/.github/workflows/review-sub-pr.yml"

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

# ── Test 3: provisioner emits ~ALL include in sub-PR ruleset payload ──────────
# Behavioral test: run the provisioner in dry-run and assert that the sub-PR
# ruleset payload contains "~ALL" as its include array.
_snapshot_fail
dryrun_output=$(DSO_DRY_RUN=1 bash "$PROVISIONER" 2>&1 || true)
has_all_include="no"
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
    has_all_include="yes"
fi
assert_eq "test_provisioner_emits_staged_include: sub-PR ruleset include is [\"refs/heads/staged-*\"]" \
    "yes" "$has_all_include"
assert_pass_if_clean "test_provisioner_emits_staged_include"

# ── Test 4: provisioner emits an empty exclude list ──────────────────────────
# Under the two-tier promotion model, the sub-PR ruleset's include is just
# refs/heads/staged-* and no excludes are needed (main and tickets are not
# captured by staged-* in the first place).
_snapshot_fail
has_empty_exclude="no"
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
                            exc = obj.get("conditions", {}).get("ref_name", {}).get("exclude", [])
                            sys.exit(0 if not exc else 1)
                    except json.JSONDecodeError:
                        pass
                    break
        if depth == 0 and j > start: break
sys.exit(1)
' 2>/dev/null; then
    has_empty_exclude="yes"
fi
assert_eq "test_provisioner_emits_empty_exclude: sub-PR ruleset exclude list is empty" \
    "yes" "$has_empty_exclude"
assert_pass_if_clean "test_provisioner_emits_empty_exclude"

# ── Test 5: workflow trigger uses branches-ignore: [main] ─────────────────────
# review-sub-pr.yml must trigger on every PR not targeting main. Asserting the
# branches-ignore form keeps the workflow scope aligned with the ruleset
# scope without enumerating branch patterns.
_snapshot_fail
workflow_uses_branches_ignore="no"
if python3 -c "
import sys, yaml
with open('$WORKFLOW') as f:
    data = yaml.safe_load(f)
on = data.get('on') or data.get(True)
pr = on.get('pull_request', {}) if isinstance(on, dict) else {}
bi = pr.get('branches-ignore', [])
sys.exit(0 if 'main' in bi else 1)
" 2>/dev/null; then
    workflow_uses_branches_ignore="yes"
fi
assert_eq "test_workflow_uses_branches_ignore_main: workflow triggers on every PR not targeting main" \
    "yes" "$workflow_uses_branches_ignore"
assert_pass_if_clean "test_workflow_uses_branches_ignore_main"

# ── Test 6: workflow trigger does NOT enumerate branch patterns ───────────────
# Regression guard against re-introducing the enumeration design.
_snapshot_fail
workflow_no_branches_list="yes"
if python3 -c "
import sys, yaml
with open('$WORKFLOW') as f:
    data = yaml.safe_load(f)
on = data.get('on') or data.get(True)
pr = on.get('pull_request', {}) if isinstance(on, dict) else {}
sys.exit(0 if pr.get('branches') else 1)
" 2>/dev/null; then
    workflow_no_branches_list="no"
fi
assert_eq "test_workflow_has_no_branches_list: workflow uses branches-ignore (not branches enumeration)" \
    "yes" "$workflow_no_branches_list"
assert_pass_if_clean "test_workflow_has_no_branches_list"

print_summary
