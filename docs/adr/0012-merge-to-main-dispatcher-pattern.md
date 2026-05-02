# Dispatcher/Strategy Pattern for merge-to-main.sh

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-05-01

Technical Story: 4e55-a6ba-9619-4a13 (PR-merge mode and enforcement-strategy config: configurable merge-to-main with autonomous PR-comment resolution)

## Context and Problem Statement

`merge-to-main.sh` had grown to ~1009 lines. It hosts the entire end-to-end worktree-to-main merge workflow: pre-flight checks, sync phase, merge phase, version-bump phase, validate phase, push phase, archive phase, and CI-trigger phase, plus state-file management, lock acquisition, retry logic, and SIGURG-aware checkpointing. Adding a second merge mode (PR-based merge with autonomous PR-comment resolution, planned for epic 4e55-a6ba) would push the file past the point where any reviewer can hold the full control flow in mind.

Two requirements drive a structural split:

1. **Two genuinely distinct strategies coexist long-term.** Direct-merge mode (`git merge` + `git push`) and PR-merge mode (`gh pr create`, autonomous comment-resolution loop, `gh pr merge`) share the sync, validate, version-bump, archive, and CI-trigger phases but differ in the merge phase itself. Inlining both inside one script forces every reader to mentally track which `if [ "$STRATEGY" = "direct" ]` branch applies at each step.
2. **State-file portability across resume.** When `--resume` re-enters the workflow, the strategy that wrote the state file may differ from the strategy now configured (the user changed `merge.strategy` between runs). Letting one script silently honor whichever strategy the state file implies risks cross-strategy corruption (e.g., a direct-mode state file with a `pr_number` field a pr-mode resume would interpret as live).

A single monolithic script cannot satisfy these requirements without growing to ~2000 lines and accumulating per-branch defensive checks at every phase boundary.

## Decision Drivers

- Each strategy must be readable, testable, and reasonable about in isolation.
- The external interface (CLI flags, exit codes, output format, state-file location) must remain unchanged so consumers (sprint, end-session, the test suite, the plugin's host projects) continue to work without modification.
- `--resume` must reject a strategy mismatch loudly rather than silently honor a stale state file.
- Adding a future strategy (e.g., `merge.strategy=stacked-pr` for stacked-PR workflows) should require zero changes to the dispatcher.
- The dispatcher must be small enough that a reviewer can hold its full control flow in mind in one read.
- No new runtime dependency; the dispatch must work in any bash environment that previously ran `merge-to-main.sh`.

## Considered Options

- **Approach A: Thin dispatcher + per-strategy script.** Replace the monolithic file with `merge-to-main.sh` (a ~115-line dispatcher that reads `merge.strategy`, validates, and `exec`s `merge-to-main-{strategy}.sh`), `merge-to-main-direct.sh` (the relocated current implementation), and a separate file per future strategy.
- **Approach B: Library extraction.** Keep `merge-to-main.sh` monolithic but move shared phase functions into `hooks/lib/merge-helpers.sh`. Add an `if [ "$STRATEGY" = "pr" ]` branch at the merge phase to call the alternative implementation.
- **Approach C: Inline strategy table.** Define each strategy as a bash function (`_merge_direct`, `_merge_pr`) inside one file and pick based on a `STRATEGY` variable.

## Decision Outcome

Chosen option: **Approach A — thin dispatcher + per-strategy script.**

`merge-to-main.sh` becomes a small dispatcher with a single responsibility: read `merge.strategy` from `.claude/dso-config.conf`, validate the value, enforce cross-strategy `--resume` rejection, export `MERGE_STRATEGY` and `CLAUDE_PLUGIN_ROOT`, and `exec` the corresponding `merge-to-main-{strategy}.sh` with all original arguments forwarded.

The implementation file ownership is:

- `merge-to-main.sh` — dispatcher; reads strategy, validates, rejects cross-strategy resume, exec's strategy script.
- `merge-to-main-direct.sh` — direct-merge implementation (the relocated original 1009-line script). Owns: sync → merge → version_bump → validate → push → archive → ci_trigger phases for direct-merge mode.
- `merge-to-main-pr.sh` — pr-merge implementation (stub today; landed as part of epic 4e55-a6ba S3a).

The state file (`/tmp/merge-to-main-state-<branch>.json`) gains a `merge_strategy` field written by `merge-helpers.sh _state_init`. On `--resume`, the dispatcher reads the per-branch state file directly (not the most-recently-mtime'd file across all branches — that would let neighboring worktrees' state files trigger false-positive cross-strategy rejections), compares stored vs. configured strategy, and rejects on mismatch with both names in the error message so the user can decide whether to delete the state file or change the config.

Approach B was rejected because it leaves the per-strategy logic interleaved at the merge phase. Reviewers still have to mentally track strategy at every state-file write, every retry decision, every error path — the line-count win is real but the cognitive-load win is illusory.

Approach C was rejected because bash function dispatch inside one file does nothing to constrain the per-strategy code from leaking shared state, and a single 2000-line file is hard to navigate regardless of how it is internally factored.

### Cross-strategy --resume rejection

The cross-strategy check lives in the dispatcher, not in the strategy scripts, because the strategy scripts must not be reachable with a state file written by a different strategy. The check:

1. Resolves the current branch via `git -C "$REPO_ROOT" branch --show-current`.
2. Reads `/tmp/merge-to-main-state-${branch//\//-}.json` directly (not via mtime glob — see "alternatives considered" below).
3. Loads `merge_strategy` from the state file (default empty if absent).
4. Compares to the dispatcher-resolved current strategy.
5. Rejects with an error message naming both strategies if they disagree.
6. Special-cases the legacy migration window: a state file with no `merge_strategy` field is treated as `direct` (the only mode that existed before this split).

### Alternative considered: mtime-based state-file selection

The first implementation iteration of the dispatcher selected the state file by globbing `/tmp/merge-to-main-state-*.json` and picking the most recently modified. This was rejected during code review because state files are per-branch; the mtime selection let a worktree-A `--resume` read worktree-B's state file and produce a spurious cross-strategy mismatch. Per-branch resolution via `git branch --show-current` is the correct approach.

### CLAUDE_PLUGIN_ROOT propagation

The dispatcher derives `CLAUDE_PLUGIN_ROOT` from `dso.plugin_root` in `dso-config.conf` when the variable is unset in the environment. The strategy script enforces `: "${CLAUDE_PLUGIN_ROOT:?...}"` and would fail if the dispatcher set the variable without exporting it (after `exec`, only exported variables propagate). The dispatcher therefore explicitly `export`s `CLAUDE_PLUGIN_ROOT` after the existence check.

## Consequences

### Positive

- Each strategy is independently readable, testable, and reasonable about. The deep-tier code review treats each strategy script as a separate review target.
- The dispatcher is small (~115 lines) and the test suite for it (`tests/scripts/test-merge-to-main-dispatcher.sh`) covers the routing and cross-strategy rejection in isolation, without interacting with the heavyweight phase logic in `merge-to-main-direct.sh`.
- Adding a future strategy is purely additive: drop a new `merge-to-main-{strategy}.sh`, add the strategy name to the dispatcher's validator, and the `exec` routes to it. The dispatcher does not change.
- The state-file `merge_strategy` field provides a durable cross-resume audit trail and the foundation for any future strategy-specific state field (e.g., `pr_number` for pr mode).
- The external interface is unchanged: the same `--bump`, `--resume`, `--help` flags work identically; the same exit codes and output format flow back to consumers.

### Negative

- The hooks/lib library (`merge-helpers.sh`) is shared by both strategy scripts but only owned by the merge-to-main workflow. Boundary checks (`check-tickets-boundary`) had to add `merge-helpers.sh` to the allowlist explicitly — it inherits the same exemption that `merge-to-main.sh` had, but the inheritance had to be encoded.
- Several existing tests (`test-merge-to-main.sh`, `test-merge-to-main-cleanliness.sh`, `test-merge-to-main-config-driven.sh`, etc.) use grep/awk patterns against the implementation file. After the split, these tests had to redirect `MERGE_SCRIPT` from `merge-to-main.sh` to `merge-to-main-direct.sh`. The redirection is a structural fix, but the underlying source-grepping pattern is itself a change-detector smell — tracked for replacement with execution-based assertions in bug 0740-2df7.
- Stub `merge-to-main-pr.sh` exits non-zero with an explanatory message until S3a lands. Setting `merge.strategy=pr` before that point produces a controlled failure rather than silent fallback.

### Neutral

- Two files now live where one did. The split is justified by the strategy boundary, not by line count alone.

## Validation

- `tests/scripts/test-merge-to-main-dispatcher.sh` covers: routing to direct-strategy script, routing to pr-strategy script, unknown-strategy rejection, cross-strategy `--resume` rejection, and the contract that `_state_init` writes `merge_strategy` from the `MERGE_STRATEGY` environment variable.
- All pre-existing `merge-to-main` tests continue to pass against `merge-to-main-direct.sh` after redirection.
- Pre-commit boundary, lint, and review gates pass.
