#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PLUGIN_ROOT/tests/lib/assert.sh"
echo "=== test-preconditions-fallthrough-landmarks.sh ==="

test_brainstorm_cluster_landmarks() {
    local _files=(
        "plugins/dso/skills/brainstorm/SKILL.md"
        "plugins/dso/skills/brainstorm/phases/approval-gate.md"
    )
    for _f in "${_files[@]}"; do
        if [[ -f "$PLUGIN_ROOT/$_f" ]]; then
            local _found="no"
            grep -q 'EMIT-PRECONDITIONS' "$PLUGIN_ROOT/$_f" && _found="yes"
            assert_eq "EMIT-PRECONDITIONS marker present in $_f" "yes" "$_found"
        fi
    done
}

test_sprint_cluster_landmarks() {
    local _files=(
        "plugins/dso/skills/sprint/SKILL.md"
        "plugins/dso/skills/sprint/prompts/auto-resume.md"
        "plugins/dso/skills/sprint/prompts/test-failure-dispatch-protocol.md"
    )
    for _f in "${_files[@]}"; do
        if [[ -f "$PLUGIN_ROOT/$_f" ]]; then
            local _found="no"
            grep -q 'EMIT-PRECONDITIONS' "$PLUGIN_ROOT/$_f" && _found="yes"
            assert_eq "EMIT-PRECONDITIONS marker present in $_f" "yes" "$_found"
        fi
    done
}

test_remaining_cluster_landmarks() {
    local _files=(
        "plugins/dso/skills/preplanning/SKILL.md"
        "plugins/dso/skills/implementation-plan/SKILL.md"
        "plugins/dso/skills/debug-everything/SKILL.md"
        "plugins/dso/skills/fix-bug/SKILL.md"
        "plugins/dso/skills/validate-work/SKILL.md"
        "plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"
    )
    for _f in "${_files[@]}"; do
        if [[ -f "$PLUGIN_ROOT/$_f" ]]; then
            local _found="no"
            grep -q 'EMIT-PRECONDITIONS' "$PLUGIN_ROOT/$_f" && _found="yes"
            assert_eq "EMIT-PRECONDITIONS marker present in $_f" "yes" "$_found"
        fi
    done
}

test_brainstorm_cluster_landmarks
test_sprint_cluster_landmarks
test_remaining_cluster_landmarks

print_summary
