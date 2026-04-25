## Bug Accountability Guide

Reference for the orchestrator during Phase E (Fix Planning) and Phase L (final report).

---

### Three Outcomes for Every Open Bug

| Outcome | Criteria | Action |
|---------|----------|--------|
| **Fixed** | Code change made + tests pass | `.claude/scripts/dso ticket transition <id> open closed` (add note with reason first) |
| **Escalated** | No code change can resolve this | Present findings to user. **Never close autonomously.** |
| **Deferred** | Blocked by a specific, verifiable prerequisite | Report the blocker. Never close autonomously. |

---

### Classification Gate

**Can this bug be resolved by a code change that passes tests?**

- **YES** → Fix it. Write code, run tests, close as FIXED.
- **NO** → **ESCALATE to user.** Present findings and a recommended action.

Bugs that MUST be escalated (never closed autonomously):

| Signal | Example |
|--------|---------|
| **Tests skip by design** | Visual tests skip on macOS; E2E tests skip without `CI=1` |
| **External tool limitation** | MCP sandbox lacks Web APIs; third-party constraint |
| **Environment-specific** | Works on CI but not locally (platform differences) |
| **Requires architectural decision** | Multiple valid approaches with real trade-offs |
| **Needs user context** | Bug report ambiguous; reproduction steps unclear |

**Escalation format** (one block per bug):
```
BUG: <id> — <title>
FINDING: <specific discovery>
CLASSIFICATION: <signal from table above>
RECOMMENDED ACTION: <e.g., "Add documentation", "Accept as known limitation">
```

---

### Deferred Justification Rules

A DEFERRED justification is valid **only if** it names a specific, verifiable blocker:
- ✅ "Blocked by <ticket-id> (not yet resolved — required prerequisite)"
- ✅ "Requires AWS credentials unavailable here — next step: `aws configure` with role X"

**Never acceptable:**
- ❌ "Pre-existing bug" — all bugs were pre-existing at session start
- ❌ "Infrastructure issue" — Tier 6 exists for this; classify and fix it
- ❌ "Skill/documentation issue" — skills and docs are code too; fix the file
- ❌ "Out of scope" — no out of scope in this workflow
- ❌ "Deferred to future session" without a named blocker
- ❌ "Not reproducible" without attempting reproduction

If you reach for an invalid justification, it means the bug should be FIXED or ESCALATED.
