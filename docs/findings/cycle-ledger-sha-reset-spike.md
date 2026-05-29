# PR-D Spike: cycle-counter SHA-reset behavior

**Status:** discovery only — no code change.
**Context:** f148 R7 follow-up. The original PR-1 diagnosis attributed
"force-dispatch on every merge-SHA reset" to
`llm-review-dispatch-or-skip.sh:154`. That diagnosis was wrong: the
dispatcher already uses the PR HEAD SHA
(`gh api .../pulls/${PR}.head.sha`). The cycle counter reset lives
elsewhere — in the Python ledger code.

## Where the reset happens

Two implementations of the same rule:

### 1. `cycle_dispatcher.next_action` (cycle_dispatcher.py:236-257)
```python
# Edge case: SHA changed -> reset cycle_num to 1 (wins over max_cycles).
if (
    last_cycle
    and last_cycle.get("commit_sha")
    and last_cycle["commit_sha"] != current_commit_sha
):
    cycle_num = 1
    ...
    return {"action": "DISPATCH_NEXT",
            "reason": f"commit_sha changed from ... reset to cycle 1",
            "cycle_num": cycle_num}
```
This is the authoritative writer — the ledger's `cycle_num` field
flows from this function.

### 2. `_init_cycle_ledger` (runner.py:2375-2394)
```python
# SHA-reset: when HEAD changed since the last ledger cycle, reset
# cycle_number to 1 — mirrors cycle_dispatcher.next_action lines 236-257.
# Without this, _init_cycle_ledger returns stale cycle counts after
# force-pushes, causing defense-loading and two-call dispatch gates to
# use incorrect cycle context (bug 3fb2-23be).
if (
    _last_cycle
    and _last_cycle.get("commit_sha")
    and _last_cycle["commit_sha"] != reviewed_sha
    and cycle_number > 1
):
    print("INFO: commit_sha changed (... → ...); resetting cycle_number from N to 1", ...)
    cycle_number = 1
```
This is a mirror of the dispatcher logic that runs at runner-entry
time, before the per-cycle `cycle_next_action` call. The duplication
exists because the runner's downstream consumers (defense loading,
two-call gate at line 2716, dismissal-memory filter at line 2747,
novelty gate at line 2765) read `cycle_number` directly — they would
load stale defenses if the runner-level value wasn't reset before they
ran.

## What SHA-key the defense ledger uses

The reset compares `last_cycle["commit_sha"]` against
`reviewed_sha`, where `reviewed_sha` is set by the runner from
`_resolve_pr_head_sha(pr_number)` — i.e., **the PR HEAD SHA**, as
returned by `gh pr view --json headRefOid` on `pull_request` /
`pull_request_target` events (since R1 / PR #449). On non-PR events,
it falls back to `GITHUB_SHA`.

So the ledger key is the **commit SHA on the branch tip**, NOT the
synthesized merge-commit SHA. This matches the dispatcher's
post-PR-#449 expectation.

## Is the reset intentional?

Yes, under every scenario reviewed. The LEDGER-SAFE comments at
runner.py:2648, 2716, 2747, 2765 explicitly document that the reset is
load-bearing for correctness:

- **2648** (two-call dispatch): SHA-reset → cycle_num=1 → prior_defenses=[] → the
  defense-aware augmentation path is correctly skipped on a fresh
  commit. Without the reset, the dispatcher would try to load defenses
  attached to a sibling SHA the reviewer has not yet seen, producing
  false-negative suppression.
- **2716** (defense-context injection for arch synthesis): same
  reasoning — augmenting the arch prompt with a previous SHA's
  defenses produces architectural reasoning over stale context.
- **2747** (dismissal-memory filter): suppressing defended findings
  from a different SHA would silently swallow real regressions
  introduced by the new commit.
- **2765** (novelty gate): downgrading "new introduced" findings
  requires a same-SHA prior cycle for the comparison to be meaningful.
  Cross-SHA comparison degenerates.

## Was the original R7 spike target the wrong file?

Yes. The original PR-D handoff text named runner.py:2627, :2658,
:2676 as LEDGER-SAFE comment sites. Those line numbers no longer
exist in the post-PR-#449 source — runner.py has been edited since.
The current LEDGER-SAFE comments are at lines 2648, 2716, 2747, 2765
(verified at SHA 6faeca171c). The behavior they document, however, is
unchanged.

## Proposed disposition

**No code fix required.** The SHA-reset is intentional, load-bearing
under documented invariants, and consistent between the two
implementations. Recommended follow-ups:

1. **Documentation refresh.** Re-anchor the LEDGER-SAFE comments
   from the handoff text to the current line numbers (2648, 2716,
   2747, 2765) when the next runner.py change touches them.
2. **De-duplicate.** The reset logic appears twice (dispatcher +
   runner init). Extract to a shared helper —
   `cycle_ledger.maybe_reset_cycle_for_sha_change(ledger, sha) -> int`
   — and call it from both sites. Defer to a separate cleanup PR;
   not blocking.
3. **No-op for the f148 epic.** R7 was originally framed as "the
   cycle-counter resets when it shouldn't." This spike confirms the
   opposite: it resets when it should. The framing should be retired,
   not implemented.

## Cycle-ledger interplay with PR #449 R1

R1 fixed the resolver to return the PR HEAD SHA on PR events. The
ledger then keys off that SHA correctly. Before R1, on
`pull_request` events, the resolver returned the synthesized
merge-commit SHA — meaning every CI re-run after a base-branch push
would see a "changed SHA" and reset the cycle, masquerading as
legitimate force-push behavior. R1 closed that, and the SHA-reset
logic now only fires on actual branch-tip changes.

Field-evidence: PR #449's llm-review log shows
`HEAD_SHA: 4bd4bc9962053027ebbf1499f08d664c913fc7a0` (the resolved PR
head) and no SHA-reset INFO line — cycle_number tracked normally
through dispatch.
