# Migration Guide: State Directory Rename

## State Directory Change

Starting with the workflow plugin extraction (sprint `j46vp`), the hook state
directory has been renamed from a lockpick-specific path to a generic,
repo-portable path.

| | Old path | New path |
|---|---|---|
| **Pattern** | `/tmp/lockpick-test-artifacts-<worktree-name>/` | `/tmp/workflow-plugin-<16-char-hash>/` |
| **Derivation** | `basename` of the worktree checkout directory | SHA-256 of the absolute `REPO_ROOT` path, first 16 hex chars |
| **Scope** | Tied to the directory name (breaks on rename) | Tied to the canonical repo path (stable across renames) |

### Why the change?

The old path embedded `lockpick` in the directory name, making the workflow
infrastructure unusable as a general-purpose plugin. The new hash-based path
is derived from `REPO_ROOT`, which is stable even if the containing worktree
directory is renamed.

## Automatic Migration

Migration happens automatically the **first time** any hook calls
`get_artifacts_dir()` after upgrading.

The migration logic in `lockpick-workflow/hooks/lib/deps.sh`:

1. Computes the new hash-based path from `REPO_ROOT`.
2. Checks whether the old path (`/tmp/lockpick-test-artifacts-<worktree>/`)
   exists **and** the new path is empty.
3. If both conditions hold, acquires an atomic `mkdir` lock and copies all
   files from the old directory into the new directory.
4. Releases the lock.

The migration is **idempotent**: subsequent calls skip the copy because the
new directory is no longer empty.

## In-Flight Sessions

If a session is in progress when the upgrade is applied:

- Hooks that have not yet run will migrate state automatically on their first
  call.
- Hooks that already ran (and wrote to the old path) will not see their
  existing state until `get_artifacts_dir()` is called again. This may produce
  a one-time re-validation prompt asking you to re-run the previous step.
- Once migration completes the session continues normally.

## Old Directories Are Not Deleted

The migration **does not delete** the old `/tmp/lockpick-test-artifacts-*/`
directories. They are left in place and will be removed by the OS temp-file
cleanup mechanism (typically on reboot or after a TTL). You can also remove
them manually:

```bash
rm -rf /tmp/lockpick-test-artifacts-*
```

## Reverting

If you need to revert to the old path (e.g., to test against an older hook
version), set `REPO_ROOT` to a path whose `basename` matches the old worktree
name and ensure `get_artifacts_dir()` is not available (or override it in
your test harness).
