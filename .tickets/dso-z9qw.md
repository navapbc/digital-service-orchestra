---
id: dso-z9qw
status: open
deps: [dso-gifa]
links: []
created: 2026-03-22T22:30:23Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-0kt1
---
# Verify classifier telemetry output matches contract spec; fix any field gaps

Run the telemetry tests from the RED test task (dso-gifa). If any tests fail because the classifier's telemetry output is missing fields or has incorrect values, fix plugins/dso/scripts/review-complexity-classifier.sh. Known spec: every invocation must append a JSON object containing all 7 factor scores, computed_total, selected_tier, staged file paths (files array), plus diff_size_lines, size_action, is_merge_commit — 13 fields total. The current implementation at lines 525-552 writes all 13 fields — verify all 13 are present in the telemetry JSONL (not just the stdout JSON). Stdout omits 'files'; telemetry must include it and all size/merge fields. Fix if missing. Also verify: ARTIFACTS_DIR unset → no telemetry file created (silent skip). Expected: bash tests/run-all.sh passes after any fixes.

## ACCEPTANCE CRITERIA

- [ ] All 6 telemetry tests from dso-gifa pass (exit 0) when running tests/hooks/test-review-complexity-classifier.sh
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-review-complexity-classifier.sh 2>&1 | grep -E 'PASS|FAIL' | grep -v FAIL | wc -l | awk '{exit ($1 < 6)}'
- [ ] classifier-telemetry.jsonl entry contains all 13 required fields: blast_radius, critical_path, anti_shortcut, staleness, cross_cutting, diff_lines, change_volume, computed_total, selected_tier, files, diff_size_lines, size_action, is_merge_commit
  Verify: ARTIFACTS_DIR=$(mktemp -d) && echo 'diff --git a/src/foo.py b/src/foo.py\nindex 0000000..1111111 100644\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -1 +1 @@\n+x = 1' | bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh && python3 -c "import json; d=json.loads(open('$ARTIFACTS_DIR/classifier-telemetry.jsonl').readline()); missing=[k for k in ['blast_radius','critical_path','anti_shortcut','staleness','cross_cutting','diff_lines','change_volume','computed_total','selected_tier','files','diff_size_lines','size_action','is_merge_commit'] if k not in d]; print('missing:',missing); exit(1 if missing else 0)"
- [ ] No telemetry file created when ARTIFACTS_DIR is unset
  Verify: env -u ARTIFACTS_DIR bash -c 'echo "diff --git a/x.py b/x.py" | bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh' && test ! -f classifier-telemetry.jsonl
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py

