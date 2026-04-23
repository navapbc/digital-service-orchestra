# create-dso-app ↔ DSO NextJS Template — Interface Contract

This document is the canonical contract between the `create-dso-app.sh`
installer (in this repo, `scripts/create-dso-app.sh`) and the DSO NextJS
template repo (`navapbc/digital-service-orchestra-nextjs-template`). When
either side changes its interface, both sides must be updated and this
document must be updated to match.

Audit owner: any change to either side must re-run the audit at the bottom
of this file.

## Interface surfaces

There are four interface surfaces. Each must agree across the installer and
the template, and each is verified by the audit.

### 1. Template repository URL

The installer hard-codes the template repo URL:

```
scripts/create-dso-app.sh:265
  local repo_url="https://github.com/navapbc/digital-service-orchestra-nextjs-template"
```

The actual template repo lives at the same URL:
<https://github.com/navapbc/digital-service-orchestra-nextjs-template>

Verification:
```
grep -n 'github.com/navapbc/digital-service-orchestra-nextjs-template' \
  scripts/create-dso-app.sh
gh repo view navapbc/digital-service-orchestra-nextjs-template \
  --json visibility -q .visibility   # expected: PUBLIC
```

### 2. Placeholder substitution

The installer substitutes the literal token `{{PROJECT_NAME}}` with the
sanitized project name:

```
scripts/create-dso-app.sh:396-419
  files_with_placeholder="$(grep -rl '{{PROJECT_NAME}}' "$project_dir" 2>/dev/null || true)"
  ...
  sed -i '' "s/{{PROJECT_NAME}}/$sanitized_name/g" "$file"
```

The template uses `{{PROJECT_NAME}}` at every substitution point. As of
the most recent audit, the placeholder appears in:

| File | Substitution point |
|------|--------------------|
| `package.json` | `"name": "{{PROJECT_NAME}}"` |
| `README.md` | Title, scaffolding references |
| `CLAUDE.md` | Project name throughout |
| `project-understanding.md` | Title and references |
| `design-notes.md` | Title and references |
| `.claude/ARCH_ENFORCEMENT.md` | Title and references |
| `.claude/dso-config.conf` | Comment header |
| `.pre-commit-config.yaml` | Comment header |
| `.github/workflows/ci.yml` | Workflow comment header |
| `SECURITY.md` | (no substitution; static) |
| `NOTICE` | (no substitution; static) |

Verification (run inside a fresh clone of the template after substitution):
```
SANITIZED=demo-proto
grep -rl '{{PROJECT_NAME}}' . --exclude-dir=.git \
  | xargs sed -i '' "s/{{PROJECT_NAME}}/$SANITIZED/g"
# Expect zero residual matches outside .git/:
grep -r '{{PROJECT_NAME}}' . --exclude-dir=.git
```

The installer-side path uses `sed -i ''` on macOS (BSD sed) and `sed -i`
on Linux (GNU sed); both are exercised by the auto-detect block at
`scripts/create-dso-app.sh:407-414`.

**Sanitization rules** (`sanitize_project_name`, line 240):
- Replace ` `, `/`, `\`, `$`, `*`, `?`, `[`, `]`, `^` with `-`
- Strip any other non-alphanumeric, non-`_-` characters
- Collapse runs of `-` into single `-`
- Strip leading and trailing `-`
- Empty result is a fatal error

The template does not depend on any specific sanitization output beyond
"file-system-safe characters". Any rule the installer enforces is fine
provided the resulting string is a valid npm `name` field (lowercase
recommended, no spaces, no glob characters).

### 3. Post-clone steps and template layout

The installer's post-clone sequence:

| Step | Installer code | Template requirement |
|------|----------------|----------------------|
| Clone with `--no-single-branch` | line 383 | template MUST publish a `tickets` orphan branch reachable via `git ls-remote` (✓ commit `1c736bf`) |
| Substitute `{{PROJECT_NAME}}` | line 396-419 | template MUST use `{{PROJECT_NAME}}` token (no other placeholder convention) |
| `npm install --prefix "$project_dir"` | line 425 | template MUST have a `package.json` at root with valid `dependencies`/`devDependencies` such that `npm install` succeeds with no nava-platform tooling installed (epic SC2(f)) |
| `detect_dso_plugin_root "$project_dir"` | line 433 | template MUST ship `.claude/dso-config.conf` with an empty `dso.plugin_root=` line so the installer can populate it (epic SC3) |
| Run `dso-setup.sh` (if found) | line 436-440 | template MUST already ship CLAUDE.md, .pre-commit-config.yaml, .github/workflows/ci.yml so dso-setup.sh skips the "create-if-absent" branches (epic SC3) |
| Write `.dso-init-complete` sentinel | line 447 | (no template requirement) |
| `cd "$project_dir" && exec claude` | line 458 | template MUST be a directory the user can launch Claude Code from with no manual setup |

### 4. Test fixture expectations

The installer's behavioural test (`tests/scripts/test-create-dso-app.sh`)
uses a stubbed `git` binary that creates a minimal project structure. The
stub MUST mirror the real template's structure on the points it asserts:

| Assertion | Real template state |
|-----------|---------------------|
| `package.json` at root | ✓ present at root with `"name": "{{PROJECT_NAME}}"` |
| `src/app/` (App Router with `src/` convention) OR `app/` OR `pages/` | ✓ template uses `src/app/` |
| `.claude/` directory OR `CLAUDE.md` at root | ✓ both are present in template |
| `.dso-init-complete` sentinel after success | ✓ written by installer, not template |

The stub previously created `app/` at the project root, which did not
match the real template's `src/app/` layout. The 2026-04-19 audit corrected
both the stub (to create `src/app/`) and the assertion (to accept all three
valid Next.js layouts) so the test fixture continues to verify a layout
that exists in the real template — not just the stub's invented one.

## Audit log

### 2026-04-19 — Initial audit (story b7e3-1280)

| Surface | Verdict | Action taken |
|---------|---------|--------------|
| 1. Template URL | ✓ matches | none |
| 2. Placeholder | ✓ matches | none |
| 3. Post-clone steps | ✓ matches | none |
| 4. Test fixture | ✗ stub created `app/` at root; real template uses `src/app/` | Fixed in-PR: updated stub and assertion in `tests/scripts/test-create-dso-app.sh`. No separate bug filed — fix is trivial and lands with the contract doc. |

### SC2 strip-list grep — NOTICE exclusion

Epic SC2(a) reads:

> `git grep -E 'nava-platform|\.copier-answers|^copier\.yml$|template-only-(bin|docs)|code\.json'` returns zero hits in tracked files.

The Apache-2.0 NOTICE file (delivered by story `ac74-2505`) necessarily
enumerates the stripped upstream artifacts as part of §4 attribution
("modifications made"). The verbatim grep above will match NOTICE for
that reason — but the SC2 *intent* is "no nava-platform tooling remains
in the source tree", not "the strip cannot be documented". Documentation
referencing stripped artifacts is exempt.

The real-URL e2e test in `tests/scripts/test-create-dso-app-real-url.sh`
implements this with the canonical pathspec exclusion:

```
git grep -E '<pattern>' -- ':!NOTICE'
```

Apply the same exclusion when running the SC2 grep verification by hand.

Real-URL end-to-end validation (the missing piece per bug `068c-1e8a` and
epic SC7) is delivered by story `6bf8-858d` (Real-URL e2e installer
validation). That story exercises this contract end-to-end against the
published template repo without PATH-stubbing.

## Maintenance

Add a new audit entry (date + table) every time:
- The installer's URL, placeholder, post-clone steps, or test fixture changes
- The template's structure, placeholder set, or shipped DSO infra changes
- A new SC is added to the parent epic that involves the template-installer interface

Consider adding a CI check that fails if either side changes without an
audit entry on the same date — tracked as a future enhancement (not in
scope for the current epic).
