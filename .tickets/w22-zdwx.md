---
id: w22-zdwx
status: closed
deps: [w22-zggi, w22-4s5q]
links: []
created: 2026-03-22T07:02:17Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-9ltc
---
# Create build-review-agents.sh with atomic write and content hash

Implement build-review-agents.sh that composes reviewer-base.md + per-agent delta files into 6 generated agent files in plugins/dso/agents/. Reads base+delta, composes YAML frontmatter (name, description, tools, model per tier), embeds sha256 content hash of source inputs, and uses atomic write: all 6 files generated in temp dir first, moved to target only on success. On failure, no target files are modified. Exits 0 on success, non-zero with descriptive error on failure. Agent model assignments: light=haiku, standard=sonnet, deep-correctness/verification/hygiene=sonnet, deep-arch=opus. After implementing, run tests from task w22-zggi to confirm GREEN.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] build-review-agents.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/build-review-agents.sh
- [ ] Running build-review-agents.sh produces exactly 6 agent files in plugins/dso/agents/
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/build-review-agents.sh && ls plugins/dso/agents/code-reviewer-*.md | wc -l | awk '{exit ($1 != 6)}'
- [ ] Each generated agent file contains a content hash line
  Verify: grep -l 'content-hash:' $(git rev-parse --show-toplevel)/plugins/dso/agents/code-reviewer-*.md | wc -l | awk '{exit ($1 != 6)}'
- [ ] Unit tests pass GREEN (all 4 test_build_* functions)
  Verify: bash $(git rev-parse --show-toplevel)/tests/unit/scripts/test-build-review-agents.sh
- [ ] Hash computation is portable: script uses sha256sum on Linux and shasum -a 256 on macOS (or a portable wrapper)
  Verify: grep -qE 'sha256sum|shasum' $(git rev-parse --show-toplevel)/plugins/dso/scripts/build-review-agents.sh
- [ ] Hash algorithm is documented in a comment: specifies concatenation order (base content + newline + delta content) so T7 staleness check can reproduce it exactly
  Verify: grep -q 'content-hash\|hash.*base.*delta\|HASH_ALGORITHM' $(git rev-parse --show-toplevel)/plugins/dso/scripts/build-review-agents.sh

## Notes

**2026-03-22T11:13:51Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T11:14:18Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T11:14:26Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T11:15:11Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T11:15:28Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T11:50:57Z**

CHECKPOINT 6/6: Done ✓
