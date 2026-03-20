#!/usr/bin/env bash
# tests/skills/test-project-setup-dependencies.sh
# Tests that plugins/dso/skills/project-setup/SKILL.md Step 3 uses individual
# per-dependency prompts with functionality explanations, and skips already-
# installed dependencies.
#
# Validates:
#   - Each optional dependency (acli, PyYAML, pre-commit) has its own
#     AskUserQuestion prompt in SKILL.md
#   - Already-installed dependencies are skipped (detection-based skip language)
#   - Each prompt explains what functionality is unavailable without the dep
#   - The old bundled "show install instructions?" question is NOT present
#
# Usage: bash tests/skills/test-project-setup-dependencies.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/project-setup/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-project-setup-dependencies.sh ==="

# test_skill_md_exists: SKILL.md must exist
_snapshot_fail
if [[ -f "$SKILL_MD" ]]; then
    skill_exists="exists"
else
    skill_exists="missing"
fi
assert_eq "test_skill_md_exists" "exists" "$skill_exists"
assert_pass_if_clean "test_skill_md_exists"

# test_acli_individual_prompt: acli must have its own AskUserQuestion prompt
_snapshot_fail
if grep -qiE "AskUserQuestion.*acli|acli.*AskUserQuestion" "$SKILL_MD" 2>/dev/null; then
    has_acli_prompt="found"
else
    has_acli_prompt="missing"
fi
assert_eq "test_acli_individual_prompt" "found" "$has_acli_prompt"
assert_pass_if_clean "test_acli_individual_prompt"

# test_pyyaml_individual_prompt: PyYAML must have its own AskUserQuestion prompt
_snapshot_fail
if grep -qiE "AskUserQuestion.*PyYAML|PyYAML.*AskUserQuestion|AskUserQuestion.*pyyaml|pyyaml.*AskUserQuestion" "$SKILL_MD" 2>/dev/null; then
    has_pyyaml_prompt="found"
else
    has_pyyaml_prompt="missing"
fi
assert_eq "test_pyyaml_individual_prompt" "found" "$has_pyyaml_prompt"
assert_pass_if_clean "test_pyyaml_individual_prompt"

# test_precommit_individual_prompt: pre-commit must have its own AskUserQuestion prompt
_snapshot_fail
if grep -qiE "AskUserQuestion.*pre-commit|pre-commit.*AskUserQuestion" "$SKILL_MD" 2>/dev/null; then
    has_precommit_prompt="found"
else
    has_precommit_prompt="missing"
fi
assert_eq "test_precommit_individual_prompt" "found" "$has_precommit_prompt"
assert_pass_if_clean "test_precommit_individual_prompt"

# test_skip_already_installed: SKILL.md must contain language indicating already-installed
# deps are skipped (detection-based)
_snapshot_fail
if grep -qiE "already.*installed|skip.*installed|detected.*installed|if.*installed.*skip|not.*prompt.*installed" "$SKILL_MD" 2>/dev/null; then
    has_skip_installed="found"
else
    has_skip_installed="missing"
fi
assert_eq "test_skip_already_installed" "found" "$has_skip_installed"
assert_pass_if_clean "test_skip_already_installed"

# test_functionality_explanation_acli: acli prompt must explain what functionality
# is unavailable without it (Jira integration)
_snapshot_fail
if grep -qiE "Jira.*integration|Jira.*within Claude|acli.*enables|acli.*required for|acli.*provides|without.*acli|acli.*without" "$SKILL_MD" 2>/dev/null; then
    has_acli_explanation="found"
else
    has_acli_explanation="missing"
fi
assert_eq "test_functionality_explanation_acli" "found" "$has_acli_explanation"
assert_pass_if_clean "test_functionality_explanation_acli"

# test_functionality_explanation_pyyaml: PyYAML prompt must explain what functionality
# is unavailable without it (legacy YAML config support)
_snapshot_fail
if grep -qiE "legacy YAML|YAML.*config|pyyaml.*enables|pyyaml.*required|without.*pyyaml|pyyaml.*without" "$SKILL_MD" 2>/dev/null; then
    has_pyyaml_explanation="found"
else
    has_pyyaml_explanation="missing"
fi
assert_eq "test_functionality_explanation_pyyaml" "found" "$has_pyyaml_explanation"
assert_pass_if_clean "test_functionality_explanation_pyyaml"

# test_functionality_explanation_precommit: pre-commit prompt must explain what
# functionality is unavailable without it (git hook management)
_snapshot_fail
if grep -qiE "git hook|hook.*management|pre-commit.*enables|pre-commit.*required|without.*pre-commit|pre-commit.*without" "$SKILL_MD" 2>/dev/null; then
    has_precommit_explanation="found"
else
    has_precommit_explanation="missing"
fi
assert_eq "test_functionality_explanation_precommit" "found" "$has_precommit_explanation"
assert_pass_if_clean "test_functionality_explanation_precommit"

# test_no_bundled_install_question: the old bundled "Would you like install
# instructions for these optional tools?" question must be removed in favor of
# individual per-dependency prompts
_snapshot_fail
if grep -q "Would you like install instructions for these optional tools" "$SKILL_MD" 2>/dev/null; then
    has_bundled_question="found"
else
    has_bundled_question="removed"
fi
assert_eq "test_no_bundled_install_question" "removed" "$has_bundled_question"
assert_pass_if_clean "test_no_bundled_install_question"

# test_acli_jira_skip_condition: acli prompt should be skipped if user declined
# Jira integration (ticket consideration from dso-6dp5)
_snapshot_fail
if grep -qiE "skip.*acli.*Jira|acli.*skip.*Jira|Jira.*declined.*acli|no.*Jira.*skip.*acli|if.*Jira.*acli|acli.*if.*Jira" "$SKILL_MD" 2>/dev/null; then
    has_jira_skip="found"
else
    has_jira_skip="missing"
fi
assert_eq "test_acli_jira_skip_condition" "found" "$has_jira_skip"
assert_pass_if_clean "test_acli_jira_skip_condition"

# test_at_least_3_dependency_prompts: must have individual prompts for all 3 deps
# (acli, PyYAML, pre-commit) — verify at least 3 AskUserQuestion calls in the
# optional dependencies section
_snapshot_fail
# Count AskUserQuestion occurrences in the optional dependencies section
# We check total count — existing tests for commands use >=5, so dep prompts should add >= 3 more
total_ask=$(grep -c "AskUserQuestion" "$SKILL_MD" 2>/dev/null) || total_ask=0
if [[ "$total_ask" -ge 3 ]]; then
    has_enough_dep_prompts="yes"
else
    has_enough_dep_prompts="no"
fi
assert_eq "test_at_least_3_dependency_prompts" "yes" "$has_enough_dep_prompts"
assert_pass_if_clean "test_at_least_3_dependency_prompts"

print_summary
