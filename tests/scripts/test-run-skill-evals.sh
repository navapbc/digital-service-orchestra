#!/usr/bin/env bash
# tests/scripts/test-run-skill-evals.sh
# RED-phase behavioral tests for plugins/dso/scripts/run-skill-evals.sh
#
# Usage: bash tests/scripts/test-run-skill-evals.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: All tests are expected to FAIL until run-skill-evals.sh is implemented
#       (RED phase of TDD). The script under test does not yet exist.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/run-skill-evals.sh"
SKILLS_ROOT="$PLUGIN_ROOT/plugins/dso/skills"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-run-skill-evals.sh ==="

# ── Temp dir setup with EXIT trap cleanup ─────────────────────────────────────
_TEST_TMPDIRS=()
TMPDIR_TEST="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_TEST")
trap 'rm -rf "${_TEST_TMPDIRS[@]}"' EXIT

# ── Helper: create a mock skill directory with an evals/promptfooconfig.yaml ──
# Usage: _make_skill_dir <base_dir> <skill_name>
# Creates: <base_dir>/<skill_name>/evals/promptfooconfig.yaml
_make_skill_dir() {
    local base_dir="$1" skill_name="$2"
    local skill_dir="$base_dir/$skill_name"
    mkdir -p "$skill_dir/evals"
    cat > "$skill_dir/evals/promptfooconfig.yaml" <<YAML
# Mock promptfoo config for $skill_name
description: "$skill_name eval"
providers:
  - openai:gpt-4o
tests:
  - description: "basic test"
    vars:
      input: "hello"
    assert:
      - type: contains
        value: "response"
YAML
}

# ── Helper: write a mock npx into an isolated bin dir ─────────────────────────
# Usage: _make_mock_npx <bin_dir> <exit_code> [stdout_text]
# Creates an isolated npx stub that exits with <exit_code> and optionally
# writes <stdout_text> to stdout. The returned PATH contains only this bin dir
# plus /usr/bin and /bin — the caller's inherited PATH is NOT prepended.
_make_mock_npx() {
    local bin_dir="$1" exit_code="$2" stdout_text="${3:-}"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/npx" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$bin_dir/args.log"
${stdout_text:+printf '%s\n' "$stdout_text"}
exit $exit_code
STUB
    chmod +x "$bin_dir/npx"
}

# ── test_script_exists_and_executable ─────────────────────────────────────────
# The script must exist at the expected path and be executable.
# RED: script not yet created — both assertions fail.

if [[ -f "$SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_script_exists_and_executable: file exists" "exists" "$actual_exists"

if [[ -x "$SCRIPT" ]]; then
    actual_exec="executable"
else
    actual_exec="not_executable"
fi
assert_eq "test_script_exists_and_executable: file is executable" "executable" "$actual_exec"

# ── test_tier1_maps_changed_paths_to_skill_evals ──────────────────────────────
# Tier 1 mode: passing a path inside a skill directory must cause that skill's
# evals/promptfooconfig.yaml to be discovered and npx promptfoo to be invoked.
# Observable: exit 0 (all evals pass) when the mock npx exits 0.
# RED: script does not exist, bash exits non-zero without running any evals.

TMPDIR_TIER1="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_TIER1")

_make_skill_dir "$TMPDIR_TIER1/skills" "fix-bug"
TMPDIR_NPX_TIER1="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NPX_TIER1")
_make_mock_npx "$TMPDIR_NPX_TIER1" 0 '{"results":[],"stats":{"successes":1,"failures":0}}'

ISOLATED_PATH_TIER1="$TMPDIR_NPX_TIER1:/usr/bin:/bin"

tier1_exit=0
tier1_output=""
tier1_output=$(
    DSO_SKILLS_ROOT="$TMPDIR_TIER1/skills" \
    PATH="$ISOLATED_PATH_TIER1" \
    bash "$SCRIPT" "$TMPDIR_TIER1/skills/fix-bug/SKILL.md" 2>&1
) || tier1_exit=$?

assert_eq "test_tier1_maps_changed_paths_to_skill_evals: exit 0 when all evals pass" \
    "0" "$tier1_exit"

# ── test_tier1_multiple_paths_deduplicated ────────────────────────────────────
# When two changed file paths belong to the same skill directory, the script
# must invoke npx for that skill exactly once (deduplicate).
# Observable: the mock npx logs each invocation to a counter file; we assert
# the file contains exactly one entry.
# RED: script does not exist; npx is never called, count file is empty/absent.

TMPDIR_DEDUP="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_DEDUP")
_make_skill_dir "$TMPDIR_DEDUP/skills" "sprint"

CALL_COUNT_FILE="$TMPDIR_DEDUP/call_count"
printf '0' > "$CALL_COUNT_FILE"

TMPDIR_NPX_DEDUP="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NPX_DEDUP")
mkdir -p "$TMPDIR_NPX_DEDUP"
cat > "$TMPDIR_NPX_DEDUP/npx" <<STUB
#!/usr/bin/env bash
count=\$(cat "$CALL_COUNT_FILE")
printf '%d' "\$(( count + 1 ))" > "$CALL_COUNT_FILE"
exit 0
STUB
chmod +x "$TMPDIR_NPX_DEDUP/npx"

ISOLATED_PATH_DEDUP="$TMPDIR_NPX_DEDUP:/usr/bin:/bin"

dedup_exit=0
DSO_SKILLS_ROOT="$TMPDIR_DEDUP/skills" \
PATH="$ISOLATED_PATH_DEDUP" \
bash "$SCRIPT" \
    "$TMPDIR_DEDUP/skills/sprint/SKILL.md" \
    "$TMPDIR_DEDUP/skills/sprint/prompts/plan.md" \
    2>/dev/null || dedup_exit=$?

dedup_call_count="$(cat "$CALL_COUNT_FILE")"
assert_eq "test_tier1_multiple_paths_deduplicated: npx called exactly once for same skill" \
    "1" "$dedup_call_count"

# ── test_tier2_discovers_all_eval_configs ─────────────────────────────────────
# --all mode must discover every evals/promptfooconfig.yaml under the skills
# root and invoke npx promptfoo for each one.
# Observable: mock npx logs every invocation path to a file; we assert both
# skills appear.
# RED: script does not exist; no invocations occur.

TMPDIR_TIER2="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_TIER2")
_make_skill_dir "$TMPDIR_TIER2/skills" "fix-bug"
_make_skill_dir "$TMPDIR_TIER2/skills" "sprint"

CALLS_LOG="$TMPDIR_TIER2/calls.log"
touch "$CALLS_LOG"

TMPDIR_NPX_TIER2="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NPX_TIER2")
mkdir -p "$TMPDIR_NPX_TIER2"
cat > "$TMPDIR_NPX_TIER2/npx" <<STUB
#!/usr/bin/env bash
# Log the config path argument for later assertion
for arg in "\$@"; do
    printf '%s\n' "\$arg" >> "$CALLS_LOG"
done
exit 0
STUB
chmod +x "$TMPDIR_NPX_TIER2/npx"

ISOLATED_PATH_TIER2="$TMPDIR_NPX_TIER2:/usr/bin:/bin"

tier2_exit=0
DSO_SKILLS_ROOT="$TMPDIR_TIER2/skills" \
PATH="$ISOLATED_PATH_TIER2" \
bash "$SCRIPT" --all 2>/dev/null || tier2_exit=$?

assert_eq "test_tier2_discovers_all_eval_configs: exit 0 when all evals pass" \
    "0" "$tier2_exit"

calls_log_content="$(cat "$CALLS_LOG" 2>/dev/null || true)"
# Assert exact config file paths were passed to npx, not just skill name substrings
assert_contains "test_tier2_discovers_all_eval_configs: fix-bug eval config path was passed" \
    "$TMPDIR_TIER2/skills/fix-bug/evals/promptfooconfig.yaml" "$calls_log_content"
assert_contains "test_tier2_discovers_all_eval_configs: sprint eval config path was passed" \
    "$TMPDIR_TIER2/skills/sprint/evals/promptfooconfig.yaml" "$calls_log_content"

# ── test_graceful_exit_when_npx_missing ───────────────────────────────────────
# When npx is not available on PATH the script must exit 2 and emit a message
# that mentions "npx" or "promptfoo" so the operator knows what is missing.
# RED: script does not exist; bash exits 127 with "No such file", not 2.

TMPDIR_NO_NPX="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NO_NPX")
_make_skill_dir "$TMPDIR_NO_NPX/skills" "fix-bug"

# Build a PATH that contains no npx at all — only harmless system dirs.
RESTRICTED_PATH_NO_NPX="$TMPDIR_NO_NPX/empty-bin:/usr/bin:/bin"
mkdir -p "$TMPDIR_NO_NPX/empty-bin"

missing_npx_exit=0
missing_npx_output=""
missing_npx_output=$(
    DSO_SKILLS_ROOT="$TMPDIR_NO_NPX/skills" \
    PATH="$RESTRICTED_PATH_NO_NPX" \
    bash "$SCRIPT" --all 2>&1
) || missing_npx_exit=$?

assert_eq "test_graceful_exit_when_npx_missing: exit 2" \
    "2" "$missing_npx_exit"
assert_contains "test_graceful_exit_when_npx_missing: stderr mentions npx or promptfoo" \
    "npx" "$missing_npx_output"

# ── test_exit_zero_on_all_pass ────────────────────────────────────────────────
# When all invoked npx promptfoo processes exit 0, the orchestrator must also
# exit 0.
# RED: script does not exist; exit is not 0 from the missing-script error.

TMPDIR_ALL_PASS="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_ALL_PASS")
_make_skill_dir "$TMPDIR_ALL_PASS/skills" "fix-bug"
_make_skill_dir "$TMPDIR_ALL_PASS/skills" "sprint"

TMPDIR_NPX_PASS="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NPX_PASS")
_make_mock_npx "$TMPDIR_NPX_PASS" 0 '{"results":[],"stats":{"successes":2,"failures":0}}'
ISOLATED_PATH_PASS="$TMPDIR_NPX_PASS:/usr/bin:/bin"

all_pass_exit=0
DSO_SKILLS_ROOT="$TMPDIR_ALL_PASS/skills" \
PATH="$ISOLATED_PATH_PASS" \
bash "$SCRIPT" --all 2>/dev/null || all_pass_exit=$?

assert_eq "test_exit_zero_on_all_pass: exit 0 when all npx invocations succeed" \
    "0" "$all_pass_exit"

# ── test_exit_nonzero_on_any_failure ──────────────────────────────────────────
# When at least one npx promptfoo process exits 1, the orchestrator must exit
# 1 regardless of the other evals passing.
# RED: script does not exist; exit code comes from the missing-script error
#      (127), not from the orchestrator logic (1).

TMPDIR_ONE_FAIL="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_ONE_FAIL")
_make_skill_dir "$TMPDIR_ONE_FAIL/skills" "fix-bug"
_make_skill_dir "$TMPDIR_ONE_FAIL/skills" "sprint"

# Mock npx that fails for "fix-bug" eval, passes for everything else.
TMPDIR_NPX_FAIL="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NPX_FAIL")
mkdir -p "$TMPDIR_NPX_FAIL"
cat > "$TMPDIR_NPX_FAIL/npx" <<STUB
#!/usr/bin/env bash
# Fail when a fix-bug eval config is referenced; pass otherwise
for arg in "\$@"; do
    if [[ "\$arg" == *"fix-bug"* ]]; then
        exit 1
    fi
done
exit 0
STUB
chmod +x "$TMPDIR_NPX_FAIL/npx"

ISOLATED_PATH_FAIL="$TMPDIR_NPX_FAIL:/usr/bin:/bin"

one_fail_exit=0
DSO_SKILLS_ROOT="$TMPDIR_ONE_FAIL/skills" \
PATH="$ISOLATED_PATH_FAIL" \
bash "$SCRIPT" --all 2>/dev/null || one_fail_exit=$?

assert_eq "test_exit_nonzero_on_any_failure: exit 1 when any npx invocation fails" \
    "1" "$one_fail_exit"

# ── test_skips_skill_without_evals_dir ────────────────────────────────────────
# A skill directory that has no evals/ subdirectory must be silently skipped —
# no error, no exit non-zero.
# Observable: a path inside a skill that has no evals/ must produce exit 0 in
# Tier 1 mode (nothing to run = success with no failures).
# RED: script does not exist; bash exits non-zero.

TMPDIR_NO_EVALS="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NO_EVALS")
# Create a skill dir WITHOUT an evals/ subdirectory
mkdir -p "$TMPDIR_NO_EVALS/skills/brainstorm"
printf 'brainstorm skill\n' > "$TMPDIR_NO_EVALS/skills/brainstorm/SKILL.md"

TMPDIR_NPX_NOEVALS="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NPX_NOEVALS")
_make_mock_npx "$TMPDIR_NPX_NOEVALS" 0
ISOLATED_PATH_NOEVALS="$TMPDIR_NPX_NOEVALS:/usr/bin:/bin"

no_evals_exit=0
no_evals_output=""
no_evals_output=$(
    DSO_SKILLS_ROOT="$TMPDIR_NO_EVALS/skills" \
    PATH="$ISOLATED_PATH_NOEVALS" \
    bash "$SCRIPT" "$TMPDIR_NO_EVALS/skills/brainstorm/SKILL.md" 2>&1
) || no_evals_exit=$?

assert_eq "test_skips_skill_without_evals_dir: exit 0 when skill has no evals/" \
    "0" "$no_evals_exit"

# ── test_eval_config_schema_validation ────────────────────────────────────────
# A promptfooconfig.yaml that is missing required fields (providers and tests)
# must cause the orchestrator to exit non-zero with a message mentioning the
# invalid config.
# Observable: exit code is non-zero; stderr contains a reference to the config
# file path or the word "invalid"/"missing".
# RED: script does not exist; bash exits with "No such file" rather than
#      schema-validation output.

TMPDIR_SCHEMA="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_SCHEMA")
mkdir -p "$TMPDIR_SCHEMA/skills/fix-bug/evals"
# Write a config missing both "providers" and "tests" keys
cat > "$TMPDIR_SCHEMA/skills/fix-bug/evals/promptfooconfig.yaml" <<YAML
description: "incomplete config"
# intentionally omits 'providers' and 'tests'
YAML

TMPDIR_NPX_SCHEMA="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NPX_SCHEMA")
_make_mock_npx "$TMPDIR_NPX_SCHEMA" 0
ISOLATED_PATH_SCHEMA="$TMPDIR_NPX_SCHEMA:/usr/bin:/bin"

schema_exit=0
schema_output=""
schema_output=$(
    DSO_SKILLS_ROOT="$TMPDIR_SCHEMA/skills" \
    PATH="$ISOLATED_PATH_SCHEMA" \
    bash "$SCRIPT" "$TMPDIR_SCHEMA/skills/fix-bug/SKILL.md" 2>&1
) || schema_exit=$?

assert_ne "test_eval_config_schema_validation: exits non-zero for invalid config" \
    "0" "$schema_exit"
# Verify the orchestrator detected the schema error BEFORE invoking npx.
# The mock npx logs args to a file; if validation ran pre-npx, the log stays empty.
schema_npx_log="$TMPDIR_NPX_SCHEMA/args.log"
schema_npx_called="$(cat "$schema_npx_log" 2>/dev/null || echo "")"
assert_eq "test_eval_config_schema_validation: npx not called for invalid config (pre-invocation validation)" \
    "" "$schema_npx_called"

# ── test_grader_config_passthrough ────────────────────────────────────────────
# The orchestrator must NOT override or inject grader configuration that is
# already defined inside promptfooconfig.yaml.
# Observable: the mock npx logs its arguments; we assert that no
# --grader or --provider flag was injected by the orchestrator on top of what
# promptfooconfig.yaml specifies.
# RED: script does not exist; npx is never called, log is absent.

TMPDIR_GRADER="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_GRADER")
_make_skill_dir "$TMPDIR_GRADER/skills" "fix-bug"
# Embed a custom grader in the config
cat >> "$TMPDIR_GRADER/skills/fix-bug/evals/promptfooconfig.yaml" <<YAML

defaultTest:
  options:
    provider: "openai:gpt-4o-mini"
YAML

ARGS_LOG="$TMPDIR_GRADER/args.log"
touch "$ARGS_LOG"

TMPDIR_NPX_GRADER="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NPX_GRADER")
mkdir -p "$TMPDIR_NPX_GRADER"
cat > "$TMPDIR_NPX_GRADER/npx" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGS_LOG"
exit 0
STUB
chmod +x "$TMPDIR_NPX_GRADER/npx"

ISOLATED_PATH_GRADER="$TMPDIR_NPX_GRADER:/usr/bin:/bin"

grader_exit=0
DSO_SKILLS_ROOT="$TMPDIR_GRADER/skills" \
PATH="$ISOLATED_PATH_GRADER" \
bash "$SCRIPT" "$TMPDIR_GRADER/skills/fix-bug/SKILL.md" 2>/dev/null || grader_exit=$?

args_log_content="$(cat "$ARGS_LOG" 2>/dev/null || true)"

# The orchestrator must invoke npx (args log must be non-empty after GREEN)
# and must NOT inject a --grader flag that would override the config.
assert_eq "test_grader_config_passthrough: orchestrator exits 0" \
    "0" "$grader_exit"
assert_ne "test_grader_config_passthrough: npx was invoked (args log non-empty)" \
    "" "$args_log_content"

# Ensure orchestrator did not inject --grader override
grader_flag_found=""
if [[ "$args_log_content" == *"--grader"* ]]; then
    grader_flag_found="--grader found"
fi
assert_eq "test_grader_config_passthrough: no --grader flag injected by orchestrator" \
    "" "$grader_flag_found"

print_summary
