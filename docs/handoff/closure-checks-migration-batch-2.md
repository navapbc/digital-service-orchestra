# Session Handoff: Closure Checks Migration (a03c-d55e-1393-4f27) — Batch 2+

**Status as of 2026-05-21**: 13 of 70 brainstorm:complete-tagged epics processed in the initial session (story ad70-f38a-7684-4e00). 57 remain. This document captures everything a future session needs to resume.

## What this is

Epic `a03c-d55e-1393-4f27` (view via `.claude/scripts/dso ticket show a03c-d55e-1393-4f27`) — Closure Checks schema migration. Phase 4 (the operational bulk migration) is partially complete. This handoff resumes from where session 2026-05-20 left off, using the same Claude-driven plan/apply tooling.

The migration_run_id of the first session is `ccd7b51c-6e50-4e6d-ad9b-1bfbae5c705c`. Each subsequent batch should mint a fresh UUID.

## Already processed (13 epics — DO NOT re-classify)

These epics have a `CLOSURE_CHECKS_CLASSIFIER_AUDIT:` audit comment in their ticket-tracker comment list. Re-running the migration on them would write a duplicate audit comment with a fresh `migration_run_id`; not destructive but noisy.

```
01f5-28c1
0b7c-d811
136b-6758-ba12-47fc
411b-a047-18de-4516
5018-64ce
53ef-d6fd-5ca5-4d62
6add-c1fc
70d5-37ee
7510-0198-3e2b-4ca5
7f42-e41f-a501-4007
87e9-0bc8
88d2-6756
94ed-f55c-51f5-45f6
```

## Remaining (57 epics — process these)

```
09b0-1d25-1a7d-4cf1
0cbc-4bbb-e2f6-4da0
1083-fb3d
148e-61c8
170b-2ac9
188c-47e4-5abe-4b9c
2c28-e5b9
2fa0-a2d9-35b7-4101
2fe5-c2d1
3601-f085
3e9b-afee
411b-a047-18de-4516
411b-a047-18de-4516
4ba1-759f
4e55-a6ba-2eed-484c
4f8e-a7a6
50ab-1e3d-a164-4373
56b1-94f1
5d6e-86a9-7e21-4ed1
615f-fad3-1e07-4cdd
6212-bdab-bfd6-4d04
68f2-f403-fc7c-4bff
6a32-c2d6
73b0-c1b1-8466-4eb6
77eb-4920
7c64-2017
7ec5-9ed4
80c9-94d8
84a8-ab02-5a7a-4c81
89b8-92dd
89e3-3a14
8fa7-b9cb
9027-7faa-bd6e-4d33
9088-bbe7
93dc-3a7b
9415-bc04-c1ea-43f9
9b29-3220
9fda-1bdf-d8a7-4cd9
a0fa-1c84
a78e-49ab-31a5-4ee0
ab1c-49d3-7c25-4f1e
aca9-2bcd-d40a-4a23
b4e9-d6b9-d4dd-4e1b
bbb6-7167
c10f-cc1b-21be-46b3
c211-92eb-1779-4dd6
c7dd-6caa
ca48-c3c3
cbe9-8d99-b1c5-4f06
cfff-7e96-65f0-46d5
d2f8-08cd-9a73-46be
db68-ca95
ea1a-c8ec-c6e2-4d35
edc7-0b85
f27a-3c6a-1a4e-48ae
f61f-7e0a-36d3-4e7d
f691-681e-0db9-4260
f7d5-59e4
w21-bsnz
```

Note: this list is a snapshot from 2026-05-21. New `brainstorm:complete`-tagged epics added since then will not appear here. Future sessions should re-derive the current pending set if more than a few weeks pass — see "Re-deriving the pending set" below.

## Resume workflow

The tooling is identical to the first session's. Each batch:

1. Mints a fresh `migration_run_id` (UUID4).
2. Honors the 25-item cumulative ack budget per session (DD5).
3. Runs plan-mode per epic, collects needs-ack items, presents them to the user, writes decisions, applies via `--apply-from-plan`.
4. Posts a `MIGRATION_RUN_SUMMARY` comment on epic `a03c-d55e-1393-4f27` recording the new `migration_run_id` and per-epic counts.

### Driver script (paste into a session to run)

```bash
#!/usr/bin/env bash
# Resume Batch 2+ of the Closure Checks migration.
# Adjust REMAINING_EPICS to the next slice you want to process.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
SESSION_ID="ad70-batch-$(date +%s)"
MIGRATION_RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
BUDGET=25  # DD5 cumulative cap across this batch
WORKDIR=$(mktemp -d /tmp/ad70-batch.XXXXXX)

# Paste the next slice of remaining epic-ids here (one per line).
# Defer the rest to a subsequent batch.
REMAINING_EPICS=(
    09b0-1d25-1a7d-4cf1
    0cbc-4bbb-e2f6-4da0
    1083-fb3d
    # ... add more, but expect to hit BUDGET around 10-20 epics
)

echo "MIGRATION_RUN_ID: $MIGRATION_RUN_ID"
echo "SESSION_ID: $SESSION_ID"
echo "WORKDIR: $WORKDIR"

CUMULATIVE=0
PROCESSED=0
for EPIC_ID in "${REMAINING_EPICS[@]}"; do
    REMAINING=$(( BUDGET - CUMULATIVE ))
    if [[ $REMAINING -le 0 ]]; then
        echo "BUDGET_HIT: stopping before $EPIC_ID"
        break
    fi
    PLAN_FILE="$WORKDIR/${EPIC_ID}.plan.json"
    out=$("$REPO_ROOT/plugins/dso/scripts/closure-checks-classifier-pass.sh" \
        --ticket-id "$EPIC_ID" \
        --target "$REPO_ROOT" \
        --session-id "$SESSION_ID" \
        --migration-run-id "$MIGRATION_RUN_ID" \
        --remaining-budget "$REMAINING" \
        --plan-output "$PLAN_FILE" 2>&1)
    NEEDS=$(printf '%s' "$out" | grep '^PLAN_WRITTEN:' | tail -1 | sed -E 's/.*needs_ack=([0-9]+).*/\1/')
    ITEMS=$(printf '%s' "$out" | grep '^PLAN_WRITTEN:' | tail -1 | sed -E 's/.*items=([0-9]+) needs_ack.*/\1/')
    CUMULATIVE=$(( CUMULATIVE + ${NEEDS:-0} ))
    PROCESSED=$(( PROCESSED + 1 ))
    echo "EPIC: $EPIC_ID items=${ITEMS:-0} needs_ack=${NEEDS:-0} cumulative=$CUMULATIVE"
done

echo ""
echo "Plan batch complete. WORKDIR: $WORKDIR"
echo "Next: the Claude orchestrator reads each plan file, presents needs-ack"
echo "items via AskUserQuestion, writes a decisions file per epic, then runs"
echo "apply-from-plan per epic to write audit comments + apply SC->CC moves."
```

### Claude orchestrator flow (after the driver writes plans)

For each plan in `$WORKDIR`:

1. Read `$WORKDIR/<epic-id>.plan.json`. The plan has `items[]` with `auto_accepted` and `proposed_target` fields.
2. For items where `auto_accepted: false`, present each to the user via `AskUserQuestion` with options `accept`/`reject`/`defer`. Up to 4 items per AskUserQuestion call.
3. Write a decisions JSON file at `/tmp/decisions-<epic-id>.json` with this shape:

   ```json
   {
     "decisions": [
       {"index": 2, "user_decision": "accept"},
       {"index": 5, "user_decision": "reject"},
       {"index": 8, "user_decision": "accept", "override_target": "CC"}
     ]
   }
   ```

4. Invoke apply-mode:

   ```bash
   plugins/dso/scripts/closure-checks-classifier-pass.sh \
       --ticket-id "$EPIC_ID" \
       --target "$REPO_ROOT" \
       --session-id "$SESSION_ID" \
       --migration-run-id "$MIGRATION_RUN_ID" \
       --remaining-budget 25 \
       --apply-from-plan "$WORKDIR/${EPIC_ID}.plan.json" \
       --decisions-file "/tmp/decisions-${EPIC_ID}.json"
   ```

   The script writes the audit comment, applies SC→CC moves, prints `AUDIT_WRITTEN:` and `DESCRIPTION_UPDATED:` lines.

5. After all per-epic applies complete, post a single `MIGRATION_RUN_SUMMARY` comment on epic `a03c-d55e-1393-4f27` recording the new `migration_run_id`, start/end timestamps, and counts.

## Per-item ack heuristics (from session 1)

The user accepted most r=4 transitional items as SC→CC moves. They rejected items where:

- The text described a durable artifact even when phrased with past-tense verbs (e.g., `"INSTALL.md and README each contain a Semgrep section"`, `"onboarding SKILL.md ... updated with Java branch writing commands"` — both rejected because the resulting state IS durable).
- The text was a documentation reference under a schema definition (e.g., `"CONTEXT — link to behavioral-testing-standard.md"` rejected as schema field label, not a real SC).
- The text described the existence of an artifact (rather than an action that produced it).

They accepted moves where the text described a one-time verification or validation task (e.g., `"All existing tests pass"`, `"Validation: grep commands.test_runner returns mvn test"`, `"Each new subcommand has an integration test that exercises..."`).

Use this judgment when reviewing items at r=4. At r=5, the classifier's verdict auto-applies per the DD4 amendment (see commit `ce2ec1a65c`).

## Re-deriving the pending set

If significant time has passed and new `brainstorm:complete`-tagged epics may have been added, re-derive the pending set by:

1. Enumerate all `brainstorm:complete`-tagged epics:

   ```bash
   {
       .claude/scripts/dso ticket list --type=epic --status=open --format=llm
       .claude/scripts/dso ticket list --type=epic --status=in_progress --format=llm
       .claude/scripts/dso ticket list --type=epic --status=closed --format=llm
   } | python3 -c '
   import json, sys
   for line in sys.stdin:
       try:
           t = json.loads(line.strip())
       except Exception:
           continue
       if "brainstorm:complete" in (t.get("tg") or t.get("tags") or []):
           print(t.get("id") or t.get("ticket_id"))
   ' | sort -u
   ```

2. For each id, check whether its description+comments already contain `CLOSURE_CHECKS_CLASSIFIER_AUDIT:` (via `ticket show <id>`). Skip ones that do.

This is slow (~1 ticket-show per candidate × 70+ candidates) — expect 1–3 minutes wall time. A future helper script could parallelize this.

## Reference

- Story: `ad70-f38a-7684-4e00` — closed 2026-05-20
- Parent epic: `a03c-d55e-1393-4f27` — open (Phase 4 partial)
- Migration run ID (session 1): `ccd7b51c-6e50-4e6d-ad9b-1bfbae5c705c`
- Helper: `plugins/dso/scripts/closure-checks-classifier-pass.sh`
- Audit contract: `plugins/dso/docs/contracts/closure-checks-classifier-audit.md` (`contract_version=1`)
- Smoke tests: `tests/scripts/test-closure-checks-classifier-pass.sh`
- MIGRATION_RUN_SUMMARY comment on a03c: posted 2026-05-21T00:00Z
- DD4 amendment commit: `ce2ec1a65c` (ranking-5 auto-apply policy)
