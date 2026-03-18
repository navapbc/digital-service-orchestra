---
id: dso-npw2
status: open
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

