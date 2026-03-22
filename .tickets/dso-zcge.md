---
id: dso-zcge
status: open
deps: [dso-z9qw]
links: []
created: 2026-03-22T22:30:35Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-0kt1
---
# Create contract document plugins/dso/docs/contracts/classifier-telemetry.md

Create plugins/dso/docs/contracts/classifier-telemetry.md documenting the classifier-telemetry.jsonl JSONL schema. This is a docs-only task (no conditional logic; no RED test task needed — Unit Test Exemption: purely structural doc creation with no behavioral content). Contract document sections: Signal Name (CLASSIFIER_TELEMETRY), Emitter (plugins/dso/scripts/review-complexity-classifier.sh), Parser (future calibration tooling — currently no automated consumer), Fields table (blast_radius, critical_path, anti_shortcut, staleness, cross_cutting, diff_lines, change_volume, computed_total, selected_tier, files, plus diff_size_lines, size_action, is_merge_commit from the size contract), Example JSONL entry. Relationship to review-gate-telemetry.jsonl: explicitly document independence — these are separate files tracking different concerns (classification decisions vs. gate enforcement outcomes); no shared correlation key is required as they serve independent consumers. Follow the format of existing contracts in plugins/dso/docs/contracts/.

## ACCEPTANCE CRITERIA

- [ ] plugins/dso/docs/contracts/classifier-telemetry.md exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-telemetry.md
- [ ] Document contains all 13 required fields in a fields table (7 factor scores + computed_total + selected_tier + files + diff_size_lines + size_action + is_merge_commit)
  Verify: python3 -c "content=open('$(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-telemetry.md').read(); fields=['blast_radius','critical_path','anti_shortcut','staleness','cross_cutting','diff_lines','change_volume','computed_total','selected_tier','files','diff_size_lines','size_action','is_merge_commit']; missing=[f for f in fields if f not in content]; print('missing:',missing); exit(1 if missing else 0)"
- [ ] Document includes a section on independence from review-gate-telemetry.jsonl
  Verify: grep -q 'review-gate-telemetry' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-telemetry.md
- [ ] Document includes an example JSONL entry
  Verify: grep -q '"selected_tier"' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-telemetry.md
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py

