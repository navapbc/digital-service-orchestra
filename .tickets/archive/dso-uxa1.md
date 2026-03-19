---
id: dso-uxa1
status: closed
deps: [dso-ku5i]
links: []
created: 2026-03-17T21:07:49Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-2x3c
---
# Migrate skill/workflow doc script invocations to use dso shim (GREEN)

## TDD Requirement (GREEN phase)

Replace all ${CLAUDE_PLUGIN_ROOT}/scripts/<name> invocations in skills/, docs/workflows/, CLAUDE.md with .claude/scripts/dso <name>. test-doc-migration.sh passes.

## Implementation Steps

1. Run migration on all 28 target files:
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Find all target files
FILES=$(grep -rl '${CLAUDE_PLUGIN_ROOT}/scripts/' "$REPO_ROOT/skills" "$REPO_ROOT/docs/workflows" "$REPO_ROOT/CLAUDE.md" 2>/dev/null | grep -v 'PLUGIN_SCRIPTS=' )
# Apply replacement (correct regex, removes trailing \s requirement)
perl -pi -e 's|\$\{CLAUDE_PLUGIN_ROOT\}/scripts/([\w][\w.-]*)|.claude/scripts/dso $1|g' $FILES
```

2. Verify exclusions were preserved:
   - PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts" lines (10) — untouched
   - ls "${CLAUDE_PLUGIN_ROOT}/scripts/"*.sh line (1, dev-onboarding/SKILL.md:121) — untouched (not matched by word-char anchor)

3. Run test-doc-migration.sh to confirm 0 remaining invocations

## Notes
- 57 invocation lines replaced → 0 remain
- ≥47 new .claude/scripts/dso lines added (57 replaced minus lines where script name has non-word chars)
- PLUGIN_SCRIPTS= lines intentionally preserved (internal config-resolution plumbing used within plugin context)

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | grep -q 'FAILED: 0'
- [ ] ruff check passes
  Verify: ruff check scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: ruff format --check scripts/*.py tests/**/*.py
- [ ] Migration completeness test passes (0 legacy invocations)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-doc-migration.sh 2>&1 | grep -q 'FAILED: 0'
- [ ] Zero legacy invocations remain (excluding known-good patterns)
  Verify: COUNT=$(grep -r '${CLAUDE_PLUGIN_ROOT}/scripts/' $(git rev-parse --show-toplevel)/skills $(git rev-parse --show-toplevel)/docs/workflows $(git rev-parse --show-toplevel)/CLAUDE.md 2>/dev/null | grep -v 'PLUGIN_SCRIPTS=' | grep -v 'ls.*CLAUDE_PLUGIN_ROOT.*scripts/"' | wc -l | tr -d ' '); [ "$COUNT" -eq 0 ]
- [ ] New .claude/scripts/dso references are present (at least 47 replaced invocations)
  Verify: COUNT=$(grep -r '\.claude/scripts/dso' $(git rev-parse --show-toplevel)/skills $(git rev-parse --show-toplevel)/docs/workflows $(git rev-parse --show-toplevel)/CLAUDE.md 2>/dev/null | wc -l | tr -d ' '); [ "$COUNT" -ge 47 ]


<!-- note-id: v1iotoax -->
<!-- timestamp: 2026-03-17T22:07:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Implemented: migrated legacy script invocations to .claude/scripts/dso <name>
