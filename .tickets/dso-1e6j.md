---
id: dso-1e6j
status: in_progress
deps: []
links: []
created: 2026-03-17T23:38:32Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-4g8u
---
# As a plugin developer, I can run scripts/bump-version.sh to increment a semver version in any configured version file


## Notes

**2026-03-17T23:38:55Z**


**What:** Create `scripts/bump-version.sh` — the core version bumping script that all other stories depend on.

**Why:** Provides the single source of truth for all version bump logic. Without this script, the commit workflow and sprint skill integrations cannot function.

**Scope:**
- IN: New script accepting `--patch`, `--minor`, `--major` flags. Reads `version.file_path` from `workflow-config.conf`. Auto-detects file format from extension: `.json` → writes `"version"` key; `.toml` → writes `version` field; no extension or `.txt` → single semver line. Exits 0 cleanly with no changes if `version.file_path` is not configured. Exits non-zero on malformed files.
- OUT: Setting `version.file_path` for any specific project (Story dso-h7su). Workflow integrations (Stories dso-bvna, dso-hsuo).

**Done Definitions:**
- When complete, `bash scripts/bump-version.sh --patch` increments the patch component of the semver in the configured version file
  ← Satisfies: "scripts/bump-version.sh accepts --patch, --minor, --major flags; exits 0 on success"
- When complete, running the script with no `version.file_path` configured in `workflow-config.conf` exits 0 with no file changes
  ← Satisfies: "If version.file_path is not set, exits cleanly with no changes"
- When complete, the script correctly parses and writes semver for .json, .toml, and plaintext version files
  ← Satisfies: "File format is auto-detected from the version file's extension"
- When complete, if `version.file_path` is configured but the target file does not exist, the script exits non-zero with a clear error message
  ← Satisfies: error handling requirement
- When complete, the test suite passes for all three formats, the no-config skip case, and malformed-file error cases
  ← Satisfies: "The test suite covers all three supported file formats and the no-config skip behavior"

**Considerations:**
- [Testing] Three distinct format parsers — test all formats (valid input, malformed input, boundary cases) and skip behavior
- [Reliability] Script must exit non-zero on malformed files rather than corrupting them; must never corrupt a valid file on error


**2026-03-17T23:51:59Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-17T23:52:21Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-17T23:53:19Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-17T23:54:02Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-18T00:24:22Z**

CHECKPOINT 5/6: Validation passed ✓ — test-bump-version.sh: 21 passed, 0 failed. Pre-existing failures (8) in test-flat-config-e2e.sh, test-pre-commit-wrapper.sh, test-read-config-flat.sh, test-smoke-test-portable.sh confirmed pre-existing (same count without my changes).

**2026-03-18T00:24:31Z**

CHECKPOINT 6/6: Done ✓ — All 5 AC verified: (1) --patch/--minor/--major flags work ✓ (2) no version.file_path → exit 0 ✓ (3) .json/.toml/plaintext formats ✓ (4) file not found → exits non-zero ✓ (5) test suite 21/21 ✓
