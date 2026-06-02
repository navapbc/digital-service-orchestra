#!/usr/bin/env bash
# tests/scripts/test-review-gate-config-doc-dirs.sh
# Behavioral tests for the `review.non_reviewable_doc_dirs` config key.
#
# A host project can declare additional non-LLM-instruction documentation
# directories (outside the shipped docs/** exemption) that the review gate
# should skip. The key is read in config-paths.sh and consumed by BOTH
# skip-review-check.sh (the skip decision) and compute-diff-hash.sh (the review
# hash) so the two stay consistent. LLM-instruction dirs (skills/, hooks/,
# docs/workflows/, CLAUDE.md, agents/, prompts/) are PROTECTED: listing one in
# the key is ignored (with a stderr warning) in both consumers, so the key can
# never weaken review of agent guidance.
#
# Bug 5ec9-5f36-9851-42e9.
#
# Usage: bash tests/scripts/test-review-gate-config-doc-dirs.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKIP_REVIEW="$DSO_PLUGIN_DIR/scripts/skip-review-check.sh"
COMPUTE_HASH="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"
CONFIG_PATHS="$DSO_PLUGIN_DIR/hooks/lib/config-paths.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
PASS=0
FAIL=0

# Pin CLAUDE_PLUGIN_ROOT to the worktree's plugin dir so the gate scripts source
# the config-paths.sh under test (not an installed/cached copy via an inherited
# CLAUDE_PLUGIN_ROOT). This mirrors a real host project, where CLAUDE_PLUGIN_ROOT
# points at the installed plugin that ships the new dso_sanitized_doc_dirs helper.
export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"

_CLEANUP=()
_cleanup() { for d in "${_CLEANUP[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap _cleanup EXIT

# Write a temp config file with the given body; echo its absolute path.
mk_conf() {
    local f
    f=$(mktemp "${TMPDIR:-/tmp}/dso-doc-dirs-conf.XXXXXX")
    printf '%s\n' "$1" > "$f"
    _CLEANUP+=("$f")
    printf '%s' "$f"
}

# Run skip-review-check.sh with a config + a single candidate file; echo exit code.
# DSO_FORCE_LOCAL_REVIEW=1 disables the dso.workflow=ci-pr short-circuit so the
# classification logic is exercised regardless of ambient config.
skip_exit() {
    printf '%s\n' "$2" | WORKFLOW_CONFIG_FILE="$1" DSO_FORCE_LOCAL_REVIEW=1 bash "$SKIP_REVIEW" >/dev/null 2>&1
    echo $?
}

# Create a fresh git repo with a committed baseline; echo its path.
new_repo() {
    local r
    r=$(mktemp -d "${TMPDIR:-/tmp}/dso-cdh-repo.XXXXXX")
    _CLEANUP+=("$r")
    (
        cd "$r" || exit 1
        git init -q
        git config user.email t@example.com
        git config user.name tester
        mkdir -p src documentation skills
        printf 'base\n' > src/code.py
        printf 'doc\n' > documentation/guide.md
        printf 'skill\n' > skills/s.md
        git add -A
        git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$r"
}

compute_hash() { # repo conf
    ( cd "$1" || exit 1; unset CLAUDE_PLUGIN_ROOT; WORKFLOW_CONFIG_FILE="$2" bash "$COMPUTE_HASH" 2>/dev/null )
}

# ============================================================================
# Part A — configured doc dirs are exempted; force-review + code still reviewed
# ============================================================================
echo "=== Part A: configured doc dirs skip review ==="
CONF_A=$(mk_conf "review.non_reviewable_doc_dirs=documentation,project-docs")

assert_eq "A1: documentation/ file skips review (exit 0)" "0" "$(skip_exit "$CONF_A" "documentation/guide.md")"
assert_eq "A2: nested project-docs/ file skips review (exit 0)" "0" "$(skip_exit "$CONF_A" "project-docs/adr/0001-decision.md")"
assert_eq "A3: code file still requires review (exit 1)" "1" "$(skip_exit "$CONF_A" "src/main.py")"
assert_eq "A4: skills/ file force-reviewed despite config (exit 1)" "1" "$(skip_exit "$CONF_A" "skills/my-skill.md")"
assert_eq "A5: shipped docs/** exemption still works (exit 0)" "0" "$(skip_exit "$CONF_A" "docs/architecture.md")"

# ============================================================================
# Part B — misconfiguration: a protected LLM-instruction dir is ignored + warned
# ============================================================================
echo "=== Part B: protected dir in config is filtered ==="
CONF_B=$(mk_conf "review.non_reviewable_doc_dirs=skills,documentation")

assert_eq "B1: skills/ still force-reviewed when listed in config (exit 1)" "1" "$(skip_exit "$CONF_B" "skills/my-skill.md")"
assert_eq "B2: valid doc dir in same list still exempted (exit 0)" "0" "$(skip_exit "$CONF_B" "documentation/guide.md")"

WARN_B=$(printf 'documentation/guide.md\n' | WORKFLOW_CONFIG_FILE="$CONF_B" DSO_FORCE_LOCAL_REVIEW=1 bash "$SKIP_REVIEW" 2>&1 >/dev/null)
assert_contains "B3: stderr warns that the protected 'skills' entry is ignored" "skills" "$WARN_B"

# ============================================================================
# Part C — absent key preserves baseline behavior (no exemption)
# ============================================================================
echo "=== Part C: absent key preserves baseline ==="
CONF_C=$(mk_conf "paths.app_dir=app")

assert_eq "C1: documentation/ NOT exempt when key absent (exit 1)" "1" "$(skip_exit "$CONF_C" "documentation/guide.md")"

# ============================================================================
# Part D — config-paths.sh helper sanitizes + filters protected dirs
# ============================================================================
echo "=== Part D: dso_sanitized_doc_dirs helper ==="
CONF_D=$(mk_conf "review.non_reviewable_doc_dirs=documentation, skills , project-docs/adr ,, hooks")

SAN_OUT=$(
    unset _CONFIG_PATHS_LOADED CLAUDE_PLUGIN_ROOT
    export WORKFLOW_CONFIG_FILE="$CONF_D"
    # shellcheck disable=SC1090
    source "$CONFIG_PATHS"
    dso_sanitized_doc_dirs 2>/dev/null
)
# Expect exactly the two safe entries (whitespace-trimmed, blanks dropped,
# protected 'skills' and 'hooks' filtered out), one per line.
SAN_EXPECTED=$'documentation\nproject-docs/adr'
assert_eq "D1: helper emits trimmed, protected-filtered dir list" "$SAN_EXPECTED" "$SAN_OUT"
assert_not_contains "D2: helper output excludes protected 'skills'" "skills" "$SAN_OUT"
assert_not_contains "D3: helper output excludes protected 'hooks'" "hooks" "$SAN_OUT"

# ============================================================================
# Part E — compute-diff-hash.sh mirrors the skip decision (hash consistency)
# ============================================================================
echo "=== Part E: compute-diff-hash.sh exclusion + protection ==="

# E1: a configured doc dir is excluded from the review hash.
REPO_E1=$(new_repo)
CONF_E1=$(mk_conf "review.non_reviewable_doc_dirs=documentation")
( cd "$REPO_E1" && printf 'change\n' >> src/code.py && git add -A )
H_CODE_ONLY=$(compute_hash "$REPO_E1" "$CONF_E1")
( cd "$REPO_E1" && printf 'docchange\n' >> documentation/guide.md && git add -A )
H_CODE_PLUS_DOC=$(compute_hash "$REPO_E1" "$CONF_E1")
assert_eq "E1: documentation change does not alter the review hash" "$H_CODE_ONLY" "$H_CODE_PLUS_DOC"

# E2: a protected dir listed in the key is NOT excluded — hash still changes.
REPO_E2=$(new_repo)
CONF_E2=$(mk_conf "review.non_reviewable_doc_dirs=skills")
( cd "$REPO_E2" && printf 'change\n' >> src/code.py && git add -A )
H_BASE=$(compute_hash "$REPO_E2" "$CONF_E2")
( cd "$REPO_E2" && printf 'skillchange\n' >> skills/s.md && git add -A )
H_SKILL=$(compute_hash "$REPO_E2" "$CONF_E2")
assert_ne "E2: skills change alters the hash despite being listed (protected)" "$H_BASE" "$H_SKILL"

print_summary
