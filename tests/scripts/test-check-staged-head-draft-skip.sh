#!/usr/bin/env bash
# tests/scripts/test-check-staged-head-draft-skip.sh
#
# check-staged-head enforces "only staged-* heads may merge into main". The sprint
# umbrella defense-substrate PR is base=main / head=session and ALWAYS a draft;
# its failure (head ≠ staged-*) attaches to the shared head commit and contaminates
# PR1 (source→staged), which shares the same head SHA — blocking the two-tier
# promotion (bug 1f5f). The gate therefore PASSES draft PRs (they cannot merge
# anyway) while still BLOCKING non-draft non-staged heads. `ready_for_review` must
# be a trigger so a draft→ready transition re-evaluates non-draft (no bypass).
#
# Behavioral: extracts the gate's run: script and executes its logic with fixtures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="$REPO_ROOT/.github/workflows/check-staged-head.yml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-check-staged-head-draft-skip.sh ==="

# Extract the gate's run: script so we can execute its decision logic directly.
GATE_SH=$(mktemp "${TMPDIR:-/tmp}/check-staged-head.XXXXXX")
python3 -c "
import yaml, sys
wf = yaml.safe_load(open('$WF'))
steps = wf['jobs']['check-staged-head']['steps']
run = next(s['run'] for s in steps if 'run' in s)
sys.stdout.write(run)
" > "$GATE_SH"

# _run <IS_DRAFT> <HEAD_REF> -> exit code of the gate logic
_run() { IS_DRAFT="$1" HEAD_REF="$2" bash "$GATE_SH" >/dev/null 2>&1; echo $?; }

# Draft PR (any head) PASSES — the contamination fix (1f5f).
_snapshot_fail
assert_eq "draft PR passes regardless of head (contamination fix, 1f5f)" "0" "$(_run true some-non-staged-head)"
assert_pass_if_clean "draft_passes"

# Non-draft staged-* head PASSES (the real promotion PR2).
_snapshot_fail
assert_eq "non-draft staged-* head passes" "0" "$(_run false staged-abc123-1780000000)"
assert_pass_if_clean "nondraft_staged_passes"

# Non-draft non-staged head BLOCKS — enforcement intact (no weakening).
_snapshot_fail
assert_eq "non-draft non-staged head blocks (enforcement intact)" "1" "$(_run false fix/my-bug)"
assert_pass_if_clean "nondraft_nonstaged_blocks"

# Non-draft empty head fails closed.
_snapshot_fail
assert_eq "non-draft empty head fails closed" "1" "$(_run false '')"
assert_pass_if_clean "nondraft_empty_failclosed"

# Structural: the step's env: block must wire IS_DRAFT / HEAD_REF to the GitHub
# Actions context. The behavioral cases above set these as bash vars; this asserts
# the workflow actually sources them from github.event.pull_request.draft and
# github.head_ref (so the draft pass-through reads the real draft flag at runtime).
_snapshot_fail
_envmap=$(python3 -c "
import yaml
wf = yaml.safe_load(open('$WF'))
env = next(s['env'] for s in wf['jobs']['check-staged-head']['steps'] if 'env' in s)
ok = ('github.event.pull_request.draft' in str(env.get('IS_DRAFT', '')) and
      'github.head_ref' in str(env.get('HEAD_REF', '')))
print('1' if ok else '0')
")
assert_eq "step env wires IS_DRAFT<-pull_request.draft and HEAD_REF<-head_ref" "1" "$_envmap"
assert_pass_if_clean "env_block_wiring"

# Structural: ready_for_review must be a trigger type (closes the draft→ready bypass).
_snapshot_fail
_rfr=$(python3 -c "
import yaml
wf = yaml.safe_load(open('$WF'))
on = wf.get('on') or wf.get(True)          # YAML may parse the 'on' key as boolean True
types = (on.get('pull_request') or {}).get('types', [])
print('1' if 'ready_for_review' in types else '0')
")
assert_eq "ready_for_review trigger present (closes draft->ready bypass)" "1" "$_rfr"
assert_pass_if_clean "ready_for_review_trigger"

rm -f "$GATE_SH"
print_summary
