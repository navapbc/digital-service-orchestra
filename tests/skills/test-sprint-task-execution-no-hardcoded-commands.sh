#!/usr/bin/env bash
# tests/skills/test-sprint-task-execution-no-hardcoded-commands.sh
#
# Structural regression test: assert that task-execution.md contains NO
# hardcoded project-specific commands (make format-check, make lint with
# app/ context, --test-dir=app/tests). These must be replaced with
# {FORMAT_CHECK_CMD}, {LINT_CMD}, and {TEST_CMD} placeholders so the
# sprint orchestrator can inject project-configured values.
#
# Background (bug 30d8-46c6-6616-4ad0): Steps 6 and 8.4 in
# task-execution.md hardcoded make format-check && make lint from app/
# and --test-dir=app/tests, which breaks sub-agent validation for any
# project not using the app/ layout or make-based tooling.
#
# Usage: bash tests/skills/test-sprint-task-execution-no-hardcoded-commands.sh
# Returns: exit 0 on PASS, non-zero on FAIL

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/prompts/task-execution.md"

pass_count=0
fail_count=0

ok()   { echo "ok - $1"; pass_count=$((pass_count + 1)); }
fail() { echo "not ok - $1"; fail_count=$((fail_count + 1)); }

if [[ ! -f "$SKILL_FILE" ]]; then
    echo "not ok - task-execution.md exists at expected path"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. No hardcoded "make format-check" literal
# ---------------------------------------------------------------------------
if grep -n "make format-check" "$SKILL_FILE" 2>/dev/null | grep -v "{FORMAT_CHECK_CMD}" | grep -q .; then
    fail "task-execution.md must not contain hardcoded 'make format-check' (use {FORMAT_CHECK_CMD})"
    grep -n "make format-check" "$SKILL_FILE" | grep -v "{FORMAT_CHECK_CMD}" | while IFS= read -r line; do
        echo "  Found: $line"
    done
else
    ok "task-execution.md does not contain hardcoded 'make format-check'"
fi

# ---------------------------------------------------------------------------
# 2. No hardcoded "make lint" referencing app/ (the project-specific path)
# ---------------------------------------------------------------------------
if grep -n "make lint" "$SKILL_FILE" 2>/dev/null | grep -q "app/"; then
    fail "task-execution.md must not contain hardcoded 'make lint' with app/ path (use {LINT_CMD})"
    grep -n "make lint" "$SKILL_FILE" | grep "app/" | while IFS= read -r line; do
        echo "  Found: $line"
    done
else
    ok "task-execution.md does not contain hardcoded 'make lint' with app/ path"
fi

# ---------------------------------------------------------------------------
# 3. No hardcoded "--test-dir=app/tests" literal
# ---------------------------------------------------------------------------
if grep -n "\-\-test-dir=app/tests" "$SKILL_FILE" 2>/dev/null | grep -q .; then
    fail "task-execution.md must not contain hardcoded '--test-dir=app/tests' (use {TEST_CMD})"
    grep -n "\-\-test-dir=app/tests" "$SKILL_FILE" | while IFS= read -r line; do
        echo "  Found: $line"
    done
else
    ok "task-execution.md does not contain hardcoded '--test-dir=app/tests'"
fi

# ---------------------------------------------------------------------------
# 4. Placeholders {FORMAT_CHECK_CMD}, {LINT_CMD}, {TEST_CMD} are present
# ---------------------------------------------------------------------------
for placeholder in "{FORMAT_CHECK_CMD}" "{LINT_CMD}" "{TEST_CMD}"; do
    if grep -q "$placeholder" "$SKILL_FILE"; then
        ok "task-execution.md contains placeholder $placeholder"
    else
        fail "task-execution.md is missing placeholder $placeholder"
    fi
done

# ---------------------------------------------------------------------------
# 5. sprint SKILL.md resolves FORMAT_CHECK_CMD in its Config Resolution block
# ---------------------------------------------------------------------------
SPRINT_SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
if [[ ! -f "$SPRINT_SKILL" ]]; then
    fail "sprint SKILL.md exists at expected path"
else
    if grep -q "FORMAT_CHECK_CMD" "$SPRINT_SKILL"; then
        ok "sprint SKILL.md resolves FORMAT_CHECK_CMD in Config Resolution block"
    else
        fail "sprint SKILL.md must resolve FORMAT_CHECK_CMD (add: FORMAT_CHECK_CMD=\$(bash \"\$PLUGIN_SCRIPTS/read-config.sh\" commands.format_check))"
    fi
fi

# ---------------------------------------------------------------------------
# 6. sprint SKILL.md dispatch site mentions FORMAT_CHECK_CMD interpolation
# ---------------------------------------------------------------------------
if grep -q "FORMAT_CHECK_CMD\|format_check" "$SPRINT_SKILL"; then
    ok "sprint SKILL.md references FORMAT_CHECK_CMD at dispatch site"
else
    fail "sprint SKILL.md must interpolate {FORMAT_CHECK_CMD} alongside {id} and {escalation_policy} at dispatch"
fi

echo ""
echo "PASSED: $pass_count  FAILED: $fail_count"
test "$fail_count" -eq 0
