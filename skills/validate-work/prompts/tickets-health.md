# Tickets Health Sub-Agent Prompt

Validate ticket issue tracking health.
Do NOT fix any issues — only report findings.

## Config Keys Used

This prompt uses plugin scripts (`validate-issues.sh`, `tk`) which are inherently portable.
The orchestrator injects a `### Config Values` block with the plugin scripts directory.

| Config Key / Variable    | Purpose                                         | Required? |
|--------------------------|-------------------------------------------------|-----------|
| `PLUGIN_SCRIPTS_DIR`     | Absolute path to plugin scripts directory       | Yes       |

The orchestrator provides this as:
```
### Config Values
PLUGIN_SCRIPTS_DIR=<absolute path to plugin scripts directory>
```

Note: `tk` is a CLI command available in PATH — no config key needed.

## Commands to Run

1. `pwd`
2. `REPO_ROOT=$(git rev-parse --show-toplevel)`
3. Run the plugin's validate-issues.sh using the injected `PLUGIN_SCRIPTS_DIR`:
   ```bash
   "$PLUGIN_SCRIPTS_DIR/validate-issues.sh"
   ```

Also run these supplementary checks:
4. `tk ready`            (report open/in-progress issues with all deps resolved)
5. `tk blocked`          (report blocked issues)
6. `tk closed --limit=50` (report recently closed issues)

## Return

Return a structured summary of all findings. Do NOT fix anything.

Include:
- validate-issues.sh result: PASS/FAIL with details on any violations found
- Ready issues: count and list (issues unblocked and ready to work)
- Blocked issues: count and list (issues with unresolved deps)
- Recently closed: count (last 50 closed issues)
- Overall tickets health: PASS/FAIL
