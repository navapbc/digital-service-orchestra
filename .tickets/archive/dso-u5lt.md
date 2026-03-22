---
id: dso-u5lt
status: closed
deps: []
links: []
created: 2026-03-21T00:15:26Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: w22-ns6l
---
# COMMIT-WORKFLOW.md uses CLAUDE_PLUGIN_ROOT without fallback for unset env var

COMMIT-WORKFLOW.md Step 0 references ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh but CLAUDE_PLUGIN_ROOT is not always set (e.g., when running commit workflow manually or in environments where Claude Code hasn't set it). When unset, the path resolves to /hooks/lib/deps.sh which fails with exit 127. Should fall back to discovering the plugin root from dso-config.conf or git rev-parse.


## Notes

<!-- note-id: s6oxeiia -->
<!-- timestamp: 2026-03-21T00:17:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Also affects compute-diff-hash.sh (line 42: CLAUDE_PLUGIN_ROOT: unbound variable) and capture-review-diff.sh invocation. The issue is pervasive across all scripts that use CLAUDE_PLUGIN_ROOT without fallback — not just COMMIT-WORKFLOW.md.

**2026-03-22T07:51:04Z**

SAFEGUARDED: fix requires editing protected file(s): plugins/dso/docs/workflows/COMMIT-WORKFLOW.md, possibly plugins/dso/scripts/ (compute-diff-hash.sh, capture-review-diff.sh)

**2026-03-22T07:51:11Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.

**2026-03-22T15:24:44Z**

SAFEGUARD APPROVED: user approved editing plugins/dso/docs/workflows/COMMIT-WORKFLOW.md. Proposed fix: add CLAUDE_PLUGIN_ROOT fallback resolution using dso-config.conf lookup at lines 38-39 and 323-324.

**2026-03-22T15:27:46Z**

Fixed: Added CLAUDE_PLUGIN_ROOT fallback resolution at both Step 0 (Breadcrumb Init) and Step 3a (Write Validation State File) in COMMIT-WORKFLOW.md. Fallback order: (1) existing CLAUDE_PLUGIN_ROOT env var, (2) dso.plugin_root from .claude/dso-config.conf, (3) $REPO_ROOT/plugins/dso. Matches the resolution pattern used in the .claude/scripts/dso shim. The line 178 reference in Step 1 test-failure-dispatch is documentation prose only, not executable code — no change needed there.

**2026-03-22T15:42:07Z**

Fixed: added CLAUDE_PLUGIN_ROOT fallback in COMMIT-WORKFLOW.md at Step 0 and Step 3a
