---
id: dso-5syi
status: closed
deps: []
links: []
created: 2026-03-19T00:47:30Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-53
parent: dso-9xnr
---
# Fix: dso shim resolves scripts from stale /scripts/ path — skip-review-check.sh and capture-review-diff.sh not found during commit workflow

During commit workflow execution, the .claude/scripts/dso shim fails to locate several scripts because it resolves CLAUDE_PLUGIN_ROOT/scripts/ (the pre-extraction path) instead of CLAUDE_PLUGIN_ROOT/plugins/dso/scripts/. Affected scripts: skip-review-check.sh (Step 0.5), capture-review-diff.sh (Review Step 2), write-reviewer-findings.sh. Workaround was direct bash invocations using the full plugin path (bash ${CLAUDE_PLUGIN_ROOT}/plugins/dso/scripts/<script>). The dso shim itself appears to have a hardcoded or config-resolved scripts lookup path that predates the dso plugin extraction into plugins/dso/. Resolution: update the dso shim's script resolution logic to use CLAUDE_PLUGIN_ROOT/plugins/dso/scripts/ as the lookup path.


## Notes

<!-- note-id: 1o4gq0u1 -->
<!-- timestamp: 2026-03-21T00:16:55Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: dso shim at .claude/scripts/dso line 69 correctly resolves SCRIPT_PATH=$DSO_ROOT/scripts/$CMD; dso-config.conf sets dso.plugin_root=plugins/dso so the path resolves correctly; test-skip-review-check.sh and test-stale-script-path-refs.sh pass
