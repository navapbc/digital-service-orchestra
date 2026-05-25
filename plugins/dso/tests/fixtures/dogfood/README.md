# Dogfood Fixtures — Gov-Copy Baseline

This directory contains the synthetic dogfood validation baseline for epic
`f360-3a5b-b8f3-4f86` (Gov-copy sub-agent for empathetic, plain-language UI copy).

## Files

- `bad-copy-baseline.yaml` — The BEFORE state. A `gov-copy-artifact.yaml` with 9
  intentionally bad items spanning three pages (`application_form`,
  `eligibility_screen`, `error_page`). Each item exhibits at least one quality
  failure deliberately: jargon ("Indicate your remunerative engagement"),
  blame-language ("You failed to provide..."), vague hints, banned-word usage
  (`utilize`, `leverage`, `facilitate`), and passive voice. Expected baseline
  metrics:
  - avg `checks.fk_grade` ≥ 15
  - `checks.banned_words_found` populated in 7 of 9 items
  - `checks.active_voice` rate: 0% (all passive)

- `good-copy-improved.yaml` — The AFTER state. Same 9 items rewritten in plain
  language. Expected target metrics:
  - avg `checks.fk_grade` ≤ 5
  - 0 banned words
  - 100% active voice

## Acceptance bar

Per epic SC-8 (synthetic dogfood validation), the harness `dogfood-gov-copy.sh`
must observe:

- Average `fk_grade` decreases by ≥ 1 grade level
- Banned words total drops to 0
- Active voice rate increases by ≥ 20 percentage points

## Stale-baseline warning

If the canon corpus (`${CLAUDE_PLUGIN_ROOT}/data/ui-reference/canon/`), banned-word list
(`dso-config.conf` `[gov_copy]` `banned_words`), or `fk_max` threshold changes,
the baseline measurements in this directory may no longer reflect current
deterministic post-processor output. Re-run the post-processor on
`bad-copy-baseline.yaml` to refresh the baseline before re-evaluating the
acceptance bar.
