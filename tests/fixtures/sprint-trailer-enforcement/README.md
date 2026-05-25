# Fixture: sprint-trailer-enforcement

Bug `db71-e078-ec99-4fbf`.

## What this fixture simulates

The f360-3a5b cross-contamination state: a session branch where multiple
stories were closed via Phase F bypass paths, leaving the commit graph with
`Merge worktree-agent-<id>` commits (the harvest commits from Phase F Step 5)
but **no** `DSO-Story-Merge: <story-id>` trailers anywhere in
`<base>..HEAD`.

Downstream consumers (`verify-story-merge-trailer.sh`, the
completion-verifier Step 3c trailer-provenance check, ci.yml
integration-scope detection, re-review attribution) all rely on the trailer
as the load-bearing attribution signal. A missing trailer corrupts every
one of them silently.

## What the setup.sh does

`setup.sh` initializes a scratch git repository under the directory
exported as `FIXTURE_DIR` (or a freshly created mktemp dir if not set) with:

- An initial commit on `main` (base ref).
- Three "harvest" commits with messages of the form
  `Merge worktree-agent-XXXX` — NO trailers, simulating per-task harvests
  that bypassed Step 18.
- Three story IDs that "appear closed" in this fixture: `fake-story-1`,
  `fake-story-2`, `fake-story-3`. None of them has a `DSO-Story-Merge`
  trailer.

`setup.sh` prints the absolute fixture path on stdout so callers can
capture it for assertions and cleanup.

## Used by

- `tests/scripts/test-sprint-trailer-enforcement-fixture.sh`
  (F5 — fixture-based verification of `verify-story-merge-trailer.sh`)
- `tests/scripts/test-sprint-trailer-enforcement-e2e.sh`
  (E2E — end-to-end exercise of the provenance pipeline)
