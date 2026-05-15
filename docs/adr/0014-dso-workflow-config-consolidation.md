# DSO Workflow Config Consolidation: Single `dso.workflow` Key

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-05-15

Technical Story: 5ed3-9eb5-b841-4b5f — DSO workflow config consolidation

## Context and Problem Statement

The DSO plugin currently exposes four separate config keys in `.claude/dso-config.conf` that together determine the project's workflow mode:

| Key | Values |
|-----|--------|
| `merge.strategy` | `pr` \| `direct` |
| `enforcement.strategy` | `ci` \| `local` |
| `worktree.isolation_enabled` | `true` \| `false` |
| `attribution.enabled` | `true` \| `false` |

In practice these four keys always move together. A project hosted on GitHub with CI uses `merge.strategy=pr`, `enforcement.strategy=ci`, `worktree.isolation_enabled=true`, and `attribution.enabled=true`. A local-only project uses the opposite of each. No documented or observed project uses a heterogeneous combination (e.g., `merge.strategy=pr` with `enforcement.strategy=local`).

Four keys to represent two modes creates three problems:

1. **Config sprawl**: a new project must set four keys correctly or produce an inconsistent hybrid state that has no defined semantics.
2. **Ambiguity**: skills and hooks that need to branch on "are we in CI-PR mode?" must read two or more keys and intersect them, introducing logic that diverges subtly across callers.
3. **Migration surface**: when a project switches from local to CI-PR mode, four separate edits are required, each of which is an opportunity for a partial migration that leaves the system in an undefined state.

## Decision Drivers

- New projects should be able to declare their workflow mode in a single key.
- Existing projects must not break during migration; legacy keys must continue to work during a bounded migration window.
- After migration, stale legacy keys should produce a hard error rather than silently yielding stale values.
- The correct value for `dso.workflow` should be auto-detectable from the project's git remote URL so that `detect-dso-workflow.sh` can bootstrap new projects without manual configuration.
- The migration must be idempotent: running the migrator twice must produce the same result as running it once.

## Considered Options

- **Approach A**: Single `dso.workflow=ci-pr|local` key with hybrid shim in `read-config.sh`, idempotent migrator, and sentinel lockout after migration.
- **Approach B**: Keep four keys but add a validation step in `read-config.sh` that errors on inconsistent combinations.
- **Approach C**: Introduce a `dso.workflow` key as an additive alias only (no sentinel lockout, no migrator), allowing legacy keys and the new key to coexist indefinitely.

## Decision Outcome

Chosen option: **Approach A — single `dso.workflow` key with shim, migrator, and sentinel lockout.**

### Key: `dso.workflow`

Two values are defined:

| Value | Equivalent legacy config |
|-------|--------------------------|
| `ci-pr` | `merge.strategy=pr`, `enforcement.strategy=ci`, `worktree.isolation_enabled=true`, `attribution.enabled=true` |
| `local` | `merge.strategy=direct`, `enforcement.strategy=local`, `worktree.isolation_enabled=false`, `attribution.enabled=false` |

### Hybrid shim in `read-config.sh`

During the migration window, callers that read a legacy key (e.g., `merge.strategy`) via `read-config.sh` receive a transparently derived value:

1. `read-config.sh` intercepts reads for the four legacy keys.
2. It checks whether `dso.workflow` is set in `dso-config.conf`.
3. If `dso.workflow` is present, it derives and returns the corresponding legacy value for the caller — the caller is unaffected and requires no change.
4. If `dso.workflow` is absent, `read-config.sh` falls through to the raw file read as before (full backward compatibility for unmigrated projects).

The shim is an inline block inside `read-config.sh`, not a wrapper script, so the public API (`read-config.sh <key>`) is unchanged.

### Idempotent migrator: `migrate-dso-workflow-config.sh`

The migrator performs the following steps atomically:

1. Check for the sentinel file `.claude/.dso-config-v2-migrated`. If present, exit 0 immediately (idempotent).
2. Read the current values of the four legacy keys from `dso-config.conf`.
3. Infer the correct `dso.workflow` value (`ci-pr` or `local`) from the legacy values. If the legacy values are inconsistent, error with a recovery message and exit 1 (do not write a partial migration).
4. Remove the four legacy keys from `dso-config.conf`.
5. Write `dso.workflow=<value>` to `dso-config.conf`.
6. Create `.claude/.dso-config-v2-migrated` atomically (via `mv` from a temp file) as the last step.

The sentinel is created last so that an interrupted migration (crash between steps 4 and 6) leaves the project without a sentinel. Re-running the migrator then retries from step 1 rather than silently accepting a partial state.

### Sentinel lockout

After migration (sentinel present), reads of the four legacy keys via `read-config.sh` exit 1 with a recovery message:

```
ERROR: legacy config key 'merge.strategy' read after dso-config v2 migration.
       Remove this key reference and use 'dso.workflow' instead.
       Recovery: remove .claude/.dso-config-v2-migrated and re-run migrate-dso-workflow-config.sh to inspect migration state.
```

This converts a formerly silent stale-read into a hard error that surfaces immediately in CI and in hook runs, preventing post-migration drift from going undetected.

### Auto-detection: `detect-dso-workflow.sh`

`detect-dso-workflow.sh` infers the correct `dso.workflow` value from the project's git remote URL:

1. Run `git remote get-url origin` (or `git remote get-url upstream` as fallback).
2. If the URL contains `github.com` → emit `ci-pr`.
3. Otherwise → emit `local`.
4. If no remote is configured → emit `local` (safe default) with a warning to stderr.

The script is intended for use during `dso:init` and the migrator's inference step. It is not called at runtime by skills or hooks — `read-config.sh` is the single runtime reader.

### Why Approach A over the alternatives

- **Approach B (validate inconsistent combinations)** preserves four-key entropy and still requires new projects to set four keys. It also requires every skill/hook to decide which key is authoritative when the validation catches a conflict. It makes legacy configs less wrong but does not simplify them. Rejected.
- **Approach C (additive alias, no lockout)** removes the ambiguity for new projects but leaves existing projects with a forever-growing config surface. Skills would need to check both `dso.workflow` and the four legacy keys indefinitely, defeating the consolidation goal. Without a lockout, stale legacy keys accumulate silently. Rejected.

Approach A is the only option that produces a clean post-migration state, gives new projects a single key to set, and makes post-migration legacy reads a detectable hard error rather than a silent stale value.

## Consequences

### Positive

- New projects set one key. The correct value is auto-detected by `detect-dso-workflow.sh` during `dso:init`.
- Skills and hooks that need to branch on workflow mode read one key. The four-way intersection logic is replaced by a single equality check.
- Post-migration, reads of stale legacy keys are hard errors, surfacing drift immediately in CI.
- The migrator is idempotent; running it twice is safe and the sentinel prevents double-migration.
- The shim requires no changes in callers: any skill or hook reading a legacy key via `read-config.sh` receives the correct derived value transparently during the migration window.

### Negative

- The sentinel lockout makes post-migration legacy key reads a hard error. Any skill, hook, or script that reads a legacy key directly (bypassing `read-config.sh`) will fail silently until discovered. Callers must use `read-config.sh`, not raw `grep`/`cut` on `dso-config.conf`.
- The four legacy keys are preserved in documentation (this ADR) but removed from `dso-config.conf` after migration. A maintainer who adds a legacy key back to `dso-config.conf` post-migration will see the derived value from the shim override it — which may be confusing without knowledge of the shim.
- `detect-dso-workflow.sh` uses git remote URL heuristics. A GitHub-hosted project that wants `local` mode (unusual but valid) must set `dso.workflow=local` explicitly after `dso:init` runs auto-detection.

### Neutral

- The four legacy keys remain valid in `dso-config.conf` for unmigrated projects. The shim activates only when `dso.workflow` is present, leaving unmigrated projects fully unchanged.
- Migration is voluntary during the migration window. A future ADR amendment or `dso:init` version bump may make migration required.

## References

- ADR 0009 (`docs/adr/0009-config-system.md`) — original config system design; `read-config.sh` public API established there is unchanged by this decision.
- ADR 0012 (`docs/adr/0012-merge-to-main-dispatcher-pattern.md`) — merge-to-main dispatcher reads `merge.strategy`; post-migration it reads `dso.workflow` via the shim.
- Config key reference: `plugins/dso/docs/CONFIGURATION-REFERENCE.md`.
- Migrator: `plugins/dso/scripts/migrate-dso-workflow-config.sh`.
- Auto-detector: `plugins/dso/scripts/detect-dso-workflow.sh`.
- Sentinel file: `.claude/.dso-config-v2-migrated` (gitignored in consuming projects; committed in plugin test fixtures).
