---
id: dso-q523
status: in_progress
deps: []
links: []
created: 2026-03-17T23:47:32Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# validate.sh hardcodes app/ directory — should pull project-specific paths from config


## Notes

**2026-03-17T23:47:39Z**

validate.sh line 611 does 'cd app/' which fails when run from the DSO plugin repo itself (no app/ dir). It should pull the app directory from workflow-config.conf (e.g., paths.app_dir) instead of hardcoding 'app/'. Similarly, commands like make format-check, make lint, make test-unit-only should use the config keys commands.test, commands.lint, commands.format_check from workflow-config.conf. Error: 'cd: /Users/joeoakhart/digital-service-orchestra/app: No such file or directory'

## File Impact
- `scripts/validate.sh` - Primary file to modify: remove hardcoded `app/` directory path and implement config-based path resolution from workflow-config.conf
- `scripts/check-script-writes.py` - May need updates to validate the new config-based path handling in validate.sh
- `tests/scripts/test_check_file_syntax.py` - Add/update tests for validate.sh config resolution
- `tests/plugin/test_fixture_minimal_plugin_consumer.py` - Verify plugin can run validate.sh with its own config paths
- `tests/plugin/test_component_discovery_schema.py` - Ensure workflow-config.conf schema includes new path and command config keys

**2026-03-18T18:58:12Z**

CHECKPOINT 1/6: Read validate.sh and workflow-config.conf. Confirmed config key mismatches: commands.lint_ruff, commands.lint_mypy, commands.syntax_check, commands.test_plugin are not in workflow-config.conf. paths.app_dir is also missing. All existing tests pass (GREEN baseline).

**2026-03-18T18:58:41Z**

CHECKPOINT 2/6: RED tests confirmed - 5 new tests fail as expected. Now applying fix to workflow-config.conf.
