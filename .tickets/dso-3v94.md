---
id: dso-3v94
status: open
deps: []
links: []
created: 2026-03-18T22:36:45Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Recurring tool error: command_exit_nonzero (173 occurrences)

## Error Details

Showing most recent 20 of 173 occurrences.

| # | Timestamp | Tool | Input Summary | Error Message |
|---|-----------|------|---------------|---------------|
| 1 | 2026-03-18T21:28:32Z | Bash | Bash: command=PLUGIN_ROOT="/Users/joeoakhart/.claude/plugins/cache/digital-servi | Exit code 1\nERROR: diff hash mismatch — code changed between review dispatch and recording\n  Expected: ef6199bcd165... |
| 2 | 2026-03-18T21:32:34Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/plu | Exit code 1\nError: Could not load epic dso-ffzi |
| 3 | 2026-03-18T21:33:31Z | Bash | Bash: command=PLUGIN_SCRIPTS="/Users/joeoakhart/.claude/plugins/cache/digital-se | Exit code 1\nMAX_AGENTS: 5\nSESSION_USAGE: normal\nGIT_CLEAN: false\nGIT_DIRTY_FILES: 14\nDB_STATUS: skipped |
| 4 | 2026-03-18T21:35:50Z | Bash | Bash: command=ls /Users/joeoakhart/digital-service-orchestra/scripts/verify-revi | Exit code 1\n/Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/verify-review-diff.sh\n/Users/joeoakhart/di |
| 5 | 2026-03-18T21:36:49Z | Bash | Bash: command=ls /Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts | Exit code 1\n/Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/write-reviewer-findings.sh |
| 6 | 2026-03-18T21:37:11Z | Bash | Bash: command=PLUGIN_ROOT="/Users/joeoakhart/.claude/plugins/cache/digital-servi | Exit code 1\nERROR: diff hash mismatch — code changed between review dispatch and recording\n  Expected: 0d095efac3d5... |
| 7 | 2026-03-18T21:39:04Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/plu | Exit code 1\nERROR: Not a worktree. This script is for worktree sessions only. |
| 8 | 2026-03-18T21:39:33Z | Bash | Bash: command=ls /Users/joeoakhart/digital-service-orchestra/config/stack-adapte | Exit code 1\nflask-jinja2.yaml\n--- |
| 9 | 2026-03-18T21:39:58Z | Bash | Bash: command=REPO_ROOT=/Users/joeoakhart/digital-service-orchestra
cat <<'FINDI | Exit code 1\nSCHEMA_VALID: no (prompt-id=code-review-dispatch, schema-hash=6c0b61af0ff149ee)\nValidation errors:\n  - fi |
| 10 | 2026-03-18T21:40:18Z | Bash | Bash: command=bash plugins/dso/hooks/record-review.sh \
  --expected-hash "c5192 | Exit code 1\nERROR: reviewer findings files do not overlap with any changed files in the diff\nThis suggests the review  |
| 11 | 2026-03-18T21:40:44Z | Bash | Bash: command=ruff format --check tests/skills/test_implementation_plan_skill_td | Exit code 1\nWould reformat: tests/skills/test_implementation_plan_skill_tdd_enforcement.py\n1 file would be reformatted |
| 12 | 2026-03-18T21:47:52Z | Bash | Bash: command=REPO_ROOT=/Users/joeoakhart/digital-service-orchestra
cat <<'FINDI | Exit code 1\nSCHEMA_VALID: no (prompt-id=code-review-dispatch, schema-hash=6c0b61af0ff149ee)\nValidation errors:\n  - mi |
| 13 | 2026-03-18T21:52:07Z | Bash | Bash: command=cd /Users/joeoakhart/digital-service-orchestra
grep -n "checkpoint | Exit code 1\nnot in .gitignore |
| 14 | 2026-03-18T21:55:09Z | Bash | Bash: command=cd /Users/joeoakhart/digital-service-orchestra
REPO_ROOT=$(git rev | Exit code 1\nError: Could not load epic dso-ffzi |
| 15 | 2026-03-18T21:55:17Z | Bash | Bash: command=cd /Users/joeoakhart/digital-service-orchestra
# Try with the full | Exit code 1\nError: Could not load epic dso-ffzi |
| 16 | 2026-03-18T22:10:35Z | Bash | Bash: command=ARTIFACTS_DIR=/tmp/workflow-plugin-1a40ba26f6a56925
PLUGIN_ROOT=$( | Exit code 1\nreviewer_hash: 9cb3aab984809370\nERROR: unknown argument: --reviewer-hash=9cb3aab984809370\n\nUsage: record |
| 17 | 2026-03-18T22:20:08Z | Bash | Bash: command=/Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/ve | Exit code 1\nDIFF_VALID: no (could not extract hash from filename: review-diff-b72a1266d33dbe67.patch) |
| 18 | 2026-03-18T22:23:44Z | Bash | Bash: command=/Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/ve | Exit code 1\nDIFF_VALID: no (could not extract hash from filename: review-diff-1ac2777593a4d01f.patch) |
| 19 | 2026-03-18T22:29:49Z | Bash | Bash: command=git commit -m "$(cat <<'EOF'
fix(dso-anlb): fix doc path refs, rec | Exit code 129\nerror: unknown option `timeout'\nusage: git commit [-a \| --interactive \| --patch] [-s] [-v] [-u[<mode>] |
| 20 | 2026-03-18T22:32:41Z | Bash | Bash: command=/Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/ve | Exit code 1\nDIFF_VALID: no (could not extract hash from filename: review-diff-d935d5cec2d580da.patch) |

