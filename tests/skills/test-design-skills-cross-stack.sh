#!/usr/bin/env bash
# tests/skills/test-design-skills-cross-stack.sh
# Tests that abstracted design skills (design-wireframe, ui-discover) work
# correctly with non-Flask/Jinja2 stack configurations.
#
# Validates:
#   AC1: node-npm + react config doesn't crash either skill's adapter resolution
#   AC2: Both skills produce meaningful output with an unrecognized adapter (graceful fallback)
#   AC3: Both skills produce full output with Flask/Jinja2 adapter
#   AC4: No hardcoded Flask/Jinja2 references remain in either skill's SKILL.md
#
# Usage: bash tests/skills/test-design-skills-cross-stack.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Cleanup temp directories on any exit path
TMPFILES=()
trap 'rm -rf "${TMPFILES[@]}"' EXIT

DESIGN_WIREFRAME_SKILL="$DSO_PLUGIN_DIR/skills/design-wireframe/SKILL.md"
UI_DISCOVER_SKILL="$DSO_PLUGIN_DIR/skills/ui-discover/SKILL.md"
ADAPTER_DIR="$PLUGIN_ROOT/config/stack-adapters"
READ_CONFIG="$DSO_PLUGIN_DIR/scripts/read-config.sh"

# Resolve a python3 with pyyaml (mirrors read-config.sh logic)
PYTHON=""
for candidate in \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "$REPO_ROOT/.venv/bin/python3" \
    "python3"; do
    [[ "$candidate" != "python3" ]] && [[ ! -f "$candidate" ]] && continue
    if "$candidate" -c "import yaml" 2>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done
if [[ -z "$PYTHON" ]]; then
    echo "SKIP: no python3 with pyyaml found — cannot run adapter resolution tests"
    exit 0
fi

echo "=== test-design-skills-cross-stack.sh ==="

# --------------------------------------------------------------------------
# Helper: resolve_adapter
# Simulates the adapter resolution logic from both SKILL.md files.
# Inputs: $1 = stack, $2 = template_engine
# Output: prints adapter filename or "none"
# Exit code: 0 = success (even if no adapter found), 1 = crash
# --------------------------------------------------------------------------
resolve_adapter() {
    local stack="$1"
    local template_engine="$2"
    local adapter_file=""

    if [[ -n "$template_engine" ]]; then
        for candidate in "$ADAPTER_DIR"/*.yaml; do
            [ -f "$candidate" ] || continue
            local candidate_stack
            local candidate_engine
            candidate_stack=$($PYTHON -c "import yaml; d=yaml.safe_load(open('$candidate')); print(d.get('selector',{}).get('stack',''))" 2>/dev/null)
            candidate_engine=$($PYTHON -c "import yaml; d=yaml.safe_load(open('$candidate')); print(d.get('selector',{}).get('template_engine',''))" 2>/dev/null)
            if [[ "$candidate_stack" == "$stack" && "$candidate_engine" == "$template_engine" ]]; then
                adapter_file="$candidate"
                break
            fi
        done
    fi

    if [[ -n "$adapter_file" ]]; then
        basename "$adapter_file"
    else
        echo "none"
    fi
}

# --------------------------------------------------------------------------
# Helper: create_mock_config
# Creates a temporary dso-config.conf with given stack and template_engine
# Inputs: $1 = stack, $2 = template_engine (optional)
# Output: prints path to temp config file
# --------------------------------------------------------------------------
create_mock_config() {
    local stack="$1"
    local template_engine="${2:-}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    TMPFILES+=("$tmp_dir")
    local config_file="$tmp_dir/dso-config.conf"

    cat > "$config_file" <<EOF
stack=$stack
EOF

    if [[ -n "$template_engine" ]]; then
        cat >> "$config_file" <<EOF
design.template_engine=$template_engine
EOF
    fi

    echo "$config_file"
}

# ==========================================================================
# AC1: node-npm + react config doesn't crash either skill's adapter resolution
# ==========================================================================
echo ""
echo "--- AC1: node-npm + react adapter resolution doesn't crash ---"

# test_node_react_adapter_resolution_no_crash: resolver exits 0
_snapshot_fail
adapter_result=$(resolve_adapter "node-npm" "react" 2>&1)
exit_code=$?
assert_eq "test_node_react_adapter_resolution_no_crash" "0" "$exit_code"
assert_pass_if_clean "test_node_react_adapter_resolution_no_crash"

# test_node_react_returns_no_adapter: should return "none" (no react adapter exists)
_snapshot_fail
assert_eq "test_node_react_returns_no_adapter" "none" "$adapter_result"
assert_pass_if_clean "test_node_react_returns_no_adapter"

# test_node_react_read_config_stack: read-config.sh reads stack from mock config
_snapshot_fail
mock_config=$(create_mock_config "node-npm" "react")
stack_val=$("$READ_CONFIG" "$mock_config" "stack" 2>/dev/null)
rc=$?
assert_eq "test_node_react_read_config_stack_exit" "0" "$rc"
assert_eq "test_node_react_read_config_stack_value" "node-npm" "$stack_val"
assert_pass_if_clean "test_node_react_read_config_stack"

# test_node_react_read_config_template_engine: read-config.sh reads design.template_engine
_snapshot_fail
engine_val=$("$READ_CONFIG" "$mock_config" "design.template_engine" 2>/dev/null)
rc=$?
assert_eq "test_node_react_read_config_engine_exit" "0" "$rc"
assert_eq "test_node_react_read_config_engine_value" "react" "$engine_val"
assert_pass_if_clean "test_node_react_read_config_template_engine"
# Cleanup handled by EXIT trap

# test_empty_template_engine_no_crash: stack with no template_engine is also safe
_snapshot_fail
adapter_result=$(resolve_adapter "node-npm" "" 2>&1)
exit_code=$?
assert_eq "test_empty_template_engine_no_crash" "0" "$exit_code"
assert_eq "test_empty_template_engine_returns_none" "none" "$adapter_result"
assert_pass_if_clean "test_empty_template_engine_no_crash"

# ==========================================================================
# AC2: Both skills produce meaningful output with an unrecognized adapter
# (i.e., fallback warning message pattern is documented in SKILL.md)
# ==========================================================================
echo ""
echo "--- AC2: Skills handle unrecognized adapter gracefully ---"

# test_design_wireframe_is_redirect_stub: design-wireframe SKILL.md is now a redirect stub
# pointing to dso:ui-designer dispatched by preplanning (not a full skill).
_snapshot_fail
if grep -q 'dso:ui-designer' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null && \
   grep -q 'preplanning' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null; then
    is_redirect="is_redirect_stub"
else
    is_redirect="not_redirect_stub"
fi
assert_eq "test_design_wireframe_is_redirect_stub" "is_redirect_stub" "$is_redirect"
assert_pass_if_clean "test_design_wireframe_is_redirect_stub"

# test_ui_discover_has_fallback_warning: SKILL.md documents the fallback warning
_snapshot_fail
if grep -q 'WARNING: No stack adapter found' "$UI_DISCOVER_SKILL" 2>/dev/null; then
    has_fallback="has_fallback"
else
    has_fallback="missing_fallback"
fi
assert_eq "test_ui_discover_has_fallback_warning" "has_fallback" "$has_fallback"
assert_pass_if_clean "test_ui_discover_has_fallback_warning"

# test_design_wireframe_no_sub_agent_guard: redirect stub must not have SUB-AGENT-GUARD
# (redirect stubs do not dispatch sub-agents)
_snapshot_fail
if grep -q 'SUB-AGENT-GUARD' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null; then
    has_guard="has_guard"
else
    has_guard="no_guard"
fi
assert_eq "test_design_wireframe_no_sub_agent_guard" "no_guard" "$has_guard"
assert_pass_if_clean "test_design_wireframe_no_sub_agent_guard"

# test_ui_discover_has_generic_glob_fallback: SKILL.md has generic globs for no-adapter case
_snapshot_fail
if grep -q '\*\*/\*.html' "$UI_DISCOVER_SKILL" 2>/dev/null; then
    has_generic="has_generic_globs"
else
    has_generic="missing_generic_globs"
fi
assert_eq "test_ui_discover_has_generic_glob_fallback" "has_generic_globs" "$has_generic"
assert_pass_if_clean "test_ui_discover_has_generic_glob_fallback"

# test_design_wireframe_redirect_explains_nesting: redirect stub explains why the skill was replaced
_snapshot_fail
if grep -q 'nesting\|nested\|Skill-tool' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null; then
    has_explanation="has_nesting_explanation"
else
    has_explanation="missing_nesting_explanation"
fi
assert_eq "test_design_wireframe_redirect_explains_nesting" "has_nesting_explanation" "$has_explanation"
assert_pass_if_clean "test_design_wireframe_redirect_explains_nesting"

# test_ui_discover_has_heuristic_fallback: mentions heuristic pattern matching
_snapshot_fail
if grep -q 'heuristic' "$UI_DISCOVER_SKILL" 2>/dev/null; then
    has_heuristic="has_heuristic"
else
    has_heuristic="missing_heuristic"
fi
assert_eq "test_ui_discover_has_heuristic_fallback" "has_heuristic" "$has_heuristic"
assert_pass_if_clean "test_ui_discover_has_heuristic_fallback"

# test_ui_discover_has_generic_route_patterns: generic fallback route detection
_snapshot_fail
if grep -q 'generic fallback' "$UI_DISCOVER_SKILL" 2>/dev/null; then
    has_generic_route="has_generic_route"
else
    has_generic_route="missing_generic_route"
fi
assert_eq "test_ui_discover_has_generic_route_patterns" "has_generic_route" "$has_generic_route"
assert_pass_if_clean "test_ui_discover_has_generic_route_patterns"

# ==========================================================================
# AC3: Both skills produce full output with Flask/Jinja2 adapter
# ==========================================================================
echo ""
echo "--- AC3: Flask/Jinja2 adapter resolves correctly ---"

# test_flask_jinja2_adapter_resolves: adapter file is found for python-poetry + jinja2
_snapshot_fail
adapter_result=$(resolve_adapter "python-poetry" "jinja2" 2>&1)
exit_code=$?
assert_eq "test_flask_jinja2_adapter_resolves_exit" "0" "$exit_code"
assert_eq "test_flask_jinja2_adapter_resolves_file" "flask-jinja2.yaml" "$adapter_result"
assert_pass_if_clean "test_flask_jinja2_adapter_resolves"

# test_flask_jinja2_adapter_has_component_patterns: adapter has component_file_patterns
_snapshot_fail
adapter_file="$ADAPTER_DIR/flask-jinja2.yaml"
_tmp=$($PYTHON -c "
import yaml
d = yaml.safe_load(open('$adapter_file'))
cfp = d.get('component_file_patterns', {})
assert 'glob_patterns' in cfp, 'missing glob_patterns'
assert 'definition_patterns' in cfp, 'missing definition_patterns'
assert 'import_patterns' in cfp, 'missing import_patterns'
print('has_patterns')
" 2>/dev/null); if [[ "$_tmp" == *"has_patterns"* ]]; then
    has_cp="has_component_patterns"
else
    has_cp="missing_component_patterns"
fi
assert_eq "test_flask_jinja2_adapter_has_component_patterns" "has_component_patterns" "$has_cp"
assert_pass_if_clean "test_flask_jinja2_adapter_has_component_patterns"

# test_flask_jinja2_adapter_has_route_patterns: adapter has route_patterns
_snapshot_fail
_tmp=$($PYTHON -c "
import yaml
d = yaml.safe_load(open('$adapter_file'))
rp = d.get('route_patterns', {})
assert 'decorator_patterns' in rp, 'missing decorator_patterns'
assert 'template_render_patterns' in rp, 'missing template_render_patterns'
assert 'registration_patterns' in rp, 'missing registration_patterns'
print('has_routes')
" 2>/dev/null); if [[ "$_tmp" == *"has_routes"* ]]; then
    has_rp="has_route_patterns"
else
    has_rp="missing_route_patterns"
fi
assert_eq "test_flask_jinja2_adapter_has_route_patterns" "has_route_patterns" "$has_rp"
assert_pass_if_clean "test_flask_jinja2_adapter_has_route_patterns"

# test_flask_jinja2_adapter_has_template_syntax: adapter has template_syntax
_snapshot_fail
_tmp=$($PYTHON -c "
import yaml
d = yaml.safe_load(open('$adapter_file'))
ts = d.get('template_syntax', {})
assert 'inheritance_pattern' in ts, 'missing inheritance_pattern'
assert 'block_patterns' in ts, 'missing block_patterns'
assert 'include_patterns' in ts, 'missing include_patterns'
print('has_syntax')
" 2>/dev/null); if [[ "$_tmp" == *"has_syntax"* ]]; then
    has_ts="has_template_syntax"
else
    has_ts="missing_template_syntax"
fi
assert_eq "test_flask_jinja2_adapter_has_template_syntax" "has_template_syntax" "$has_ts"
assert_pass_if_clean "test_flask_jinja2_adapter_has_template_syntax"

# test_flask_jinja2_adapter_has_framework_detection: adapter has framework_detection
_snapshot_fail
_tmp=$($PYTHON -c "
import yaml
d = yaml.safe_load(open('$adapter_file'))
fd = d.get('framework_detection', {})
assert 'marker_files' in fd, 'missing marker_files'
assert 'marker_keys' in fd, 'missing marker_keys'
print('has_detection')
" 2>/dev/null); if [[ "$_tmp" == *"has_detection"* ]]; then
    has_fd="has_framework_detection"
else
    has_fd="missing_framework_detection"
fi
assert_eq "test_flask_jinja2_adapter_has_framework_detection" "has_framework_detection" "$has_fd"
assert_pass_if_clean "test_flask_jinja2_adapter_has_framework_detection"

# test_design_wireframe_redirect_has_new_workflow_steps: redirect stub shows how to use new workflow
_snapshot_fail
if grep -q 'dso:ui-designer.*agent\|Agent tool\|ui-designer-dispatch-protocol' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null; then
    has_workflow="has_new_workflow"
else
    has_workflow="missing_new_workflow"
fi
assert_eq "test_design_wireframe_redirect_has_new_workflow_steps" "has_new_workflow" "$has_workflow"
assert_pass_if_clean "test_design_wireframe_redirect_has_new_workflow_steps"

# test_ui_discover_references_adapter_loaded: SKILL.md documents adapter-loaded path
_snapshot_fail
if grep -q 'If.*ADAPTER_FILE.*is set' "$UI_DISCOVER_SKILL" 2>/dev/null; then
    has_loaded_path="has_loaded_path"
else
    has_loaded_path="missing_loaded_path"
fi
assert_eq "test_ui_discover_references_adapter_loaded" "has_loaded_path" "$has_loaded_path"
assert_pass_if_clean "test_ui_discover_references_adapter_loaded"

# ==========================================================================
# AC4: No hardcoded Flask/Jinja2 references remain in either skill's SKILL.md
# (Only adapter-resolution examples and generic fallback docs are allowed)
# ==========================================================================
echo ""
echo "--- AC4: No hardcoded Flask/Jinja2 references in SKILL.md ---"

# test_design_wireframe_no_hardcoded_flask: no Flask references outside adapter resolution
# Allowed references: "flask-jinja2.yaml" (adapter filename example)
# Disallowed: hardcoded "Flask" as assumed framework
_snapshot_fail
# Count lines with Flask/flask that are NOT in adapter examples or comments
hardcoded_flask_count=$(grep -c -i 'flask' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null; true); hardcoded_flask_count=${hardcoded_flask_count:-0}
# The only allowed reference is the adapter filename example "flask-jinja2.yaml"
# Check that all Flask references are in that context
allowed_flask=$(grep -i 'flask' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null | grep -c 'flask-jinja2' 2>/dev/null; true); allowed_flask=${allowed_flask:-0}
non_adapter_flask=$((hardcoded_flask_count - allowed_flask))
if [[ "$non_adapter_flask" -le 0 ]]; then
    no_hardcoded="no_hardcoded_flask"
else
    no_hardcoded="has_hardcoded_flask($non_adapter_flask)"
fi
assert_eq "test_design_wireframe_no_hardcoded_flask" "no_hardcoded_flask" "$no_hardcoded"
assert_pass_if_clean "test_design_wireframe_no_hardcoded_flask"

# test_design_wireframe_no_hardcoded_jinja2: no Jinja2 references
_snapshot_fail
hardcoded_jinja_count=$(grep -c -i 'jinja2\|jinja' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null; true); hardcoded_jinja_count=${hardcoded_jinja_count:-0}
# Allow references that are in the adapter filename example or generic fallback examples
allowed_jinja=$(grep -i 'jinja2\|jinja' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null | grep -c 'flask-jinja2\|Jinja2 adapter' 2>/dev/null; true); allowed_jinja=${allowed_jinja:-0}
non_adapter_jinja=$((hardcoded_jinja_count - allowed_jinja))
if [[ "$non_adapter_jinja" -le 0 ]]; then
    no_hardcoded="no_hardcoded_jinja2"
else
    no_hardcoded="has_hardcoded_jinja2($non_adapter_jinja)"
fi
assert_eq "test_design_wireframe_no_hardcoded_jinja2" "no_hardcoded_jinja2" "$no_hardcoded"
assert_pass_if_clean "test_design_wireframe_no_hardcoded_jinja2"

# test_ui_discover_no_hardcoded_flask: no Flask references outside adapter examples
_snapshot_fail
hardcoded_flask_count=$(grep -c -i 'flask' "$UI_DISCOVER_SKILL" 2>/dev/null; true); hardcoded_flask_count=${hardcoded_flask_count:-0}
# Allowed: "flask-jinja2.yaml" examples, and "5000 for Flask" (generic port fallback docs)
allowed_flask=$(grep -i 'flask' "$UI_DISCOVER_SKILL" 2>/dev/null | grep -c 'flask-jinja2\|for Flask' 2>/dev/null; true); allowed_flask=${allowed_flask:-0}
non_adapter_flask=$((hardcoded_flask_count - allowed_flask))
if [[ "$non_adapter_flask" -le 0 ]]; then
    no_hardcoded="no_hardcoded_flask"
else
    no_hardcoded="has_hardcoded_flask($non_adapter_flask)"
fi
assert_eq "test_ui_discover_no_hardcoded_flask" "no_hardcoded_flask" "$no_hardcoded"
assert_pass_if_clean "test_ui_discover_no_hardcoded_flask"

# test_ui_discover_no_hardcoded_jinja2: no Jinja2 references outside adapter/fallback docs
_snapshot_fail
hardcoded_jinja_count=$(grep -c -i 'jinja2\|jinja' "$UI_DISCOVER_SKILL" 2>/dev/null; true); hardcoded_jinja_count=${hardcoded_jinja_count:-0}
# Allowed: "Jinja2-like" in generic fallback patterns section, "flask-jinja2"
allowed_jinja=$(grep -i 'jinja2\|jinja' "$UI_DISCOVER_SKILL" 2>/dev/null | grep -c 'flask-jinja2\|Jinja2-like\|Jinja2 templates\|for Jinja2' 2>/dev/null; true); allowed_jinja=${allowed_jinja:-0}
non_adapter_jinja=$((hardcoded_jinja_count - allowed_jinja))
if [[ "$non_adapter_jinja" -le 0 ]]; then
    no_hardcoded="no_hardcoded_jinja2"
else
    no_hardcoded="has_hardcoded_jinja2($non_adapter_jinja)"
fi
assert_eq "test_ui_discover_no_hardcoded_jinja2" "no_hardcoded_jinja2" "$no_hardcoded"
assert_pass_if_clean "test_ui_discover_no_hardcoded_jinja2"

# test_design_wireframe_redirect_points_to_preplanning: redirect stub directs users to preplanning
# (design-wireframe is now a redirect stub; the config-driven adapter is in dso:ui-designer)
_snapshot_fail
if grep -q '/dso:preplanning' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null || \
   grep -q 'preplanning' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null; then
    redirect_ok="redirect_ok"
else
    redirect_ok="redirect_missing"
fi
assert_eq "test_design_wireframe_redirect_points_to_preplanning" "redirect_ok" "$redirect_ok"
assert_pass_if_clean "test_design_wireframe_redirect_points_to_preplanning"

# test_ui_discover_uses_config_driven_adapter: SKILL.md mentions config-driven
_snapshot_fail
if grep -q 'config-driven stack adapter' "$UI_DISCOVER_SKILL" 2>/dev/null; then
    config_driven="config_driven"
else
    config_driven="not_config_driven"
fi
assert_eq "test_ui_discover_uses_config_driven_adapter" "config_driven" "$config_driven"
assert_pass_if_clean "test_ui_discover_uses_config_driven_adapter"

# ==========================================================================
# Additional: cross-stack adapter resolution for other stacks
# ==========================================================================
echo ""
echo "--- Additional: other unrecognized stacks don't crash ---"

# test_go_gin_no_crash: go stack with no template engine
_snapshot_fail
adapter_result=$(resolve_adapter "go-mod" "" 2>&1)
exit_code=$?
assert_eq "test_go_gin_no_crash_exit" "0" "$exit_code"
assert_eq "test_go_gin_no_crash_result" "none" "$adapter_result"
assert_pass_if_clean "test_go_gin_no_crash"

# test_rust_yew_no_crash: rust stack with yew template engine
_snapshot_fail
adapter_result=$(resolve_adapter "rust-cargo" "yew" 2>&1)
exit_code=$?
assert_eq "test_rust_yew_no_crash_exit" "0" "$exit_code"
assert_eq "test_rust_yew_no_crash_result" "none" "$adapter_result"
assert_pass_if_clean "test_rust_yew_no_crash"

# test_django_no_crash: python-poetry + django templates
_snapshot_fail
adapter_result=$(resolve_adapter "python-poetry" "django" 2>&1)
exit_code=$?
assert_eq "test_django_no_crash_exit" "0" "$exit_code"
assert_eq "test_django_no_crash_result" "none" "$adapter_result"
assert_pass_if_clean "test_django_no_crash"

print_summary
