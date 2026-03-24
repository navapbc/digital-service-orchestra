# Versioning Guide — Digital Service Orchestra

## Semver Convention

This plugin follows [Semantic Versioning](https://semver.org/): **MAJOR.MINOR.PATCH**

Examples: `0.2.0`, `1.0.0`, `1.3.2`

## Tag Format

All release tags use the `'v'` prefix:

```
v<MAJOR>.<MINOR>.<PATCH>
```

Examples: `v0.2.0`, `v1.0.0` — **not** `0.2.0` or `0.2`.

The `'v'` prefix is required. Tools and scripts in this repo (e.g., `.claude/scripts/dso tag-release.sh`) enforce this convention.

## Breaking Change Policy

| Change Type | Version Bump | Examples |
|-------------|-------------|---------|
| Breaking API change | **MAJOR** | `hooks.json` event contract changes; `plugin.json` schema changes incompatibly; required config keys renamed or removed |
| New capability | **MINOR** | New skills added; new scripts; new optional config keys; backward-compatible hook changes |
| Bug fix or patch | **PATCH** | Fixes to existing scripts; documentation corrections; minor behavior corrections |

### What Counts as a Breaking Change

- Removing or renaming an event name in `hooks.json`
- Changing the required fields in `plugin.json` in a way that breaks existing consumers
- Removing a skill or script that consuming projects may depend on
- Renaming a config key that was previously documented as stable

## Current Version

The authoritative version is stored in `plugin.json` and `marketplace.json` at the plugin root:

```json
{
  "version": "0.2.0"
}
```

Both files must stay in sync. Use `.claude/scripts/dso tag-release.sh` to update both at once.

## Consuming Project Pinning

Consuming projects can pin to a specific version by referencing the git tag when installing:

```bash
# Pin to a specific release tag
claude plugin install github:navapbc/digital-service-orchestra@v0.2.0

# Pin to a branch (tracks latest on that branch — not recommended for production)
claude plugin install github:navapbc/digital-service-orchestra@main
```

For reproducible environments, pin to a specific tag rather than a branch. Record the pinned version in your project's `CLAUDE.md` or a lockfile equivalent.

## Release Workflow

### Patch Bumps (automated, merge-time)

Patch version bumps happen automatically during the `merge-to-main.sh` workflow when `version.file_path` is configured in `.claude/dso-config.conf` and `--bump` is passed (or bump mode is on). The `version_bump` phase (between `merge` and `validate`) runs `bump-version.sh --patch` — no manual commit step is required.

### Minor and Major Releases (manual, via tag-release.sh)

For MINOR and MAJOR version bumps (new capabilities or breaking changes), use the standalone `tag-release.sh` workflow:

1. Determine the next version per the policy above.
2. Run `.claude/scripts/dso tag-release.sh <VERSION>` — this updates `plugin.json` and `marketplace.json` and prints the `git tag` command.
3. Commit the version bump (`git commit -m "chore: bump version to vX.Y.Z"`).
4. Run the printed `git tag` command to create the annotated tag.
5. Push both the commit and the tag: `git push && git push --tags`.
6. Add a new entry to `CHANGELOG.md` documenting the release.
