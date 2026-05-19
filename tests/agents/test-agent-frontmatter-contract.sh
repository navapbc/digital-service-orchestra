#!/usr/bin/env bash
# tests/agents/test-agent-frontmatter-contract.sh
# SDET audit P1-10: per-agent contract test framework.
#
# Asserts the agent-file YAML-style frontmatter contract for every agent in
# `plugins/dso/agents/*.md`. Today only ~3 dedicated agent tests exist for
# 45 agents (6% ratio). This file provides cheap contract-replay coverage
# that catches prompt-contract drift across the full agent set.
#
# Per-agent contract (verified for every .md under plugins/dso/agents/):
#   - File begins with a YAML frontmatter delimited by `---` on lines 1 and N.
#   - Required keys present: `name`, `description`, `model`.
#   - `model` is one of: haiku, sonnet, opus.
#   - `name` matches the file basename (sans .md).
#
# Usage: bash tests/agents/test-agent-frontmatter-contract.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
AGENTS_DIR="$REPO_ROOT/plugins/dso/agents"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-agent-frontmatter-contract.sh ==="

if [[ ! -d "$AGENTS_DIR" ]]; then
    echo "SKIP: $AGENTS_DIR not found"
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 0
fi

# ─── Test 1 — every agent file has frontmatter with required keys ────────────
echo ""
echo "--- test_every_agent_has_required_frontmatter ---"

test_every_agent_has_required_frontmatter() {
    _snapshot_fail

    local f basename name model description
    local total=0 valid=0
    while IFS= read -r -d '' f; do
        total=$(( total + 1 ))
        basename=$(basename "$f" .md)

        # Frontmatter delimiters
        local first_delim second_delim
        first_delim=$(awk '/^---$/{print NR; exit}' "$f")
        second_delim=$(awk 'NR>1 && /^---$/{print NR; exit}' "$f")
        if [[ "$first_delim" != "1" ]] || [[ -z "$second_delim" ]]; then
            echo "  MISSING_FRONTMATTER: $f" >&2
            continue
        fi

        # Extract required keys from frontmatter region.
        name=$(awk '/^name:/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$f")
        model=$(awk '/^model:/{sub(/^model:[[:space:]]*/, ""); print; exit}' "$f")
        description=$(awk '/^description:/{sub(/^description:[[:space:]]*/, ""); print; exit}' "$f")

        if [[ -z "$name" || -z "$model" || -z "$description" ]]; then
            echo "  MISSING_KEY in $f: name='$name' model='$model' desc='${description:0:40}'" >&2
            continue
        fi

        # Strip surrounding quotes from name for comparison.
        local name_clean="${name//\"/}"
        if [[ "$name_clean" != "$basename" ]]; then
            echo "  NAME_MISMATCH: file=$basename name='$name_clean'" >&2
            continue
        fi

        case "$model" in
            haiku|sonnet|opus) valid=$(( valid + 1 )) ;;
            *)
                echo "  INVALID_MODEL in $f: model='$model' (must be haiku/sonnet/opus)" >&2
                ;;
        esac
    done < <(find "$AGENTS_DIR" -maxdepth 1 -name '*.md' -type f -print0)

    assert_eq "all agent files validate" "$total" "$valid"
    assert_pass_if_clean "test_every_agent_has_required_frontmatter"
}
test_every_agent_has_required_frontmatter

# ─── Test 2 — code-reviewer agents use the expected model tier ───────────────
echo ""
echo "--- test_code_reviewer_models_match_tier_convention ---"

test_code_reviewer_models_match_tier_convention() {
    _snapshot_fail

    # Tier conventions per docs/workflows/REVIEW-WORKFLOW.md:
    #   - dso:code-reviewer-light → haiku
    #   - dso:code-reviewer-standard → sonnet
    #   - dso:code-reviewer-deep-* → sonnet (specialists) / opus (arch)
    local f model expected_model basename
    while IFS= read -r -d '' f; do
        basename=$(basename "$f" .md)
        model=$(awk '/^model:/{sub(/^model:[[:space:]]*/, ""); print; exit}' "$f")
        case "$basename" in
            code-reviewer-light) expected_model=haiku ;;
            code-reviewer-standard) expected_model=sonnet ;;
            code-reviewer-deep-arch) expected_model=opus ;;
            code-reviewer-deep-correctness|code-reviewer-deep-verification|code-reviewer-deep-hygiene)
                expected_model=sonnet
                ;;
            *) continue ;;
        esac
        assert_eq "$basename model=$expected_model" "$expected_model" "$model"
    done < <(find "$AGENTS_DIR" -maxdepth 1 -name 'code-reviewer-*.md' -type f -print0)

    assert_pass_if_clean "test_code_reviewer_models_match_tier_convention"
}
test_code_reviewer_models_match_tier_convention

print_summary
