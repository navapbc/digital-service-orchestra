#!/usr/bin/env bash
# tests/docs/test-reviewer-polyglot-compliance.sh
#
# Structural contract test: generated reviewer agents must not contain
# Python-specific tool names (ruff, mypy) in suppression/Do-Not sections.
# Instead, they must reference only language-neutral "configured linter" terms.
#
# This test invokes build-review-agents.sh to regenerate agents into a temp
# directory. If this test fails unexpectedly, check whether build-review-agents.sh
# interface has changed (flags, required env vars).
#
# RED phase: test_generated_agents_contain_no_python_tool_names and
# test_source_templates_contain_no_python_tool_names FAIL because the current
# templates DO contain ruff/mypy terms in suppression/Do-Not sections.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

REVIEWER_BASE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-base.md"
DELTAS_DIR="$REPO_ROOT/plugins/dso/docs/workflows/prompts"
BUILD_SCRIPT="$REPO_ROOT/plugins/dso/scripts/build-review-agents.sh"
VALIDATE_SH="$REPO_ROOT/plugins/dso/scripts/validate.sh"

# ---------------------------------------------------------------------------
# test_generated_agents_contain_no_python_tool_names
#
# Verifies that generated reviewer agent files do not contain Python-specific
# tool names (ruff, mypy) in suppression or Do-Not sections.
#
# Observable behavior: a polyglot-compliant reviewer will suppress "configured
# linter" violations instead of Python-specific tool violations, making the
# suppression guidance apply to all project language stacks.
# ---------------------------------------------------------------------------
echo "=== test_generated_agents_contain_no_python_tool_names ==="

TEMP_AGENTS_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_AGENTS_DIR"' EXIT

# Regenerate agents into the temp directory (side-effect-free)
if ! bash "$BUILD_SCRIPT" \
    --base "$REVIEWER_BASE" \
    --deltas "$DELTAS_DIR" \
    --output "$TEMP_AGENTS_DIR" >/dev/null 2>&1; then
    echo "ERROR: build-review-agents.sh failed — cannot run test" >&2
    (( FAIL++ ))
    echo ""
else
    # Grep all generated agent files for ruff|mypy in suppression/Do-Not sections
    # Use awk to scope to Do Not and Suppression sections only
    python_tool_matches="$(python3 - "$TEMP_AGENTS_DIR" <<'PYEOF'
import sys, re, os, pathlib

agents_dir = sys.argv[1]
matched_files = []

# Pattern to detect Python-specific tool names
tool_pattern = re.compile(r'\b(ruff|mypy)\b', re.IGNORECASE)

# Section headers that delimit suppression/Do-Not scopes
section_start = re.compile(
    r'^##?\s*(Do Not|Do-Not|Linter Suppression|Suppression Rules|suppress)',
    re.IGNORECASE
)
# Any ## header ends the section
section_end = re.compile(r'^##?\s+\S')

for agent_file in sorted(pathlib.Path(agents_dir).glob('*.md')):
    content = agent_file.read_text()
    lines = content.splitlines()
    in_section = False
    for i, line in enumerate(lines):
        if section_start.search(line):
            in_section = True
            continue
        if in_section and i > 0 and section_end.search(line):
            # Another section header ends the scope
            in_section = False
        if in_section and tool_pattern.search(line):
            matched_files.append(f"{agent_file.name}: line {i+1}: {line.strip()}")

for m in matched_files:
    print(m)
PYEOF
)"

    if [[ -z "$python_tool_matches" ]]; then
        assert_eq \
            "generated agents contain no Python tool names (ruff|mypy) in suppression sections" \
            "zero matches" \
            "zero matches"
    else
        # Count matches for diagnostic
        match_count=$(echo "$python_tool_matches" | wc -l | tr -d ' ')
        assert_eq \
            "generated agents contain no Python tool names (ruff|mypy) in suppression sections" \
            "zero matches" \
            "$match_count matches found: $(echo "$python_tool_matches" | head -3)"
    fi
fi

# ---------------------------------------------------------------------------
# test_generated_agents_contain_configured_linter_language
#
# Verifies that generated reviewer agent files contain language-neutral
# "configured linter" or "configured lint" phrasing (at least one per file).
#
# Observable behavior: reviewers use language-neutral suppression guidance
# that applies regardless of the project's linter stack.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_generated_agents_contain_configured_linter_language ==="

if [[ -d "$TEMP_AGENTS_DIR" ]]; then
    missing_files="$(python3 - "$TEMP_AGENTS_DIR" <<'PYEOF'
import sys, re, pathlib

agents_dir = sys.argv[1]
# Pattern matching language-neutral linter references
linter_pattern = re.compile(r'configured linter|configured lint', re.IGNORECASE)

missing = []
for agent_file in sorted(pathlib.Path(agents_dir).glob('*.md')):
    content = agent_file.read_text()
    if not linter_pattern.search(content):
        missing.append(agent_file.name)

for m in missing:
    print(m)
PYEOF
)"

    if [[ -z "$missing_files" ]]; then
        assert_eq \
            "all generated agents contain 'configured linter' language" \
            "all files contain it" \
            "all files contain it"
    else
        file_count=$(echo "$missing_files" | wc -l | tr -d ' ')
        assert_eq \
            "all generated agents contain 'configured linter' language" \
            "all files contain it" \
            "$file_count file(s) missing 'configured linter': $(echo "$missing_files" | head -3)"
    fi
fi

# ---------------------------------------------------------------------------
# test_config_keys_preserved
#
# Verifies that validate.sh references the commands.lint_ruff and
# commands.lint_mypy config keys. These config keys must remain so that
# projects with Python stacks can configure Python-specific linters,
# even as the reviewer templates become language-neutral.
#
# Observable behavior: the configuration contract is preserved for Python
# projects even after the reviewer templates are made polyglot.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_config_keys_preserved ==="

validate_content="$(< "$VALIDATE_SH")"

if [[ "$validate_content" == *"commands.lint_ruff"* ]]; then
    assert_eq \
        "validate.sh contains commands.lint_ruff config key" \
        "present" \
        "present"
else
    assert_eq \
        "validate.sh contains commands.lint_ruff config key" \
        "present" \
        "absent — commands.lint_ruff not found in validate.sh"
fi

if [[ "$validate_content" == *"commands.lint_mypy"* ]]; then
    assert_eq \
        "validate.sh contains commands.lint_mypy config key" \
        "present" \
        "present"
else
    assert_eq \
        "validate.sh contains commands.lint_mypy config key" \
        "present" \
        "absent — commands.lint_mypy not found in validate.sh"
fi

# ---------------------------------------------------------------------------
# test_source_templates_contain_no_python_tool_names
#
# Verifies that reviewer-delta-*.md source files (Linter Suppression Rules
# sections only) and reviewer-base.md (Do Not/suppression sections) contain
# no Python-specific tool names (ruff|mypy).
#
# Observable behavior: the source templates are language-neutral, so any
# project regardless of stack gets appropriate suppression guidance.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_source_templates_contain_no_python_tool_names ==="

# Check reviewer-base.md Do Not / suppression sections
base_matches="$(python3 - "$REVIEWER_BASE" <<'PYEOF'
import sys, re

tool_pattern = re.compile(r'\b(ruff|mypy)\b', re.IGNORECASE)
section_start = re.compile(
    r'^##?\s*(Do Not|Do-Not|Linter Suppression|Suppression Rules|suppress)',
    re.IGNORECASE
)
section_end = re.compile(r'^##?\s+\S')

content = open(sys.argv[1]).read()
lines = content.splitlines()
in_section = False
matches = []
for i, line in enumerate(lines):
    if section_start.search(line):
        in_section = True
        continue
    if in_section and section_end.search(line):
        in_section = False
    if in_section and tool_pattern.search(line):
        matches.append(f"reviewer-base.md line {i+1}: {line.strip()}")

for m in matches:
    print(m)
PYEOF
)"

# Check all reviewer-delta-*.md Linter Suppression Rules sections
delta_matches="$(python3 - "$DELTAS_DIR" <<'PYEOF'
import sys, re, pathlib

tool_pattern = re.compile(r'\b(ruff|mypy)\b', re.IGNORECASE)
section_start = re.compile(
    r'^##?\s*(Linter Suppression|Suppression Rules|suppress)',
    re.IGNORECASE
)
section_end = re.compile(r'^##?\s+\S')

deltas_dir = pathlib.Path(sys.argv[1])
matches = []
for delta_file in sorted(deltas_dir.glob('reviewer-delta-*.md')):
    content = delta_file.read_text()
    lines = content.splitlines()
    in_section = False
    for i, line in enumerate(lines):
        if section_start.search(line):
            in_section = True
            continue
        if in_section and section_end.search(line):
            in_section = False
        if in_section and tool_pattern.search(line):
            matches.append(f"{delta_file.name} line {i+1}: {line.strip()}")

for m in matches:
    print(m)
PYEOF
)"

all_matches=""
[[ -n "$base_matches" ]] && all_matches="$base_matches"
[[ -n "$delta_matches" ]] && all_matches="${all_matches:+$all_matches
}$delta_matches"

if [[ -z "$all_matches" ]]; then
    assert_eq \
        "source templates contain no Python tool names (ruff|mypy) in suppression sections" \
        "zero matches" \
        "zero matches"
else
    match_count=$(echo "$all_matches" | wc -l | tr -d ' ')
    assert_eq \
        "source templates contain no Python tool names (ruff|mypy) in suppression sections" \
        "zero matches" \
        "$match_count matches found: $(echo "$all_matches" | head -3)"
fi

print_summary
