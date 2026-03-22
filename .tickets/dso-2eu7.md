---
id: dso-2eu7
status: in_progress
deps: []
links: []
created: 2026-03-22T15:15:24Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-jtkr
---
# Add review.behavioral_patterns key to .claude/dso-config.conf

Add the review.behavioral_patterns configuration key to .claude/dso-config.conf.

## Purpose

The classifier reads this key at runtime to identify which files are 'behavioral' (agent instructions that must receive full scoring weight identical to source code). Without this key, the classifier cannot distinguish behavioral files from ordinary docs.

## Implementation Steps

1. Open .claude/dso-config.conf
2. Add the following section after the existing config keys:

```
# Review tier routing — behavioral file classification
# Semicolon-delimited glob list of file patterns to treat as behavioral (full scoring weight).
# Default value below covers all DSO plugin behavioral files.
review.behavioral_patterns=plugins/dso/skills/**;plugins/dso/hooks/**;plugins/dso/docs/workflows/**;plugins/dso/docs/prompts/**;plugins/dso/commands/**;plugins/dso/scripts/**;CLAUDE.md;.claude/**
```

## TDD Requirement

No RED test required — this task modifies only a static config file with no conditional logic or branching. Exemption: Unit exemption criterion 3 (static assets only — a flat KEY=VALUE config file has no executable assertions possible at the config level; behavioral validation is in the classifier's test suite via T1/T2).

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/tests/run-all.sh"
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && cd "$REPO_ROOT" && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && cd "$REPO_ROOT" && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] review.behavioral_patterns key present in .claude/dso-config.conf
  Verify: grep -q 'review.behavioral_patterns' $(git rev-parse --show-toplevel)/.claude/dso-config.conf
- [ ] Value contains all 8 default glob patterns (skills, hooks, workflows, prompts, commands, scripts, CLAUDE.md, .claude/**)
  Verify: grep 'review.behavioral_patterns' $(git rev-parse --show-toplevel)/.claude/dso-config.conf | grep -q 'plugins/dso/skills'
- [ ] read-config.sh can read the key value
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/read-config.sh review.behavioral_patterns | grep -q 'plugins/dso/skills'


## Notes

<!-- note-id: od4ty14m -->
<!-- timestamp: 2026-03-22T15:22:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: cbvlobk7 -->
<!-- timestamp: 2026-03-22T15:22:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: vys82r30 -->
<!-- timestamp: 2026-03-22T15:24:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ (none required — static config file, exemption criterion 3 applies)

<!-- note-id: uw9cat57 -->
<!-- timestamp: 2026-03-22T15:24:34Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: tvthqqki -->
<!-- timestamp: 2026-03-22T15:24:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: gghoxe3o -->
<!-- timestamp: 2026-03-22T15:29:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All 6 ACs pass: key present, 8 globs present, read-config.sh reads it, ruff format/lint clean, tests pass (exit 0)
