---
id: dso-4g8u
status: closed
deps: []
links: []
created: 2026-03-17T23:33:18Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Automatic Plugin Version Bumping


## Notes

**2026-03-17T23:33:25Z**


## Context
Plugin consumers (Claude Code projects using the DSO plugin) rely on the version field in the plugin's version file to detect when new plugin code is available. When a consumer runs `/plugin`, it compares the installed version against the source — but currently, version updates are manual and easy to forget, leading to consumers running stale plugin code without knowing it. As the plugin is under rapid iteration, an automated versioning strategy is needed that keeps version numbers meaningful without creating commit noise.

## Success Criteria
- `scripts/bump-version.sh` accepts `--patch`, `--minor`, `--major` flags; reads the version file path from `workflow-config.conf` key `version.file_path`; exits 0 on success, non-zero on error
- If `version.file_path` is not set in `workflow-config.conf`, the script exits cleanly with no changes (skip behavior, not an error)
- File format is auto-detected from the version file's extension: `.json` parses and writes the `version` key; `.toml` parses and writes the `version` field; files with no extension or `.txt` treat the file as a single semver line
- Patch version increments automatically when committing code changes outside of `/sprint` via the commit workflow; the commit workflow includes explicit guidance to skip version bumping when running within `/sprint`
- Minor version increments automatically at epic completion during `/sprint`, resetting patch to 0
- Major version changes remain a manual-only process
- The test suite covers all three supported file formats and the no-config skip behavior, verifying correct pre/post version values for each bump type

## Dependencies
None

## Approach
Create `scripts/bump-version.sh` with format auto-detection and semver parsing. Integrate patch bumps into the commit workflow (with skip-during-sprint guidance) and minor bumps into the sprint skill's epic completion step. This project sets `version.file_path=.claude-plugin/plugin.json` in its own `workflow-config.conf`.

