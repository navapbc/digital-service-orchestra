# merge-to-main.sh error handling (loaded by /dso:end-session Step 11)

Loaded only when `merge-to-main.sh` reports an error. Three distinct error shapes; handle each per the rules below.

## ESCALATE: retry budget exhausted

If the script output begins with `ESCALATE:`, **STOP immediately. Do NOT diagnose, retry, or continue.** Present the ESCALATE message verbatim to the user and ask for guidance. Do NOT proceed to Step 12 or any subsequent step.

> Merge failed after repeated attempts. Script message: `<ESCALATE output>`. Please advise how to proceed.

## CONFLICT_DATA: merge conflicts in non-ticket files

If the script reports ERROR with a `CONFLICT_DATA:` prefix:

1. Capture the working tree state for the user before invoking resolution: run `git status --short` and report: "Merge conflict detected. Current working tree state captured — do not stop the session until Step 12 confirms is_clean."
2. Invoke `/dso:resolve-conflicts` for agent-assisted resolution.
3. If resolution succeeds: continue to Step 12.
4. If resolution is abandoned (merge aborted): run `git status --short` and report ALL dirty files to the user before proceeding. Do NOT continue to Step 12 silently — the user must confirm their work is intact.

> **CRITICAL**: When resolving conflicts that involve `.tickets-tracker/` event files, do NOT use `git merge -X ours` — that would silently discard incoming ticket events from main and corrupt the event log. Resolve `.tickets-tracker/` conflicts per-file using `git checkout --ours` on each conflicted JSON event file individually (they are append-only and safe to accept ours per-file). `/dso:resolve-conflicts` handles this automatically.  <!-- # tickets-boundary-ok: data-integrity warning prose, not direct access -->

## Non-conflict ERROR

If the script reports an ERROR without the `CONFLICT_DATA:` prefix:

1. Diagnose the main repo state before giving up:
   ```bash
   MAIN_REPO=$(dirname "$(git rev-parse --git-common-dir)")
   git -C "$MAIN_REPO" status --short
   ```
2. If the output shows staged or modified files (lines beginning with `M`, `A`, `D`, `R`, `C`, or `??` for non-`.tickets-tracker/` paths):  <!-- # tickets-boundary-ok: prose path-pattern reference, not direct access -->
   - `git -C "$MAIN_REPO" reset HEAD` — unstage all staged files.
   - `git -C "$MAIN_REPO" checkout .` — discard tracked modifications.
   - `git -C "$MAIN_REPO" clean -fd` — remove untracked files.
   - Report: "Cleared stale main repo git state (staged/dirty index). Retrying merge."
   - Retry: `.claude/scripts/dso merge-to-main.sh ${BUMP_ARG:-}`
   - If the retry succeeds: continue to Step 12.
   - If the retry fails: relay the new error message to the user and stop.
3. If the main repo is clean and the error persists: relay the original error message to the user and stop.
