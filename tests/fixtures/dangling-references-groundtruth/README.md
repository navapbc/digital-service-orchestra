# Dangling-reference matcher ground-truth fixtures (story 29e7 / CF-8 / E7)

Each fixture is one *case* the FP/FN harness
(`tests/scripts/measure-dangling-fp-fn.sh`) materializes into a synthetic git
repo (base commit on `origin/main`, head commit), runs
`plugins/dso/scripts/ci/check-dangling-references.sh` against, and scores.

A case is a directory `cases/<id>/` containing:

- `expect`        — one word: `DANGLING` (true positive expected) or `CLEAN`
                    (true negative expected — flagging it is a FALSE POSITIVE).
- `base/`         — repo contents at the base ref (`origin/main`).
- `head/`         — repo contents at HEAD (full replacement; files absent in
                    `head/` are deleted relative to `base/`).
- `note`          — one line describing what the case probes.

Scoring (relative to `expect`):
- expect=DANGLING, flagged    → TRUE POSITIVE
- expect=DANGLING, not flagged→ FALSE NEGATIVE (missed real conflict)
- expect=CLEAN,    flagged    → FALSE POSITIVE (the failure mode this story attacks)
- expect=CLEAN,    not flagged→ TRUE NEGATIVE

## Composition

The set is deliberately weighted toward *tricky true-negatives* — the cases
where the legacy `git grep` reference scan produced false positives:

- Comment-only surviving mentions of a removed symbol.
- String-literal-only surviving mentions.
- Substring / partial-word matches (`foo_bar` should not match removed `bar`).
- Symbols moved to another file (still defined → not dangling).
- Renames with all callers updated.
- Short-symbol noise (below the min-length guard).

…balanced by unambiguous true-positives (real surviving code references, and
surviving doc/config references) so FN is also measured.

## E7 remaining work (FLAGGED)

The full Done Definition calls for a **20-PR real historical ground-truth set**.
That requires live `gh` data (real merged PR base/head pairs) not assembled here.
This fixture set is the *representative* substitute used to measure FP/FN in this
isolated worktree; the live 20-PR run remains the open E7 verification step.
