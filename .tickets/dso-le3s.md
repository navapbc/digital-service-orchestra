---
id: dso-le3s
status: in_progress
deps: [dso-ozsx, dso-n458]
links: []
created: 2026-03-20T00:43:06Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-6576
---
# DOC: Update CONFIGURATION-REFERENCE.md to document ci.workflow_name and deprecate merge.ci_workflow_name

Update plugins/dso/docs/CONFIGURATION-REFERENCE.md to document ci.workflow_name as the canonical key and mark merge.ci_workflow_name as deprecated.

TDD EXEMPTION: This task modifies only Markdown documentation. No executable conditional logic is added. Criterion 3: 'modifies only static assets (Markdown documentation)'.

IMPLEMENTATION STEPS:
1. Find the ci.* section in CONFIGURATION-REFERENCE.md (ci.fast_gate_job, ci.fast_fail_job, etc.) and add a new ci.workflow_name entry after ci.integration_workflow:

   ### `ci.workflow_name`
   | | |
   |---|---|
   | **Description** | GitHub Actions workflow name for `gh workflow run`. Used by `merge-to-main.sh` for post-push CI trigger recovery. Consolidated from the deprecated `merge.ci_workflow_name`. When absent, post-push CI trigger recovery is skipped. |
   | **Accepted values** | Exact workflow name string (e.g., `CI`, `Build and Test`) |
   | **Default** | Absent — CI trigger recovery skipped |
   | **Used by** | `.claude/scripts/dso merge-to-main.sh` |
   | **Migration** | If you have `merge.ci_workflow_name` set, move the value to `ci.workflow_name` and remove the old key. |

2. Find the merge.ci_workflow_name section and add a deprecation notice:

   > **DEPRECATED**: This key is deprecated in favor of `ci.workflow_name`. `merge-to-main.sh` reads `ci.workflow_name` first and falls back to `merge.ci_workflow_name` with a deprecation warning. Migrate by moving the value to `ci.workflow_name`.

FILE: plugins/dso/docs/CONFIGURATION-REFERENCE.md (edit — add ci.workflow_name entry, mark merge.ci_workflow_name deprecated)


## ACCEPTANCE CRITERIA

- [ ] ci.workflow_name has a dedicated section in CONFIGURATION-REFERENCE.md
  Verify: grep -q '### `ci.workflow_name`' $(git rev-parse --show-toplevel)/plugins/dso/docs/CONFIGURATION-REFERENCE.md
- [ ] merge.ci_workflow_name section contains a deprecation notice
  Verify: grep -A5 '### `merge.ci_workflow_name`' $(git rev-parse --show-toplevel)/plugins/dso/docs/CONFIGURATION-REFERENCE.md | grep -qi 'deprecated\|deprecat'
- [ ] ci.workflow_name section mentions migration path from merge.ci_workflow_name
  Verify: grep -A10 '### `ci.workflow_name`' $(git rev-parse --show-toplevel)/plugins/dso/docs/CONFIGURATION-REFERENCE.md | grep -qi 'migration\|migrate\|merge\.ci_workflow_name'
- [ ] CONFIGURATION-REFERENCE.md is valid Markdown (no broken section headers)
  Verify: grep -c '^### ' $(git rev-parse --show-toplevel)/plugins/dso/docs/CONFIGURATION-REFERENCE.md | awk '{exit ($1 < 5)}'

## Notes

<!-- note-id: ur2qw3t1 -->
<!-- timestamp: 2026-03-20T01:59:59Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: n49xdqry -->
<!-- timestamp: 2026-03-20T02:00:03Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: fhd72ts3 -->
<!-- timestamp: 2026-03-20T02:00:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required) ✓

<!-- note-id: 4ir4kems -->
<!-- timestamp: 2026-03-20T02:00:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: vu0mza44 -->
<!-- timestamp: 2026-03-20T02:03:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ (check-skill-refs: 0, docs-only change, validate.sh hit SIGURG ceiling as documented in CLAUDE.md)

<!-- note-id: lvhsm7zy -->
<!-- timestamp: 2026-03-20T02:03:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — ci.workflow_name expanded with description, default, used-by, example values (CI/Build and Test/Run Tests), and migration steps. merge.ci_workflow_name updated with exact deprecation warning text from script, fallback-only used-by note, and one-line migration summary. Both entries cross-reference each other.
