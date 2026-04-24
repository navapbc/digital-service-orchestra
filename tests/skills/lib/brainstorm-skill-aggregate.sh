#!/usr/bin/env bash
# brainstorm-skill-aggregate.sh
#
# Helper for brainstorm skill tests that assert content-presence across the skill
# corpus. After the skill-refactor that split /dso:brainstorm into phase files,
# tests that grep SKILL.md alone miss content that moved to phases/*.md.
#
# Source this file and call `brainstorm_aggregate_path` to get the path to a
# temp file containing SKILL.md + all phases/*.md + verifiable-sc-check.md.
# The caller is responsible for cleanup (or can use `brainstorm_aggregate_cleanup`
# with trap EXIT).
#
# Usage:
#   source "$REPO_ROOT/tests/skills/lib/brainstorm-skill-aggregate.sh"
#   SKILL_CORPUS=$(brainstorm_aggregate_path)
#   trap brainstorm_aggregate_cleanup EXIT
#   grep -q 'RESEARCH_FINDINGS:' "$SKILL_CORPUS"
#
# This does NOT replace SKILL.md-specific assertions (e.g., "the Type Detection
# Gate in SKILL.md delegates rather than inlining") — use $SKILL_MD for those.

_BRAINSTORM_AGG_FILE=""

brainstorm_aggregate_path() {
    if [ -n "$_BRAINSTORM_AGG_FILE" ] && [ -f "$_BRAINSTORM_AGG_FILE" ]; then
        echo "$_BRAINSTORM_AGG_FILE"
        return 0
    fi
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    local skill_dir="$repo_root/plugins/dso/skills/brainstorm"
    local shared_check="$repo_root/plugins/dso/skills/shared/prompts/verifiable-sc-check.md"
    _BRAINSTORM_AGG_FILE=$(mktemp)
    cat "$skill_dir/SKILL.md" > "$_BRAINSTORM_AGG_FILE"
    if [ -d "$skill_dir/phases" ]; then
        for _p in "$skill_dir/phases"/*.md; do
            printf '\n' >> "$_BRAINSTORM_AGG_FILE"
            cat "$_p" >> "$_BRAINSTORM_AGG_FILE"
        done
    fi
    if [ -f "$shared_check" ]; then
        printf '\n' >> "$_BRAINSTORM_AGG_FILE"
        cat "$shared_check" >> "$_BRAINSTORM_AGG_FILE"
    fi
    echo "$_BRAINSTORM_AGG_FILE"
}

brainstorm_aggregate_cleanup() {
    if [ -n "$_BRAINSTORM_AGG_FILE" ] && [ -f "$_BRAINSTORM_AGG_FILE" ]; then
        rm -f "$_BRAINSTORM_AGG_FILE"
        _BRAINSTORM_AGG_FILE=""
    fi
}
