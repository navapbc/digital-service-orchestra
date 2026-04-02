#!/usr/bin/env bash
# tests/scripts/test-generate-skill-eval.sh
# RED-phase behavioral tests for plugins/dso/scripts/generate-skill-eval.sh
#
# Usage: bash tests/scripts/test-generate-skill-eval.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: All tests are expected to FAIL until generate-skill-eval.sh is implemented
#       (RED phase of TDD). The script under test does not yet exist.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/generate-skill-eval.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-generate-skill-eval.sh ==="

# ── Temp dir setup with EXIT trap cleanup ─────────────────────────────────────
_TEST_TMPDIRS=()
trap 'rm -rf "${_TEST_TMPDIRS[@]}"' EXIT

# ── Helper: create a skill directory with a SKILL.md ──────────────────────────
# Usage: _make_skill_dir <skills_root> <skill_name> <skill_md_content>
# Returns the full path to the skill directory via stdout.
_make_skill_dir() {
    local skills_root="$1" skill_name="$2" skill_md_content="$3"
    local skill_dir="$skills_root/$skill_name"
    mkdir -p "$skill_dir"
    printf '%s\n' "$skill_md_content" > "$skill_dir/SKILL.md"
    printf '%s\n' "$skill_dir"
}

# ── test_happy_path_frontmatter ────────────────────────────────────────────────
# When SKILL.md has a YAML frontmatter block with a "description" field, the
# script must extract it and generate evals/promptfooconfig.yaml containing
# top-level "providers:" and "tests:" keys plus at least one TODO llm-rubric
# assertion.
# Observable: exit 0; evals/promptfooconfig.yaml exists and is valid YAML with
#             required keys.
# RED: script does not exist — bash exits 127.

echo ""
echo "test_happy_path_frontmatter"

TMPDIR_FM="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_FM")

FM_CONTENT='---
description: "Diagnose and fix bugs using TDD methodology"
version: "1.0"
---
# Fix Bug Skill

## Overview

This skill fixes bugs.'

_make_skill_dir "$TMPDIR_FM/skills" "fix-bug" "$FM_CONTENT" > /dev/null

fm_exit=0
fm_output=""
fm_output=$(
    bash "$SCRIPT" \
        --skills-root "$TMPDIR_FM/skills" \
        "fix-bug" 2>&1
) || fm_exit=$?

assert_eq "test_happy_path_frontmatter: exits 0" "0" "$fm_exit"

fm_config="$TMPDIR_FM/skills/fix-bug/evals/promptfooconfig.yaml"
if [[ -f "$fm_config" ]]; then
    fm_has_providers=$(python3 -c "
import yaml, sys
data = yaml.safe_load(open('$fm_config'))
print('yes' if 'providers' in data else 'no')
" 2>/dev/null || echo "error")
    fm_has_tests=$(python3 -c "
import yaml, sys
data = yaml.safe_load(open('$fm_config'))
print('yes' if 'tests' in data else 'no')
" 2>/dev/null || echo "error")
    fm_has_todo=$(python3 -c "
import yaml, sys
content = open('$fm_config').read()
print('yes' if 'TODO' in content else 'no')
" 2>/dev/null || echo "error")
    fm_has_rubric=$(python3 -c "
import yaml, sys
content = open('$fm_config').read()
print('yes' if 'llm-rubric' in content else 'no')
" 2>/dev/null || echo "error")
    assert_eq "test_happy_path_frontmatter: generated YAML has providers key" "yes" "$fm_has_providers"
    assert_eq "test_happy_path_frontmatter: generated YAML has tests key" "yes" "$fm_has_tests"
    assert_eq "test_happy_path_frontmatter: generated YAML has TODO marker" "yes" "$fm_has_todo"
    assert_eq "test_happy_path_frontmatter: generated YAML has llm-rubric assertion" "yes" "$fm_has_rubric"
    fm_has_desc=$(python3 -c "
import yaml, sys
content = open('$fm_config').read()
print('yes' if 'bug' in content.lower() or 'fix' in content.lower() else 'no')
" 2>/dev/null || echo "error")
    assert_eq "test_happy_path_frontmatter: generated YAML incorporates skill description" "yes" "$fm_has_desc"
else
    assert_eq "test_happy_path_frontmatter: evals/promptfooconfig.yaml was created" "exists" "missing"
fi

# ── test_happy_path_h2 ────────────────────────────────────────────────────────
# When SKILL.md has no frontmatter but has an H2 section, the script must
# extract the first H2 heading content and use it as the description for the
# generated YAML.
# Observable: exit 0; evals/promptfooconfig.yaml is created with providers and tests.
# RED: script does not exist — bash exits 127.

echo ""
echo "test_happy_path_h2"

TMPDIR_H2="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_H2")

H2_CONTENT='# Sprint Skill

## Orchestrate multi-story feature sprints end to end

This skill drives sprint execution from epic decomposition through delivery.'

_make_skill_dir "$TMPDIR_H2/skills" "sprint" "$H2_CONTENT" > /dev/null

h2_exit=0
h2_output=$(
    bash "$SCRIPT" \
        --skills-root "$TMPDIR_H2/skills" \
        "sprint" 2>&1
) || h2_exit=$?

assert_eq "test_happy_path_h2: exits 0" "0" "$h2_exit"

h2_config="$TMPDIR_H2/skills/sprint/evals/promptfooconfig.yaml"
if [[ -f "$h2_config" ]]; then
    h2_valid=$(python3 -c "
import yaml
data = yaml.safe_load(open('$h2_config'))
has_both = 'providers' in data and 'tests' in data
print('yes' if has_both else 'no')
" 2>/dev/null || echo "error")
    assert_eq "test_happy_path_h2: generated YAML has providers and tests" "yes" "$h2_valid"
else
    assert_eq "test_happy_path_h2: evals/promptfooconfig.yaml was created" "exists" "missing"
fi

# ── test_error_nonexistent_skill ──────────────────────────────────────────────
# When the named skill directory does not exist under the skills root, the
# script must exit 1 and emit a stderr message that includes the skill name and
# the phrase "not found" (or equivalent).
# Observable: exit code 1; stderr contains skill name and "not found".
# RED: script does not exist — bash exits 127 with "No such file", not 1.

echo ""
echo "test_error_nonexistent_skill"

TMPDIR_NOSK="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NOSK")
mkdir -p "$TMPDIR_NOSK/skills"

nosk_exit=0
nosk_output=$(
    bash "$SCRIPT" \
        --skills-root "$TMPDIR_NOSK/skills" \
        "nonexistent-skill-xyz" 2>&1
) || nosk_exit=$?

assert_eq "test_error_nonexistent_skill: exits 1" "1" "$nosk_exit"
assert_contains "test_error_nonexistent_skill: stderr includes skill name" \
    "nonexistent-skill-xyz" "$nosk_output"
assert_contains "test_error_nonexistent_skill: stderr includes not found" \
    "not found" "$nosk_output"

# ── test_error_no_description ─────────────────────────────────────────────────
# When SKILL.md exists but contains neither a frontmatter "description" field
# nor any H2 section, the script must exit 1 and emit a stderr message that
# includes "no parseable description" or equivalent.
# Observable: exit code 1; stderr contains indication of missing description.
# RED: script does not exist — bash exits 127.

echo ""
echo "test_error_no_description"

TMPDIR_NODESC="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_NODESC")

NODESC_CONTENT='# My Skill

Some content with no H2 headings and no frontmatter.

Just plain text paragraphs.'

_make_skill_dir "$TMPDIR_NODESC/skills" "no-desc-skill" "$NODESC_CONTENT" > /dev/null

nodesc_exit=0
nodesc_stderr=""
nodesc_stderr=$(
    bash "$SCRIPT" \
        --skills-root "$TMPDIR_NODESC/skills" \
        "no-desc-skill" 2>&1
) || nodesc_exit=$?

assert_eq "test_error_no_description: exits 1" "1" "$nodesc_exit"
assert_contains "test_error_no_description: stderr mentions no parseable description" \
    "no parseable description" "$nodesc_stderr"

# ── test_error_existing_config ────────────────────────────────────────────────
# When evals/promptfooconfig.yaml already exists in the skill directory, the
# script must exit 1 and emit a stderr message that includes "already exists".
# Observable: exit code 1; stderr contains "already exists"; the existing file
#             is NOT overwritten (content unchanged).
# RED: script does not exist — bash exits 127.

echo ""
echo "test_error_existing_config"

TMPDIR_EXISTS="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_EXISTS")

EXISTS_SKILL_CONTENT='---
description: "Some existing skill"
---
# Existing Skill

## Does things'

_make_skill_dir "$TMPDIR_EXISTS/skills" "existing-skill" "$EXISTS_SKILL_CONTENT" > /dev/null

# Pre-create the evals config to trigger the error
mkdir -p "$TMPDIR_EXISTS/skills/existing-skill/evals"
EXISTING_SENTINEL="SENTINEL_CONTENT_DO_NOT_OVERWRITE"
printf '%s\n' "$EXISTING_SENTINEL" > "$TMPDIR_EXISTS/skills/existing-skill/evals/promptfooconfig.yaml"

exists_exit=0
exists_stderr=""
exists_stderr=$(
    bash "$SCRIPT" \
        --skills-root "$TMPDIR_EXISTS/skills" \
        "existing-skill" 2>&1
) || exists_exit=$?

assert_eq "test_error_existing_config: exits 1" "1" "$exists_exit"
assert_contains "test_error_existing_config: stderr includes already exists" \
    "already exists" "$exists_stderr"

# Verify existing file was NOT overwritten
existing_content="$(cat "$TMPDIR_EXISTS/skills/existing-skill/evals/promptfooconfig.yaml" 2>/dev/null || echo "")"
assert_contains "test_error_existing_config: existing file content preserved" \
    "$EXISTING_SENTINEL" "$existing_content"

# ── test_fence_aware_h2 ───────────────────────────────────────────────────────
# When SKILL.md contains a fenced code block that itself has a line starting
# with "## ", the script must not treat that as an H2 heading. Only real H2
# headings outside code fences should be used for description extraction.
# Observable: exit 0; the generated description uses the real H2, not the fake one.
# RED: script does not exist — bash exits 127.

echo ""
echo "test_fence_aware_h2"

TMPDIR_FENCE="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_FENCE")

FENCE_CONTENT='# My Skill

Here is an example script:

```bash
## Fake H2 inside code block — should be ignored
echo "hello"
```

## Real H2 description for the skill

Actual description text here.'

_make_skill_dir "$TMPDIR_FENCE/skills" "fence-skill" "$FENCE_CONTENT" > /dev/null

fence_exit=0
fence_output=""
fence_output=$(
    bash "$SCRIPT" \
        --skills-root "$TMPDIR_FENCE/skills" \
        "fence-skill" 2>&1
) || fence_exit=$?

assert_eq "test_fence_aware_h2: exits 0 (real H2 extracted)" "0" "$fence_exit"

fence_config="$TMPDIR_FENCE/skills/fence-skill/evals/promptfooconfig.yaml"
if [[ -f "$fence_config" ]]; then
    # The description should contain "Real H2 description" not "Fake H2"
    fence_desc_content=$(python3 -c "
import yaml
data = yaml.safe_load(open('$fence_config'))
content = str(data)
print(content)
" 2>/dev/null || echo "")
    fake_found=""
    [[ "$fence_desc_content" == *"Fake H2"* ]] && fake_found="yes"
    assert_eq "test_fence_aware_h2: fake H2 inside code block not used as description" \
        "" "$fake_found"

    real_found=""
    real_config_content=$(cat "$fence_config")
    [[ "$real_config_content" == *"Real H2"* ]] && real_found="yes"
    assert_eq "test_fence_aware_h2: real H2 heading is reflected in output" \
        "yes" "$real_found"
else
    assert_eq "test_fence_aware_h2: evals/promptfooconfig.yaml was created" "exists" "missing"
fi

# ── test_yaml_escaping ────────────────────────────────────────────────────────
# When SKILL.md description contains colons, double quotes, and embedded
# newlines, the generated YAML must be valid (round-trips through a YAML parser
# without error) and the description value must be preserved intact.
# Observable: exit 0; python3 yaml.safe_load succeeds on the output file.
# RED: script does not exist — bash exits 127.

echo ""
echo "test_yaml_escaping"

TMPDIR_ESC="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_ESC")

ESC_CONTENT='---
description: "Handles edge cases: colons, \"quotes\", and special chars like & % @"
---
# Escaping Skill

## Does: complex "escaping" with colons & special chars'

_make_skill_dir "$TMPDIR_ESC/skills" "escaping-skill" "$ESC_CONTENT" > /dev/null

esc_exit=0
esc_output=$(
    bash "$SCRIPT" \
        --skills-root "$TMPDIR_ESC/skills" \
        "escaping-skill" 2>&1
) || esc_exit=$?

assert_eq "test_yaml_escaping: exits 0" "0" "$esc_exit"

esc_config="$TMPDIR_ESC/skills/escaping-skill/evals/promptfooconfig.yaml"
if [[ -f "$esc_config" ]]; then
    esc_parse_exit=0
    esc_parse_result=$(python3 -c "
import yaml, sys
try:
    data = yaml.safe_load(open('$esc_config'))
    print('valid')
except yaml.YAMLError as e:
    print('invalid: ' + str(e))
    sys.exit(1)
" 2>/dev/null) || esc_parse_exit=$?
    assert_eq "test_yaml_escaping: generated YAML parses without error" "0" "$esc_parse_exit"
    assert_eq "test_yaml_escaping: yaml.safe_load returns valid" "valid" "$esc_parse_result"
else
    assert_eq "test_yaml_escaping: evals/promptfooconfig.yaml was created" "exists" "missing"
fi

# ── test_atomic_write ─────────────────────────────────────────────────────────
# On the success path, the script must not leave a partial output file when
# interrupted. This is verified indirectly: after a successful run the output
# file must exist and be non-empty (confirming atomic write completed), and on
# the error path (existing config) no new file should be created in a tmp
# location inside the evals/ directory.
# Observable: after successful run — evals/promptfooconfig.yaml is non-empty;
#             after error run — no tmp files remain in evals/.
# RED: script does not exist — neither condition can be checked.

echo ""
echo "test_atomic_write"

TMPDIR_ATOMIC="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_ATOMIC")

ATOMIC_CONTENT='---
description: "Atomic write test skill"
---
# Atomic Skill'

_make_skill_dir "$TMPDIR_ATOMIC/skills" "atomic-skill" "$ATOMIC_CONTENT" > /dev/null

atomic_exit=0
bash "$SCRIPT" \
    --skills-root "$TMPDIR_ATOMIC/skills" \
    "atomic-skill" 2>/dev/null || atomic_exit=$?

assert_eq "test_atomic_write: script exits 0 on success path" "0" "$atomic_exit"

atomic_config="$TMPDIR_ATOMIC/skills/atomic-skill/evals/promptfooconfig.yaml"
if [[ -f "$atomic_config" ]]; then
    atomic_size=$(wc -c < "$atomic_config" | tr -d ' ')
    assert_ne "test_atomic_write: output file is non-empty (write completed)" "0" "$atomic_size"

    # Verify no tmp/partial files remain alongside the output
    atomic_tmp_count=$(find "$TMPDIR_ATOMIC/skills/atomic-skill/evals/" \
        -name "*.tmp" -o -name ".tmp*" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "test_atomic_write: no leftover tmp files in evals/" "0" "$atomic_tmp_count"
else
    assert_eq "test_atomic_write: evals/promptfooconfig.yaml was created" "exists" "missing"
fi

# ── test_help_flag ────────────────────────────────────────────────────────────
# When invoked with --help, the script must print usage information to stdout
# (or stderr) and exit 0.
# Observable: exit code 0; output contains "Usage" or "usage".
# RED: script does not exist — bash exits 127.

echo ""
echo "test_help_flag"

help_exit=0
help_output=""
help_output=$(bash "$SCRIPT" --help 2>&1) || help_exit=$?

assert_eq "test_help_flag: --help exits 0" "0" "$help_exit"
assert_contains "test_help_flag: --help output mentions Usage" "sage" "$help_output"

# ── test_structural_validity ──────────────────────────────────────────────────
# The generated YAML must have top-level "providers" and "tests" keys, matching
# the structure expected by _validate_config and promptfoo.
# Observable: exit 0; python3 yaml.safe_load confirms both keys exist at
#             top level with non-empty values.
# RED: script does not exist — bash exits 127.

echo ""
echo "test_structural_validity"

TMPDIR_STRUCT="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_STRUCT")

STRUCT_CONTENT='---
description: "Structural validity test skill"
---
# Struct Skill

## Validates YAML structure of generated evals config'

_make_skill_dir "$TMPDIR_STRUCT/skills" "struct-skill" "$STRUCT_CONTENT" > /dev/null

struct_exit=0
bash "$SCRIPT" \
    --skills-root "$TMPDIR_STRUCT/skills" \
    "struct-skill" 2>/dev/null || struct_exit=$?

assert_eq "test_structural_validity: exits 0" "0" "$struct_exit"

struct_config="$TMPDIR_STRUCT/skills/struct-skill/evals/promptfooconfig.yaml"
if [[ -f "$struct_config" ]]; then
    struct_check=$(python3 -c "
import yaml, sys
data = yaml.safe_load(open('$struct_config'))
errors = []
if 'providers' not in data:
    errors.append('missing top-level providers key')
elif not data['providers']:
    errors.append('providers is empty')
if 'tests' not in data:
    errors.append('missing top-level tests key')
elif not data['tests']:
    errors.append('tests is empty')
if errors:
    print('FAIL: ' + '; '.join(errors))
    sys.exit(1)
print('ok')
" 2>/dev/null || echo "parse-error")
    assert_eq "test_structural_validity: providers and tests keys present and non-empty" \
        "ok" "$struct_check"
else
    assert_eq "test_structural_validity: evals/promptfooconfig.yaml was created" "exists" "missing"
fi

print_summary
