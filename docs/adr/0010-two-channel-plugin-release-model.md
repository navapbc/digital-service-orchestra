# Two-Channel Plugin Release Model (Stable + Dev)

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-04-18

Technical Story: epic 36a7-dbb5, story e56b-efc7

## Context and Problem Statement

The DSO plugin is distributed via a `marketplace.json` manifest. Before this decision, the marketplace contained a single plugin entry (`dso`) pinned to main HEAD via `git-subdir`. This meant that every merge to main — including in-progress work, experimental features, and partially-baked epics — was immediately propagated to all consuming projects on their next `update-artifacts` run.

Consuming projects had no way to opt into a known-stable state short of pinning a specific commit SHA manually in their local installation, which required manual coordination and was not surfaced in the standard tooling.

Two failure modes drove this decision:
1. **Consumers broken by mid-sprint merges**: a consuming project running `update-artifacts` mid-sprint would receive half-complete feature implementations.
2. **No stable release signal**: there was no artifact that stated "this is a tested, complete release", making it impossible for consuming projects to reason about stability guarantees.

## Decision Drivers

- Consuming projects must be able to install a stable, tested version without tracking main HEAD.
- Maintainers must retain the ability to move fast on main without forcing stability discipline on every commit.
- The release process must enforce quality gates rather than relying on developer discipline alone.
- The two channels must coexist in the same marketplace.json without consumer confusion.
- Advancing the stable channel must require an explicit, deliberate action — not an automatic promotion.

## Considered Options

- **Option A**: Two marketplace entries — `dso` (stable, tagged) and `dso-dev` (main HEAD)
- **Option B**: Single marketplace entry with a `--channel=stable|dev` flag on `update-artifacts`
- **Option C**: Separate marketplace files (`marketplace.json` for stable, `marketplace-dev.json` for dev)
- **Option D**: Semver branch strategy (release branches cut from main, stable pinned to release branch HEAD)

## Decision Outcome

Chosen option: **Option A — two marketplace entries in a single marketplace.json**.

`marketplace.json` contains two entries:

| Entry | Channel | Pinned to |
|-------|---------|-----------|
| `dso` | stable | Latest release tag (e.g., `v1.13.0`) |
| `dso-dev` | dev | `main` HEAD |

Releasing to the stable channel requires running `scripts/release.sh` at the repo root, which enforces 10 precondition gates before creating and pushing the release tag. The first stable release tag is `v1.13.0` (next minor bump from the last non-tagged version, `1.12.32`).

Existing consumers who installed the single `dso` entry before this change will automatically resolve to the stable channel on their next `update-artifacts` run, because the `dso` entry name is preserved and now points to a release tag rather than main HEAD.

### Release Script: `scripts/release.sh`

`scripts/release.sh` enforces 10 precondition gates in order before creating a release tag:

1. **Semver validation** — the proposed version string must match `vMAJOR.MINOR.PATCH`.
2. **gh auth** — `gh auth status` must pass; the release requires GitHub CLI authentication.
3. **Tag uniqueness** — the tag must not already exist locally or on the remote.
4. **On main** — the current branch must be `main`; releases are never cut from feature branches.
5. **Clean tree** — `git status --porcelain` must return empty; no uncommitted changes.
6. **Upstream sync** — local main must not be behind `origin/main`.
7. **CI green** — the most recent CI run on main must have a passing status (checked via `gh run list`).
8. **validate.sh --ci** — the local validation suite must pass cleanly.
9. **marketplace.json validity** — the file must parse as valid JSON and contain the expected `dso` and `dso-dev` entries.
10. **Confirmation** — the maintainer must type the version string at an interactive prompt to confirm.

### Positive Consequences

- Consuming projects can choose their preferred stability level by selecting `dso` (stable, gated) or `dso-dev` (latest, ungated).
- The stable channel advances only when a maintainer explicitly runs `scripts/release.sh` and all 10 gates pass; there is no risk of accidental promotion.
- The dev channel continues to receive all merges immediately, supporting consuming projects that want cutting-edge features and are willing to tolerate instability.
- Existing `dso` consumers automatically land on the stable channel with no manual migration step.
- The release script encodes the release quality bar in executable form, making it auditable and self-documenting.

### Negative Consequences

- Maintainers must remember to run `scripts/release.sh` when a batch of features is ready for stable consumers; stable will lag main until a release is deliberately cut.
- Consuming projects on `dso-dev` have no stability guarantee; a breaking change on main is immediately available to them.
- The two-channel split adds a communication obligation: release notes or a changelog are needed so stable consumers understand what changed between release tags.
- The `scripts/release.sh` CI gate (`gh run list`) is advisory, not transactional — a race condition exists if CI is running at the moment the script checks.

## Pros and Cons of the Options

### Option A: Two marketplace entries (chosen)

- Good, because it requires no changes to consuming project tooling (`update-artifacts` already reads marketplace.json).
- Good, because the channel choice is explicit and visible in the consuming project's plugin install config.
- Good, because the stable entry name (`dso`) is preserved, giving existing consumers zero-change migration.
- Bad, because the dev channel (`dso-dev`) adds cognitive overhead for new consumers choosing between entries.

### Option B: Single entry with --channel flag

- Good, because there is only one entry to maintain in marketplace.json.
- Bad, because `update-artifacts` would require a flag change, breaking existing consumers silently if the default changed.
- Bad, because the channel choice is a runtime flag rather than a declared dependency in config, making it harder to audit.

### Option C: Separate marketplace files

- Good, because stable and dev manifests are completely isolated.
- Bad, because `update-artifacts` reads a single marketplace.json; consuming projects would need to point at a different URL for the dev manifest.
- Bad, because it fragments tooling configuration across multiple files and URLs.

### Option D: Release branch strategy

- Good, because release branches are a familiar pattern from other ecosystems.
- Bad, because maintaining release branches alongside main doubles the merge surface area.
- Bad, because `git-subdir` pinning to a branch HEAD still lacks the explicit gating that a tag + script provides.
- Bad, because it adds branch management overhead without a clear advantage over tagged releases.

## Links

- `scripts/release.sh` — release gate script at repo root
- `marketplace.json` — two-entry plugin manifest
- Epic 36a7-dbb5 — two-channel release model
- Story e56b-efc7 — documentation update for this decision
