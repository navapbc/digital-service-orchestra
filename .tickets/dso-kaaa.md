---
id: dso-kaaa
status: open
deps: [dso-ez3s]
links: []
created: 2026-03-21T19:59:14Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ku13
---
# DOGFOOD: Run generate-test-index.sh against this repo to produce initial .test-index

Dogfood the scanner by running it against this repository (the DSO plugin itself) to produce the initial .test-index file. This validates the fuzzy match algorithm against real naming conventions and produces a committable artifact.

TDD REQUIREMENT: This task invokes generate-test-index.sh and commits the resulting .test-index. No new logic is written. Exemption criterion: 'infrastructure-boundary-only — invocation of the generate-test-index.sh script, no business logic'. Verification is behavioral: the .test-index exists, has valid entries, and the coverage summary is reasonable.

Implementation steps:
1. Run: bash plugins/dso/scripts/generate-test-index.sh
2. Inspect the generated .test-index:
   - Verify it exists at repo root
   - Verify each line matches format 'source/path: test/path' (no blank right-hand sides)
   - Verify each test path in each entry actually exists on disk
3. Review the coverage summary output:
   - Document actual counts in the task notes (tk add-note)
   - If 'files with no test coverage' count seems unexpectedly high, investigate whether they are truly test-free or if the scanner missed them
4. The generated .test-index will be committed as part of the story's commit

Files to create:
- .test-index (new, at repo root)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] .test-index exists at repo root
  Verify: test -f $(git rev-parse --show-toplevel)/.test-index
- [ ] .test-index has at least one entry
  Verify: wc -l $(git rev-parse --show-toplevel)/.test-index | awk '{exit ($1 < 1)}'
- [ ] All test paths referenced in .test-index exist on disk
  Verify: while IFS= read -r line; do [[ "$line" =~ ^# ]] && continue; [[ -z "$line" ]] && continue; right="${line#*:}"; IFS=',' read -ra parts <<< "$right"; for p in "${parts[@]}"; do p="${p// /}"; [[ -n "$p" ]] && test -f "$(git rev-parse --show-toplevel)/$p" || { echo "Missing: $p"; exit 1; }; done; done < $(git rev-parse --show-toplevel)/.test-index
- [ ] Coverage summary counts are documented in task notes (tk add-note dso-kaaa)
  Verify: grep -q "Files with" $(git rev-parse --show-toplevel)/.tickets/dso-kaaa.md

