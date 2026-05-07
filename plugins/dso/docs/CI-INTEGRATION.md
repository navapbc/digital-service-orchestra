# CI Integration

How the DSO plugin participates in CI: llm-review orchestration, version resolution, and the two-channel release model.

## CI llm-review orchestrator

`${CLAUDE_PLUGIN_ROOT}/scripts/dso_ci_review/` is a Python package; `ci-llm-review-runner.sh` is a 29-line shim that resolves `_PLUGIN_ROOT` and execs `python3 -m dso_ci_review.runner`. (`llm-api-call.sh` was deleted in S3.)

- Auto-detects local-checkout vs fetched-assets mode via marker file `${CLAUDE_PLUGIN_ROOT}/.dso-source-of-truth`.
- Parallel overlay dispatch (`&` fan-out + single `wait`).
- Does **not** consult `check-usage.sh` — CI is not subject to interactive throttling.

## CI version resolution (3-tier)

Host-project CI uses the local plugin checkout when the marker file is present; falls back to `dso` channel, then `dso-dev` channel.

## Two-channel release model

The plugin marketplace (`marketplace.json`) exposes two channels:

- `dso` — stable; pinned to a release tag after the first `scripts/release.sh` run.
- `dso-dev` — dev; pinned to `main` HEAD.

Advancing the stable channel requires running `scripts/release.sh` at the repo root, which enforces 10 precondition gates (semver validation, gh auth, tag uniqueness, on-main, clean tree, upstream sync, CI green, `validate.sh --ci`, marketplace.json validity, and interactive confirmation) before creating and pushing the release tag.

Consumers who want stability install `dso`; consumers who want every merge install `dso-dev`. See `VERSIONING.md` for the broader release discipline.

## Merge-to-main pipeline

Phases: `sync → merge → version_bump → validate → push → archive → ci_trigger`.

- PR mode (`merge.strategy=pr`) appends a `remediate` phase (bounded retry loop, per-tier ceiling=5, global ceiling=15; exit 2 = remediation exhaustion with escalation JSON on stdout; exit 1 = pre-remediation failure).
- State file: `/tmp/merge-to-main-state-<branch>.json` (4h TTL); `--resume` continues from checkpoint.
- See `CONFIGURATION-REFERENCE.md` for `merge.strategy` and `enforcement.strategy` keys.
