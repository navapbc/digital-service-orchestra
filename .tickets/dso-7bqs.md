---
id: dso-7bqs
status: open
deps: [dso-z9qw]
links: []
created: 2026-03-22T22:30:49Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-0kt1
---
# Document validation signal thresholds and breach response protocol in REVIEW-WORKFLOW.md

Add a Post-Deployment Calibration section to plugins/dso/docs/workflows/REVIEW-WORKFLOW.md. This is a docs-only task (no conditional logic; Unit Test Exemption: purely structural doc creation with no behavioral content). Section content (based on epic success criteria): Tier Distribution Baseline: After 30 commits, compute tier distribution from classifier-telemetry.jsonl. Expected healthy baseline: ~50-60% Light, 30-40% Standard, 5-15% Deep. Signal: any single tier >80% = miscalibrated. Light-Tier Finding Rate: If Light-tier reviews produce critical/important findings >10%, floor rules are insufficient. Response: identify triggering pattern, add to floor rules in review-complexity-classifier.sh, re-validate against 30-commit sample. CI Failure Rate by Tier: Track post-merge CI failure rate per tier for first 30 commits. Light tier higher failure rate than Standard/Deep = under-classification. Response: lower Light/Standard threshold or add floor rules. Baseline Comparison: Compare overall CI failure rate against 30 commits preceding deployment. Sustained increase = routing gap. Breach Response Protocol: (1) Create P1 bug ticket via tk create, (2) adjust classifier (floor rules or scoring), (3) re-validate against same 30-commit sample. Place section after the existing tier routing content. Do NOT modify any hook, script, or config files — docs only.

## ACCEPTANCE CRITERIA

- [ ] REVIEW-WORKFLOW.md contains a Post-Deployment Calibration section header
  Verify: grep -q 'Post-Deployment Calibration\|post-deployment calibration' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] Section documents tier distribution baseline percentages (~50-60% Light, 30-40% Standard, 5-15% Deep)
  Verify: grep -q '50.*60.*Light\|50-60' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] Section documents Light-tier finding rate threshold (<10% critical/important)
  Verify: grep -q '10%\|10 percent' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] Section documents breach response protocol (P1 bug ticket, adjust classifier, re-validate)
  Verify: grep -q 'P1\|breach' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] Section references classifier-telemetry.jsonl as the data source
  Verify: grep -q 'classifier-telemetry.jsonl' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] No changes to any script, hook, or config file (docs-only commit)
  Verify: git diff --name-only HEAD | grep -vE '\.md$' | grep -vE '\.txt$' | wc -l | awk '{exit ($1 > 0)}'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py

