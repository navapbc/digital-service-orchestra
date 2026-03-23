# Rollback Procedure: v3 Migration

Use this runbook if post-cleanup validation fails or the old ticket system must be temporarily restored. Both commits produced by the migration are independently revertible.

## Pre-conditions

Confirm the recovery anchor tag exists before reverting:

```bash
git tag | grep pre-cleanup-migration
```

If the tag is absent, the finalize phase was interrupted before tagging — the cleanup commit has not yet run and there is nothing to revert.

## Commits to Identify

The migration produces two commits:

| Commit | What it changes | How to find it |
|--------|----------------|----------------|
| **Cleanup commit** | Removes `.tickets/`, the `tk` script, and tk-specific test fixtures | `git log --oneline --grep='remove old ticket system'` |
| **Reference update commit** | Replaces `tk` command references with `ticket` across skills/scripts/hooks/docs | `git log --oneline --grep='atomic reference update'` or look for the commit on story w21-wbqz |

## Revert the Cleanup Commit (independently revertible)

Restores `.tickets/`, the `tk` script, and test fixtures. Does **not** touch `ticket` command references.

```bash
# Find the SHA
CLEANUP_SHA=$(git log --oneline --grep='remove old ticket system' | awk '{print $1}' | head -1)

# Preview the revert
git revert --no-commit "$CLEANUP_SHA"
git diff --cached --stat

# Commit the revert
git revert "$CLEANUP_SHA"
```

Verify:

```bash
test -d .tickets/ && echo "OK: .tickets/ restored"
test -f plugins/dso/scripts/tk && echo "OK: tk script restored"
```

## Revert the Reference Update Commit (independently revertible)

Restores `tk` command references across skills, scripts, hooks, and documentation. Does **not** restore `.tickets/` or the `tk` script binary.

```bash
# Find the SHA (w21-wbqz story — atomic reference update commit)
REF_SHA=$(git log --oneline --grep='atomic reference update' | awk '{print $1}' | head -1)

# Preview
git revert --no-commit "$REF_SHA"
git diff --cached --stat

# Commit the revert
git revert "$REF_SHA"
```

Verify:

```bash
grep -r 'tk show\|tk create\|tk list' plugins/dso/skills/ | head -5
```

## Full Rollback (both commits)

Revert in reverse order — cleanup commit first, then reference update:

```bash
CLEANUP_SHA=$(git log --oneline --grep='remove old ticket system' | awk '{print $1}' | head -1)
REF_SHA=$(git log --oneline --grep='atomic reference update' | awk '{print $1}' | head -1)

git revert "$CLEANUP_SHA"   # restores .tickets/, tk script, fixtures
git revert "$REF_SHA"       # restores tk command references
```

## Accessing Old Data After Cleanup

If `.tickets/` has been removed but the tag exists, read individual ticket files directly from git:

```bash
# Read a specific ticket by ID
git show pre-cleanup-migration:.tickets/<ticket-id>.md

# List all ticket files at the tag
git ls-tree --name-only pre-cleanup-migration .tickets/
```

## Dry-Run Verification (finalize phase)

To preview what the finalize phase will remove without making changes:

```bash
plugins/dso/scripts/cutover-tickets-migration.sh --dry-run --phase=finalize
```

Output lines prefixed with `[would]` show the actions that would be taken in a live run. No files are modified and no commits are made.
