---
id: dso-npw2
status: in_progress
deps: [dso-xtcg]
links: []
created: 2026-03-18T04:37:05Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-igoj
---
# Rewrite docs/INSTALL.md: two-step flow, config/env summary with links, troubleshooting, remove stale content

As a new engineer, I want a single document (`docs/INSTALL.md`) that walks me through DSO setup end-to-end so I can complete onboarding without asking anyone.

## Done Definition

- `docs/INSTALL.md` rewritten with the two-step flow: install plugin → invoke `/dso:project-setup`
- Includes a summary of the most critical `workflow-config.conf` keys and env vars with links to Story D's authoritative reference — **no full duplication** of the reference inline (prevents drift)
- Includes optional dependency notes (acli, PyYAML): what they enable and how to install
- Includes a troubleshooting section covering cross-platform edge cases (macOS, Linux, WSL/Ubuntu)
- All stale content from pre-plugin-transition removed
- A new engineer can complete setup end-to-end by following `INSTALL.md` alone, without needing to ask anyone
- `scripts/check-skill-refs.sh` exits 0 on the updated file

## Escalation Policy

**If at any point you lack high confidence in your understanding of the existing project setup — e.g., you are unsure whether an installation step is still accurate, what the correct entry point is for a given platform, or whether a troubleshooting item is still relevant — stop and ask the user before writing. Err on the side of guidance over assumption. INSTALL.md is the first document a new engineer reads; inaccurate instructions erode trust and waste onboarding time.**


## Notes

**2026-03-18T07:42:29Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T07:42:45Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-18T07:42:58Z**

CHECKPOINT 3/6: Tests written (documentation task — verification criteria defined) ✓

VERIFICATION CRITERIA (from dso-bxd0 audit + Done Definition):

STALE ITEMS TO REMOVE:
1. /dso:init verification step (lines 109-127) — replace with /dso:project-setup reference
2. validate-work Configuration section (lines 129-230) — move reference to CONFIGURATION-REFERENCE.md link
3. workflow-config.conf copy command using literal /path/to/ placeholder — fix to use $CLAUDE_PLUGIN_ROOT
4. Option A (claude plugin install) marked as current/working — mark as aspirational/pending
5. No mention of dso-setup.sh in installation flow — add it

ITEMS TO ADD:
1. Two-step flow: (1) install plugin via git clone + dso-setup.sh, (2) invoke /dso:project-setup
2. dso.plugin_root config key documentation (brief, link to CONFIGURATION-REFERENCE.md)
3. Explicit 'pre-commit install' step
4. Optional dependency notes: acli (what it enables, how to install), PyYAML (what it enables, how to install)
5. Troubleshooting section: macOS (brew install coreutils, bash version), Linux, WSL/Ubuntu cross-platform edge cases
6. Summary of critical workflow-config.conf keys + env vars with link to CONFIGURATION-REFERENCE.md (no duplication)
7. dso-setup.sh referenced in installation flow

QUALIFICATION RULE: All skill invocations must use /dso:project-setup form (not /project-setup)

**2026-03-18T07:44:00Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-18T07:44:14Z**

CHECKPOINT 5/6: Validation passed ✓ — scripts/check-skill-refs.sh exits 0

**2026-03-18T07:44:40Z**

CHECKPOINT 6/6: Done ✓

AC SELF-CHECK RESULTS:
- AC1 (two-step flow, /dso:project-setup): PASS (3 occurrences of /dso:project-setup)
- AC2 (workflow-config.conf summary + link to CONFIGURATION-REFERENCE.md, no duplication): PASS
- AC3 (acli + PyYAML: what they enable + how to install): PASS
- AC4 (troubleshooting section: macOS, Linux, WSL/Ubuntu): PASS
- AC5 (stale /dso:init removed): PASS (0 occurrences)
- AC6 (validate-work Configuration section removed): PASS (0 occurrences)
- AC7 (workflow-config copy uses $CLAUDE_PLUGIN_ROOT): PASS
- AC8 (explicit pre-commit install step): PASS
- AC9 (dso.plugin_root documented): PASS
- AC10 (Option A marked aspirational/not yet supported): PASS
- AC11 (dso-setup.sh referenced in installation flow): PASS
- AC12 (check-skill-refs.sh exits 0): PASS
