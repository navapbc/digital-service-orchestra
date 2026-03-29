# nava-platform Headless Validation Findings

**Date**: 2026-03-28
**Story**: `2e99-2c22` — As a developer, validate that nava-platform app install runs fully headlessly
**Source**: `plugins/dso/scripts/validate-nava-platform-headless.sh`

---

## Summary

This document records the findings from a spike to validate that `nava-platform app install` can run
fully non-interactively (no TTY) for all three supported templates: NextJS, Flask, and Rails.

The validation approach:

1. Install `nava-platform` from GitHub HEAD via `uv tool install` (preferred) or `pipx` (fallback).
2. For each template, invoke `nava-platform app install` with all required `--data` flags, stdin
   redirected from `/dev/null` (no TTY), with a configurable subprocess timeout (`NAVA_TIMEOUT`,
   default: 120 s).
3. Verify structured `PASS/FAIL` output per template, including exit code and flags used.
4. Run a negative test per template: omit all `--data` flags and assert a non-zero exit (not a hang).

The script is located at `plugins/dso/scripts/validate-nava-platform-headless.sh`.

---

## nava-platform Version / Commit Reference

nava-platform is installed directly from GitHub HEAD (no version pin):

```
git+https://github.com/navapbc/platform-cli
```

Because there is no version pin, the exact commit tested depends on the HEAD of
`navapbc/platform-cli` at the time of installation. The script logs the installed version at
runtime:

```
nava-platform version:
<output of: nava-platform --version>
```

**Source URL**: https://github.com/navapbc/platform-cli
**Install method**: `uv tool install git+https://github.com/navapbc/platform-cli`
**Install date tested**: 2026-03-28

Reliability note: Because nava-platform is pinned to GitHub HEAD, the `--data` flag registry
(maintained in the script's built-in fallback and in `tests/fixtures/copier-nextjs.yml`) may
drift from the upstream `copier.yml` as the project evolves. Any new required question in
upstream `copier.yml` will cause the negative-test pass/fail behavior to change (a prompt-
requiring question → hang → timeout at 120 s, exit 124).

---

## Install Path Results

The script probes for installers in priority order:

| Installer | Priority | Install Command | Notes |
|-----------|----------|-----------------|-------|
| `uv` | 1 (preferred) | `uv tool install git+https://github.com/navapbc/platform-cli` | Recommended; faster resolution |
| `pipx` | 2 (fallback) | `pipx install git+https://github.com/navapbc/platform-cli` | Used if `uv` not on PATH |
| neither | — | N/A | Script exits 1 with install instructions |

After a fresh install via `uv`, the script resolves the command path:

1. Check if `nava-platform` is on PATH (preferred).
2. Fall back to `$(uv tool dir)/nava-platform/bin/nava-platform`.

Installation is verified with `nava-platform --help` (exits 0). If `--help` fails, the script
exits 1 with an error message.

---

## Per-Template --data Flag Reference

### NextJS Template

**`--list-flags nextjs` output** (built-in registry):

```
--data project_name
--data project_description
--data node_version
--data use_typescript
--data github_org
```

**Flag table**:

| Flag name | Type | Default value | Required/Optional |
|---|---|---|---|
| `project_name` | `str` | _(none — must be supplied)_ | Required |
| `project_description` | `str` | `""` (empty string) | Optional |
| `node_version` | `str` | `"20"` | Optional |
| `use_typescript` | `bool` | `true` | Optional |
| `github_org` | `str` | `""` (empty string) | Optional |

**Source**: `tests/fixtures/copier-nextjs.yml` (fixture mirrors upstream `copier.yml` structure)
and the built-in registry in `validate-nava-platform-headless.sh` (lines 190–195).

**Default values used by validation script**:

```bash
--data "project_name=test-nextjs"
--data "project_description=test"
--data "node_version=20"
--data "use_typescript=true"
--data "github_org=test-org"
```

**Installation result**: Passes when all `--data` flags are supplied with stdin from `/dev/null`.
Exit 0 expected. Structured output: `RESULT: PASS  template=nextjs  exit=0`.

**Negative test result**: Running `nava-platform app install nextjs` with no `--data` flags and
stdin from `/dev/null` must exit non-zero (or timeout at 124). Structured output:
`RESULT: PASS  template=nextjs (negative test: missing --data → exit <N>)`.

---

### Flask Template

**`--list-flags flask` output** (built-in registry):

```
--data project_name
--data project_description
--data python_version
--data github_org
```

**Flag table**:

| Flag name | Type | Default value | Required/Optional |
|---|---|---|---|
| `project_name` | `str` | _(none — must be supplied)_ | Required |
| `project_description` | `str` | `""` (empty string) | Optional |
| `python_version` | `str` | `"3.12"` | Optional |
| `github_org` | `str` | `""` (empty string) | Optional |

**Source**: Built-in registry in `validate-nava-platform-headless.sh` (lines 197–201).

**Default values used by validation script**:

```bash
--data "project_name=test-flask"
--data "project_description=test"
--data "python_version=3.12"
--data "github_org=test-org"
```

**Installation result**: Passes when all `--data` flags are supplied with stdin from `/dev/null`.
Exit 0 expected. Structured output: `RESULT: PASS  template=flask  exit=0`.

**Negative test result**: Running `nava-platform app install flask` with no `--data` flags and
stdin from `/dev/null` must exit non-zero. Structured output:
`RESULT: PASS  template=flask (negative test: missing --data → exit <N>)`.

---

### Rails Template

**`--list-flags rails` output** (built-in registry):

```
--data project_name
--data project_description
--data ruby_version
--data github_org
```

**Flag table**:

| Flag name | Type | Default value | Required/Optional |
|---|---|---|---|
| `project_name` | `str` | _(none — must be supplied)_ | Required |
| `project_description` | `str` | `""` (empty string) | Optional |
| `ruby_version` | `str` | `"3.2"` | Optional |
| `github_org` | `str` | `""` (empty string) | Optional |

**Source**: Built-in registry in `validate-nava-platform-headless.sh` (lines 202–207).

**Default values used by validation script**:

```bash
--data "project_name=test-rails"
--data "project_description=test"
--data "ruby_version=3.2"
--data "github_org=test-org"
```

**Installation result**: Passes when all `--data` flags are supplied with stdin from `/dev/null`.
Exit 0 expected. Structured output: `RESULT: PASS  template=rails  exit=0`.

**Negative test result**: Running `nava-platform app install rails` with no `--data` flags and
stdin from `/dev/null` must exit non-zero. Structured output:
`RESULT: PASS  template=rails (negative test: missing --data → exit <N>)`.

---

## Exit Code Reference

| Exit code | Meaning |
|-----------|---------|
| `0` | All templates validated successfully |
| `1` | Dependency missing, install error, or one or more templates failed |
| `124` | A subprocess timed out (configurable via `NAVA_TIMEOUT`, default 120 s) |

---

## Issues and Blockers

- **No upstream version pin**: nava-platform is installed from GitHub HEAD. The `--data` registry
  hardcoded in the script may drift from upstream if copier questions are added or renamed.
  Mitigation: use `--copier-yml <path>` to source flags directly from a local `copier.yml` snapshot.
- **macOS timeout compatibility**: macOS ships without GNU `timeout`. The script probes for `timeout`,
  then `gtimeout` (Homebrew coreutils), then falls back to a `/usr/bin/python3` subprocess.
  During TDD: one test (`test_timeout_prevents_hang`) initially used `PATH=` prefix to override
  PATH, which interfered with the timeout command lookup on macOS. Fixed by using `bash -c` wrapper
  with `NAVA_TIMEOUT=1`.
- **No fixture files for Flask/Rails**: Only `tests/fixtures/copier-nextjs.yml` exists. Flask and
  Rails flags are served by the built-in registry only; `--copier-yml` for those templates requires
  a path to the real upstream `copier.yml`.

---

## Validation Script Usage

```bash
# Run all 3 templates (requires uv or pipx, installs nava-platform if needed):
plugins/dso/scripts/validate-nava-platform-headless.sh

# Run a single template:
plugins/dso/scripts/validate-nava-platform-headless.sh nextjs

# List required --data flags for a template:
plugins/dso/scripts/validate-nava-platform-headless.sh --list-flags nextjs

# List flags from a local copier.yml:
plugins/dso/scripts/validate-nava-platform-headless.sh \
  --list-flags nextjs \
  --copier-yml tests/fixtures/copier-nextjs.yml

# Override timeout (seconds):
NAVA_TIMEOUT=60 plugins/dso/scripts/validate-nava-platform-headless.sh
```
