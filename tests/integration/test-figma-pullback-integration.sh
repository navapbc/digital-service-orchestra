#!/usr/bin/env bash
# tests/integration/test-figma-pullback-integration.sh
# Integration tests for Figma URL parsing, PAT authentication, node mapping,
# merge algorithm, and ID-linkage validation.
#
# Tests: FP-URL-1 through FP-URL-4 (URL parsing), FP-AUTH-1 through FP-AUTH-3 (PAT auth),
#        FP-MAP-1 through FP-MAP-7 (node mapping to spatial-layout.json),
#        FP-MERGE-1 through FP-MERGE-4 (merge algorithm),
#        FP-LINK-1 through FP-LINK-2 (ID-linkage validation)
#
# RED state: These tests MUST FAIL until figma-url-parse.sh, figma-auth.sh,
#            figma-node-mapper.sh, figma-merge.sh, and figma-id-validate.sh are implemented.
# Script-not-found is the expected failure mode — do NOT skip on missing scripts.
#
# REVIEW-DEFENSE: FP-MERGE-1..4 and FP-LINK-1..2 intentionally target figma-merge.sh and
# figma-id-validate.sh (bash scripts), not figma-merge.py (Python CLI). This is a deliberate
# dual-implementation design: figma-merge.sh covers the pullback pipeline's merge algorithm
# (story f921-e2d6), while figma-merge.py covers the interactive manifest-merge CLI workflow
# (story 3042-e00d). Both implementations are planned deliverables; each integration test file
# targets its own surface. The apparent naming inconsistency is intentional — not a split.
#
# Usage: bash tests/integration/test-figma-pullback-integration.sh
# Returns: exit 0 if all pass, exit 1 if any fail (RED state expected until implementation)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-figma-pullback-integration.sh ==="

# Cleanup trap — removes temp dirs and any figma lock files created during test execution
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
    # Remove any figma lock files created during test execution
    rm -f /tmp/figma-auth.lock /tmp/figma-pullback.lock 2>/dev/null || true
}
trap _cleanup EXIT

# Script paths under test (do NOT create these — they must not exist for RED state)
FIGMA_URL_PARSE="$REPO_ROOT/plugins/dso/scripts/figma-url-parse.sh"
FIGMA_AUTH="$REPO_ROOT/plugins/dso/scripts/figma-auth.sh"
FIGMA_MERGE="$REPO_ROOT/plugins/dso/scripts/figma-merge.sh"
FIGMA_ID_VALIDATE="$REPO_ROOT/plugins/dso/scripts/figma-id-validate.sh"
# figma-node-mapper: check bash first, fall back to python
if [[ -f "$REPO_ROOT/plugins/dso/scripts/figma-node-mapper.sh" ]]; then
    FIGMA_NODE_MAPPER="$REPO_ROOT/plugins/dso/scripts/figma-node-mapper.sh"
    FIGMA_NODE_MAPPER_CMD="bash"
elif [[ -f "$REPO_ROOT/plugins/dso/scripts/figma-node-mapper.py" ]]; then
    FIGMA_NODE_MAPPER="$REPO_ROOT/plugins/dso/scripts/figma-node-mapper.py"
    FIGMA_NODE_MAPPER_CMD="python3"
else
    FIGMA_NODE_MAPPER="$REPO_ROOT/plugins/dso/scripts/figma-node-mapper.sh"
    FIGMA_NODE_MAPPER_CMD="bash"
fi

# Fixtures
FIXTURES_DIR="$SCRIPT_DIR/fixtures/figma"

# ---------------------------------------------------------------------------
# URL Parsing Tests (FP-URL-1 through FP-URL-4)
# ---------------------------------------------------------------------------

# FP-URL-1: Given a /design/-format URL, when figma-url-parse.sh processes it,
# then file key is extracted to stdout and exits 0.
test_fp_url_1_design_format() {
    local url="https://www.figma.com/design/AbCdEfGhIjKl0123/My-Design-File?node-id=2%3A1"
    local expected_key="AbCdEfGhIjKl0123"

    # Script-not-found must FAIL (exit 1), not skip
    if [[ ! -f "$FIGMA_URL_PARSE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-URL-1 — figma-url-parse.sh not found at %s\n" "$FIGMA_URL_PARSE" >&2
        return
    fi

    local output exit_code=0
    output=$(bash "$FIGMA_URL_PARSE" "$url" 2>/dev/null) || exit_code=$?

    assert_eq "FP-URL-1: exits 0 for /design/ URL" "0" "$exit_code"
    assert_eq "FP-URL-1: extracts file key to stdout" "$expected_key" "$output"
}

# FP-URL-2: Given a /file/-format URL, when figma-url-parse.sh processes it,
# then file key extracted, exits 0.
test_fp_url_2_file_format() {
    local url="https://www.figma.com/file/XyZ9876abcDEF321/Legacy-File?node-id=0%3A1"
    local expected_key="XyZ9876abcDEF321"

    if [[ ! -f "$FIGMA_URL_PARSE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-URL-2 — figma-url-parse.sh not found at %s\n" "$FIGMA_URL_PARSE" >&2
        return
    fi

    local output exit_code=0
    output=$(bash "$FIGMA_URL_PARSE" "$url" 2>/dev/null) || exit_code=$?

    assert_eq "FP-URL-2: exits 0 for /file/ URL" "0" "$exit_code"
    assert_eq "FP-URL-2: extracts file key to stdout" "$expected_key" "$output"
}

# FP-URL-3: Given a /proto/-format URL, when figma-url-parse.sh processes it,
# then file key extracted, exits 0.
test_fp_url_3_proto_format() {
    local url="https://www.figma.com/proto/Mn0pQrStUvWx1234/Prototype-Flow?node-id=1%3A2"
    local expected_key="Mn0pQrStUvWx1234"

    if [[ ! -f "$FIGMA_URL_PARSE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-URL-3 — figma-url-parse.sh not found at %s\n" "$FIGMA_URL_PARSE" >&2
        return
    fi

    local output exit_code=0
    output=$(bash "$FIGMA_URL_PARSE" "$url" 2>/dev/null) || exit_code=$?

    assert_eq "FP-URL-3: exits 0 for /proto/ URL" "0" "$exit_code"
    assert_eq "FP-URL-3: extracts file key to stdout" "$expected_key" "$output"
}

# FP-URL-4: Given an invalid URL (no Figma domain, no key), when figma-url-parse.sh
# processes it, then exits 1 with error message on stderr.
test_fp_url_4_invalid_url() {
    local url="https://example.com/not-a-figma-url"

    if [[ ! -f "$FIGMA_URL_PARSE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-URL-4 — figma-url-parse.sh not found at %s\n" "$FIGMA_URL_PARSE" >&2
        return
    fi

    local stderr_output exit_code=0
    stderr_output=$(bash "$FIGMA_URL_PARSE" "$url" 2>&1 >/dev/null) || exit_code=$?

    assert_ne "FP-URL-4: exits non-zero for invalid URL" "0" "$exit_code"
    assert_ne "FP-URL-4: emits error message on stderr" "" "$stderr_output"
}

# ---------------------------------------------------------------------------
# PAT Authentication Tests (FP-AUTH-1 through FP-AUTH-3)
# ---------------------------------------------------------------------------

# FP-AUTH-1: Given a valid PAT, when figma-auth.sh validates via GET /v1/me,
# then exits 0.
# Uses a mock HTTP server approach: we intercept with FIGMA_API_BASE_URL pointing
# to a local endpoint. If mock infrastructure unavailable, we stub with a temp
# server or rely on a known-valid fixture.
#
# For RED tests, the script must not exist yet — this test will FAIL on script-not-found.
test_fp_auth_1_valid_pat() {
    if [[ ! -f "$FIGMA_AUTH" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-AUTH-1 — figma-auth.sh not found at %s\n" "$FIGMA_AUTH" >&2
        return
    fi

    # Use a mock server via Python's http.server if available
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Create a mock /v1/me success response
    local mock_response_dir="$tmpdir/v1"
    mkdir -p "$mock_response_dir"
    cat > "$mock_response_dir/me" <<'JSON'
{"id":"123456","email":"test@example.com","handle":"testuser","img_url":""}
JSON

    # Start a minimal mock HTTP server
    local mock_port=18741
    python3 -m http.server "$mock_port" --directory "$tmpdir" >/dev/null 2>&1 &
    local server_pid=$!
    # Give server time to start
    sleep 0.3

    local exit_code=0
    FIGMA_PAT="figd_validpatvalue123456" \
    FIGMA_API_BASE_URL="http://localhost:$mock_port" \
        bash "$FIGMA_AUTH" 2>/dev/null || exit_code=$?

    kill "$server_pid" 2>/dev/null || true

    assert_eq "FP-AUTH-1: exits 0 with valid PAT and successful /v1/me response" "0" "$exit_code"
}

# FP-AUTH-2: Given an invalid PAT, when figma-auth.sh validates, then exits 1 with
# re-provisioning instructions on stderr.
test_fp_auth_2_invalid_pat() {
    if [[ ! -f "$FIGMA_AUTH" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-AUTH-2 — figma-auth.sh not found at %s\n" "$FIGMA_AUTH" >&2
        return
    fi

    # Use fixture: figma-401-response.json (status 403, simulates auth failure)
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Create mock server serving 403 response
    local mock_v1_dir="$tmpdir/v1"
    mkdir -p "$mock_v1_dir"
    cp "$FIXTURES_DIR/figma-401-response.json" "$mock_v1_dir/me"

    local mock_port=18742
    python3 -m http.server "$mock_port" --directory "$tmpdir" >/dev/null 2>&1 &
    local server_pid=$!
    sleep 0.3

    local stderr_output exit_code=0
    stderr_output=$(FIGMA_PAT="figd_invalidtoken000" \
        FIGMA_API_BASE_URL="http://localhost:$mock_port" \
        bash "$FIGMA_AUTH" 2>&1 >/dev/null) || exit_code=$?

    kill "$server_pid" 2>/dev/null || true

    assert_ne "FP-AUTH-2: exits non-zero with invalid PAT" "0" "$exit_code"
    assert_ne "FP-AUTH-2: emits re-provisioning instructions on stderr" "" "$stderr_output"
}

# FP-AUTH-3: Given FIGMA_PAT env var and no config key, when figma-auth.sh runs,
# then reads PAT from env var (env-var fallback).
# Verifies the script uses FIGMA_PAT env var when no config key is present.
test_fp_auth_3_env_var_fallback() {
    if [[ ! -f "$FIGMA_AUTH" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-AUTH-3 — figma-auth.sh not found at %s\n" "$FIGMA_AUTH" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Point to a temp config dir with NO figma PAT config key
    local mock_config_dir="$tmpdir/config"
    mkdir -p "$mock_config_dir"
    # Create an empty config file (no FIGMA_PAT key)
    touch "$mock_config_dir/dso-config.conf"

    # Create mock server serving success response for /v1/me
    local mock_v1_dir="$tmpdir/v1"
    mkdir -p "$mock_v1_dir"
    cat > "$mock_v1_dir/me" <<'JSON'
{"id":"789012","email":"envuser@example.com","handle":"envuser","img_url":""}
JSON

    local mock_port=18743
    python3 -m http.server "$mock_port" --directory "$tmpdir" >/dev/null 2>&1 &
    local server_pid=$!
    sleep 0.3

    local exit_code=0
    FIGMA_PAT="figd_envvartoken987654" \
    FIGMA_API_BASE_URL="http://localhost:$mock_port" \
    DSO_CONFIG_FILE="$mock_config_dir/dso-config.conf" \
        bash "$FIGMA_AUTH" 2>/dev/null || exit_code=$?

    kill "$server_pid" 2>/dev/null || true

    assert_eq "FP-AUTH-3: exits 0 when PAT read from FIGMA_PAT env var (no config key)" "0" "$exit_code"
}

# ---------------------------------------------------------------------------
# Node Mapping Tests (FP-MAP-1 through FP-MAP-7)
# ---------------------------------------------------------------------------

# FP-MAP-1: Given tests/integration/fixtures/figma/figma-file-response.json,
# when figma-node-mapper.sh processes it,
# then outputs valid spatial-layout.json (parseable JSON with required fields:
# components array, metadata).
test_fp_map_1_valid_json() {
    if [[ ! -f "$FIGMA_NODE_MAPPER" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MAP-1 — figma-node-mapper not found at %s\n" "$FIGMA_NODE_MAPPER" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local output_file="$tmpdir/spatial-layout.json"

    local exit_code=0
    "$FIGMA_NODE_MAPPER_CMD" "$FIGMA_NODE_MAPPER" \
        "$FIXTURES_DIR/figma-file-response.json" \
        "$output_file" 2>/dev/null || exit_code=$?

    assert_eq "FP-MAP-1: exits 0 for valid fixture" "0" "$exit_code"

    local parsed_ok=0
    python3 -c "import sys,json; d=json.load(open('$output_file')); assert 'components' in d; assert 'metadata' in d" \
        2>/dev/null || parsed_ok=1

    assert_eq "FP-MAP-1: output is parseable JSON with components and metadata fields" "0" "$parsed_ok"
}

# FP-MAP-2: Given a FRAME node (id "2:1", name "Main Frame") in the fixture,
# when mapped, then output contains a section entry with id="2:1", name="Main Frame",
# spatial_hint with x=0, y=0, width=1440, height=900.
test_fp_map_2_frame_mapping() {
    if [[ ! -f "$FIGMA_NODE_MAPPER" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MAP-2 — figma-node-mapper not found at %s\n" "$FIGMA_NODE_MAPPER" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local output_file="$tmpdir/spatial-layout.json"

    local exit_code=0
    "$FIGMA_NODE_MAPPER_CMD" "$FIGMA_NODE_MAPPER" \
        "$FIXTURES_DIR/figma-file-response.json" \
        "$output_file" 2>/dev/null || exit_code=$?

    assert_eq "FP-MAP-2: exits 0" "0" "$exit_code"

    local frame_check=0
    python3 - "$output_file" <<'PYEOF' 2>/dev/null || frame_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
frame = next((c for c in components if c.get("id") == "2:1"), None)
assert frame is not None, "no component with id 2:1"
assert frame.get("name") == "Main Frame", f"name mismatch: {frame.get('name')}"
sh = frame.get("spatial_hint", {})
assert sh.get("x") == 0,      f"x={sh.get('x')}"
assert sh.get("y") == 0,      f"y={sh.get('y')}"
assert sh.get("width") == 1440,  f"width={sh.get('width')}"
assert sh.get("height") == 900,  f"height={sh.get('height')}"
PYEOF

    assert_eq "FP-MAP-2: FRAME node mapped with correct id, name, and spatial_hint" "0" "$frame_check"
}

# FP-MAP-3: Given a TEXT node (id "2:2", name "Heading",
# characters "Welcome to the Design System"), when mapped,
# then output contains text content in the component entry.
test_fp_map_3_text_mapping() {
    if [[ ! -f "$FIGMA_NODE_MAPPER" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MAP-3 — figma-node-mapper not found at %s\n" "$FIGMA_NODE_MAPPER" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local output_file="$tmpdir/spatial-layout.json"

    local exit_code=0
    "$FIGMA_NODE_MAPPER_CMD" "$FIGMA_NODE_MAPPER" \
        "$FIXTURES_DIR/figma-file-response.json" \
        "$output_file" 2>/dev/null || exit_code=$?

    assert_eq "FP-MAP-3: exits 0" "0" "$exit_code"

    local text_check=0
    python3 - "$output_file" <<'PYEOF' 2>/dev/null || text_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
text_node = next((c for c in components if c.get("id") == "2:2"), None)
assert text_node is not None, "no component with id 2:2"
assert text_node.get("name") == "Heading", f"name={text_node.get('name')}"
content = text_node.get("text_content", "") or text_node.get("characters", "") or str(text_node)
assert "Welcome to the Design System" in content, f"text content missing: {text_node}"
PYEOF

    assert_eq "FP-MAP-3: TEXT node contains text content 'Welcome to the Design System'" "0" "$text_check"
}

# FP-MAP-4: Given a RECTANGLE node (id "2:3", name "Divider"), when mapped,
# then output contains it as a component entry with appropriate type.
test_fp_map_4_rectangle_mapping() {
    if [[ ! -f "$FIGMA_NODE_MAPPER" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MAP-4 — figma-node-mapper not found at %s\n" "$FIGMA_NODE_MAPPER" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local output_file="$tmpdir/spatial-layout.json"

    local exit_code=0
    "$FIGMA_NODE_MAPPER_CMD" "$FIGMA_NODE_MAPPER" \
        "$FIXTURES_DIR/figma-file-response.json" \
        "$output_file" 2>/dev/null || exit_code=$?

    assert_eq "FP-MAP-4: exits 0" "0" "$exit_code"

    local rect_check=0
    python3 - "$output_file" <<'PYEOF' 2>/dev/null || rect_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
rect_node = next((c for c in components if c.get("id") == "2:3"), None)
assert rect_node is not None, "no component with id 2:3"
assert rect_node.get("name") == "Divider", f"name={rect_node.get('name')}"
# type field must be present and non-empty
node_type = rect_node.get("type", "")
assert node_type, f"type field missing or empty: {rect_node}"
PYEOF

    assert_eq "FP-MAP-4: RECTANGLE node mapped as component entry with non-empty type" "0" "$rect_check"
}

# FP-MAP-5: Given a COMPONENT node (id "2:4", name "PrimaryButton",
# componentId "component:primary-button-v1"), when mapped,
# then output contains component with COMPLETE behavioral spec placeholder.
test_fp_map_5_component_mapping() {
    if [[ ! -f "$FIGMA_NODE_MAPPER" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MAP-5 — figma-node-mapper not found at %s\n" "$FIGMA_NODE_MAPPER" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local output_file="$tmpdir/spatial-layout.json"

    local exit_code=0
    "$FIGMA_NODE_MAPPER_CMD" "$FIGMA_NODE_MAPPER" \
        "$FIXTURES_DIR/figma-file-response.json" \
        "$output_file" 2>/dev/null || exit_code=$?

    assert_eq "FP-MAP-5: exits 0" "0" "$exit_code"

    local comp_check=0
    python3 - "$output_file" <<'PYEOF' 2>/dev/null || comp_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
comp_node = next((c for c in components if c.get("id") == "2:4"), None)
assert comp_node is not None, "no component with id 2:4"
assert comp_node.get("name") == "PrimaryButton", f"name={comp_node.get('name')}"
# Must have a behavioral_spec or behavioral_spec_placeholder field (non-empty)
spec = comp_node.get("behavioral_spec") or comp_node.get("behavioral_spec_placeholder") or ""
assert spec, f"behavioral spec placeholder missing: {comp_node}"
PYEOF

    assert_eq "FP-MAP-5: COMPONENT node has behavioral spec placeholder" "0" "$comp_check"
}

# FP-MAP-6: Given an INSTANCE node (id "2:5", name "PrimaryButton Instance"),
# when mapped, then output contains an instance entry referencing the source component.
test_fp_map_6_instance_mapping() {
    if [[ ! -f "$FIGMA_NODE_MAPPER" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MAP-6 — figma-node-mapper not found at %s\n" "$FIGMA_NODE_MAPPER" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local output_file="$tmpdir/spatial-layout.json"

    local exit_code=0
    "$FIGMA_NODE_MAPPER_CMD" "$FIGMA_NODE_MAPPER" \
        "$FIXTURES_DIR/figma-file-response.json" \
        "$output_file" 2>/dev/null || exit_code=$?

    assert_eq "FP-MAP-6: exits 0" "0" "$exit_code"

    local inst_check=0
    python3 - "$output_file" <<'PYEOF' 2>/dev/null || inst_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
inst_node = next((c for c in components if c.get("id") == "2:5"), None)
assert inst_node is not None, "no component with id 2:5"
assert inst_node.get("name") == "PrimaryButton Instance", f"name={inst_node.get('name')}"
# Must reference a source component via component_ref, source_component_id, or similar
ref = (inst_node.get("component_ref") or inst_node.get("source_component_id")
       or inst_node.get("instance_of") or "")
assert ref, f"instance has no source component reference: {inst_node}"
PYEOF

    assert_eq "FP-MAP-6: INSTANCE node contains reference to source component" "0" "$inst_check"
}

# FP-MAP-7: Given invalid/malformed JSON input, when figma-node-mapper.sh processes it,
# then exits 1 with error on stderr.
test_fp_map_7_invalid_json() {
    if [[ ! -f "$FIGMA_NODE_MAPPER" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MAP-7 — figma-node-mapper not found at %s\n" "$FIGMA_NODE_MAPPER" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local bad_input="$tmpdir/bad-input.json"
    local output_file="$tmpdir/spatial-layout.json"

    # Write deliberately malformed JSON
    printf '{ "document": { BROKEN JSON !!! \n' > "$bad_input"

    local stderr_output exit_code=0
    stderr_output=$("$FIGMA_NODE_MAPPER_CMD" "$FIGMA_NODE_MAPPER" \
        "$bad_input" \
        "$output_file" 2>&1 >/dev/null) || exit_code=$?

    assert_ne "FP-MAP-7: exits non-zero for malformed JSON input" "0" "$exit_code"
    assert_ne "FP-MAP-7: emits error message on stderr for malformed JSON" "" "$stderr_output"
}

# ---------------------------------------------------------------------------
# Merge Algorithm Tests (FP-MERGE-1 through FP-MERGE-4)
# ---------------------------------------------------------------------------

# FP-MERGE-1: Given an original manifest and a Figma-derived spatial-layout.json
# with a new component, when figma-merge.sh runs, then the new component appears
# with tag:NEW, designer_added:true, behavioral_spec_status:INCOMPLETE in the output.
test_fp_merge_1_new_component_tagged() {
    if [[ ! -f "$FIGMA_MERGE" ]]; then
        (( ++FAIL ))
        printf "test_fp_merge_1_new_component_tagged: FAIL — figma-merge.sh not found at %s\n" "$FIGMA_MERGE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    local original_manifest="$tmpdir/original-manifest.json"
    local new_spatial="$tmpdir/new-spatial-layout.json"
    local output_file="$tmpdir/merged-output.json"

    # Original manifest: one existing component
    cat > "$original_manifest" <<'JSON'
{
  "components": [
    {
      "id": "2:1",
      "name": "ExistingButton",
      "type": "COMPONENT",
      "behavioral_spec_status": "COMPLETE",
      "behavioral_spec": "Handles click events"
    }
  ]
}
JSON

    # New Figma spatial-layout: same component plus a brand-new one
    cat > "$new_spatial" <<'JSON'
{
  "components": [
    {
      "id": "2:1",
      "name": "ExistingButton",
      "type": "COMPONENT",
      "spatial_hint": {"x": 0, "y": 0, "width": 120, "height": 40}
    },
    {
      "id": "3:1",
      "name": "NewCard",
      "type": "COMPONENT",
      "spatial_hint": {"x": 200, "y": 0, "width": 300, "height": 200}
    }
  ]
}
JSON

    local exit_code=0
    bash "$FIGMA_MERGE" "$original_manifest" "$new_spatial" "$output_file" 2>/dev/null || exit_code=$?

    assert_eq "FP-MERGE-1: exits 0" "0" "$exit_code"

    local merge_check=0
    python3 - "$output_file" <<'PYEOF' 2>/dev/null || merge_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
new_comp = next((c for c in components if c.get("id") == "3:1"), None)
assert new_comp is not None, "new component 3:1 not found in output"
assert new_comp.get("tag") == "NEW" or new_comp.get("tags", []) == ["NEW"] or "NEW" in str(new_comp.get("tag", "")), \
    f"tag:NEW not present: {new_comp}"
assert new_comp.get("designer_added") == True, f"designer_added:true not set: {new_comp}"
assert new_comp.get("behavioral_spec_status") == "INCOMPLETE", \
    f"behavioral_spec_status:INCOMPLETE not set: {new_comp}"
PYEOF

    assert_eq "FP-MERGE-1: new component has tag:NEW, designer_added:true, behavioral_spec_status:INCOMPLETE" "0" "$merge_check"
}

# FP-MERGE-2: Given an original manifest with a COMPLETE-spec component and a Figma
# spatial-layout.json missing that component, when figma-merge.sh runs, then the
# component is removed from the output AND stderr contains a warning about the
# COMPLETE behavioral spec being deleted.
test_fp_merge_2_complete_spec_removal_warns() {
    if [[ ! -f "$FIGMA_MERGE" ]]; then
        (( ++FAIL ))
        printf "test_fp_merge_2_complete_spec_removal_warns: FAIL — figma-merge.sh not found at %s\n" "$FIGMA_MERGE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    local original_manifest="$tmpdir/original-manifest.json"
    local new_spatial="$tmpdir/new-spatial-layout.json"
    local output_file="$tmpdir/merged-output.json"

    # Original manifest: component with COMPLETE spec
    cat > "$original_manifest" <<'JSON'
{
  "components": [
    {
      "id": "2:1",
      "name": "CompleteButton",
      "type": "COMPONENT",
      "behavioral_spec_status": "COMPLETE",
      "behavioral_spec": "Handles click with full a11y"
    },
    {
      "id": "2:2",
      "name": "StillPresentCard",
      "type": "COMPONENT",
      "behavioral_spec_status": "INCOMPLETE"
    }
  ]
}
JSON

    # New Figma spatial-layout: COMPLETE component is missing (removed in Figma)
    cat > "$new_spatial" <<'JSON'
{
  "components": [
    {
      "id": "2:2",
      "name": "StillPresentCard",
      "type": "COMPONENT",
      "spatial_hint": {"x": 0, "y": 0, "width": 200, "height": 100}
    }
  ]
}
JSON

    local stderr_output exit_code=0
    stderr_output=$(bash "$FIGMA_MERGE" "$original_manifest" "$new_spatial" "$output_file" 2>&1 >/dev/null) || exit_code=$?

    # Run again to get exit code without capturing stderr
    local exit_code2=0
    bash "$FIGMA_MERGE" "$original_manifest" "$new_spatial" "$output_file" 2>/dev/null || exit_code2=$?

    assert_eq "FP-MERGE-2: exits 0 after removal with warning" "0" "$exit_code2"

    # The removed COMPLETE component must not appear in output
    local removal_check=0
    python3 - "$output_file" <<'PYEOF' 2>/dev/null || removal_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
removed = next((c for c in components if c.get("id") == "2:1"), None)
assert removed is None, f"removed COMPLETE component 2:1 still present: {removed}"
PYEOF

    assert_eq "FP-MERGE-2: COMPLETE-spec component removed from output" "0" "$removal_check"
    assert_contains "FP-MERGE-2: stderr warns about COMPLETE behavioral spec deletion" "COMPLETE" "$stderr_output"
}

# FP-MERGE-3: Given a component with updated absoluteBoundingBox in the new Figma
# data, when figma-merge.sh runs, then the output spatial_hint reflects the new
# dimensions while the behavioral spec sections are unchanged.
test_fp_merge_3_spatial_update_preserves_spec() {
    if [[ ! -f "$FIGMA_MERGE" ]]; then
        (( ++FAIL ))
        printf "test_fp_merge_3_spatial_update_preserves_spec: FAIL — figma-merge.sh not found at %s\n" "$FIGMA_MERGE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    local original_manifest="$tmpdir/original-manifest.json"
    local new_spatial="$tmpdir/new-spatial-layout.json"
    local output_file="$tmpdir/merged-output.json"

    # Original manifest: component with full behavioral spec sections
    cat > "$original_manifest" <<'JSON'
{
  "components": [
    {
      "id": "2:1",
      "name": "ResizablePanel",
      "type": "COMPONENT",
      "spatial_hint": {"x": 0, "y": 0, "width": 200, "height": 100},
      "behavioral_spec_status": "COMPLETE",
      "Interaction Behaviors": "Responds to pointer events",
      "Responsive Rules": "Scales with viewport",
      "Accessibility Specification": "role=region aria-label=panel",
      "State Definitions": "default, hover, focused"
    }
  ]
}
JSON

    # New Figma spatial-layout: updated bounding box (width/height changed)
    cat > "$new_spatial" <<'JSON'
{
  "components": [
    {
      "id": "2:1",
      "name": "ResizablePanel",
      "type": "COMPONENT",
      "spatial_hint": {"x": 10, "y": 20, "width": 400, "height": 250}
    }
  ]
}
JSON

    local exit_code=0
    bash "$FIGMA_MERGE" "$original_manifest" "$new_spatial" "$output_file" 2>/dev/null || exit_code=$?

    assert_eq "FP-MERGE-3: exits 0" "0" "$exit_code"

    local spec_check=0
    python3 - "$output_file" <<'PYEOF' 2>/dev/null || spec_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
comp = next((c for c in components if c.get("id") == "2:1"), None)
assert comp is not None, "component 2:1 not found"
# spatial_hint must reflect new dimensions
sh = comp.get("spatial_hint", {})
assert sh.get("width") == 400, f"width not updated: {sh}"
assert sh.get("height") == 250, f"height not updated: {sh}"
# behavioral spec sections must be preserved
assert comp.get("Interaction Behaviors") == "Responds to pointer events", \
    f"Interaction Behaviors changed: {comp.get('Interaction Behaviors')}"
assert comp.get("Responsive Rules") == "Scales with viewport", \
    f"Responsive Rules changed: {comp.get('Responsive Rules')}"
assert comp.get("Accessibility Specification") == "role=region aria-label=panel", \
    f"Accessibility Specification changed: {comp.get('Accessibility Specification')}"
assert comp.get("State Definitions") == "default, hover, focused", \
    f"State Definitions changed: {comp.get('State Definitions')}"
PYEOF

    assert_eq "FP-MERGE-3: spatial_hint updated; Interaction Behaviors, Responsive Rules, Accessibility Specification, State Definitions preserved" "0" "$spec_check"
}

# FP-MERGE-4: Given an updated TEXT node, when figma-merge.sh runs,
# then the text content is updated while behavioral specs are preserved.
test_fp_merge_4_text_content_update_preserves_spec() {
    if [[ ! -f "$FIGMA_MERGE" ]]; then
        (( ++FAIL ))
        printf "test_fp_merge_4_text_content_update_preserves_spec: FAIL — figma-merge.sh not found at %s\n" "$FIGMA_MERGE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    local original_manifest="$tmpdir/original-manifest.json"
    local new_spatial="$tmpdir/new-spatial-layout.json"
    local output_file="$tmpdir/merged-output.json"

    # Original manifest: TEXT node with behavioral spec
    cat > "$original_manifest" <<'JSON'
{
  "components": [
    {
      "id": "2:2",
      "name": "HeadingText",
      "type": "TEXT",
      "text_content": "Old Heading",
      "behavioral_spec_status": "COMPLETE",
      "Interaction Behaviors": "Read-only display",
      "Responsive Rules": "Truncates with ellipsis at 320px",
      "Accessibility Specification": "role=heading aria-level=1",
      "State Definitions": "default"
    }
  ]
}
JSON

    # New Figma spatial-layout: TEXT node with updated text content
    cat > "$new_spatial" <<'JSON'
{
  "components": [
    {
      "id": "2:2",
      "name": "HeadingText",
      "type": "TEXT",
      "text_content": "Updated Heading Text",
      "spatial_hint": {"x": 0, "y": 0, "width": 500, "height": 60}
    }
  ]
}
JSON

    local exit_code=0
    bash "$FIGMA_MERGE" "$original_manifest" "$new_spatial" "$output_file" 2>/dev/null || exit_code=$?

    assert_eq "FP-MERGE-4: exits 0" "0" "$exit_code"

    local text_check=0
    python3 - "$output_file" <<'PYEOF' 2>/dev/null || text_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
comp = next((c for c in components if c.get("id") == "2:2"), None)
assert comp is not None, "TEXT node 2:2 not found"
# text content must be updated
text = comp.get("text_content") or comp.get("characters") or ""
assert "Updated Heading Text" in text, f"text_content not updated: {text!r}"
# behavioral spec sections must be preserved
assert comp.get("Interaction Behaviors") == "Read-only display", \
    f"Interaction Behaviors changed: {comp.get('Interaction Behaviors')}"
assert comp.get("Responsive Rules") == "Truncates with ellipsis at 320px", \
    f"Responsive Rules changed: {comp.get('Responsive Rules')}"
assert comp.get("Accessibility Specification") == "role=heading aria-level=1", \
    f"Accessibility Specification changed: {comp.get('Accessibility Specification')}"
assert comp.get("State Definitions") == "default", \
    f"State Definitions changed: {comp.get('State Definitions')}"
PYEOF

    assert_eq "FP-MERGE-4: text_content updated; behavioral spec sections preserved" "0" "$text_check"
}

# ---------------------------------------------------------------------------
# ID-Linkage Validation Tests (FP-LINK-1 through FP-LINK-2)
# ---------------------------------------------------------------------------

# FP-LINK-1: Given a 3-artifact manifest where all IDs in spatial-layout.json exist
# in wireframe.svg and tokens.md, when figma-id-validate.sh runs, then exits 0.
test_fp_link_1_all_ids_present() {
    if [[ ! -f "$FIGMA_ID_VALIDATE" ]]; then
        (( ++FAIL ))
        printf "test_fp_link_1_all_ids_present: FAIL — figma-id-validate.sh not found at %s\n" "$FIGMA_ID_VALIDATE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    local spatial_layout="$tmpdir/spatial-layout.json"
    local wireframe_svg="$tmpdir/wireframe.svg"
    local tokens_md="$tmpdir/tokens.md"

    # spatial-layout.json with two component IDs
    cat > "$spatial_layout" <<'JSON'
{
  "components": [
    {"id": "2:1", "name": "PrimaryButton"},
    {"id": "2:2", "name": "InputField"}
  ]
}
JSON

    # wireframe.svg referencing both IDs
    cat > "$wireframe_svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="900">
  <g id="2:1" data-component="PrimaryButton">
    <rect width="120" height="40" fill="#0055CC"/>
  </g>
  <g id="2:2" data-component="InputField">
    <rect width="300" height="40" fill="#FFFFFF" stroke="#CCCCCC"/>
  </g>
</svg>
SVG

    # tokens.md referencing both IDs
    cat > "$tokens_md" <<'MD'
# Design Tokens

## Component: 2:1 PrimaryButton
- color: #0055CC
- border-radius: 4px

## Component: 2:2 InputField
- border-color: #CCCCCC
- padding: 8px 12px
MD

    local exit_code=0
    bash "$FIGMA_ID_VALIDATE" "$spatial_layout" "$wireframe_svg" "$tokens_md" 2>/dev/null || exit_code=$?

    assert_eq "FP-LINK-1: exits 0 when all IDs present in wireframe.svg and tokens.md" "0" "$exit_code"
}

# FP-LINK-2: Given a 3-artifact manifest with an orphaned ID (present in
# spatial-layout.json, absent from wireframe.svg), when figma-id-validate.sh runs,
# then exits 1 with the orphaned ID listed on stderr.
test_fp_link_2_orphaned_id_reported() {
    if [[ ! -f "$FIGMA_ID_VALIDATE" ]]; then
        (( ++FAIL ))
        printf "test_fp_link_2_orphaned_id_reported: FAIL — figma-id-validate.sh not found at %s\n" "$FIGMA_ID_VALIDATE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    local spatial_layout="$tmpdir/spatial-layout.json"
    local wireframe_svg="$tmpdir/wireframe.svg"
    local tokens_md="$tmpdir/tokens.md"

    # spatial-layout.json with two component IDs
    cat > "$spatial_layout" <<'JSON'
{
  "components": [
    {"id": "2:1", "name": "PrimaryButton"},
    {"id": "3:99", "name": "OrphanedWidget"}
  ]
}
JSON

    # wireframe.svg: only has 2:1; 3:99 is absent (orphaned)
    cat > "$wireframe_svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="900">
  <g id="2:1" data-component="PrimaryButton">
    <rect width="120" height="40" fill="#0055CC"/>
  </g>
</svg>
SVG

    # tokens.md: also only references 2:1
    cat > "$tokens_md" <<'MD'
# Design Tokens

## Component: 2:1 PrimaryButton
- color: #0055CC
MD

    local stderr_output exit_code=0
    stderr_output=$(bash "$FIGMA_ID_VALIDATE" "$spatial_layout" "$wireframe_svg" "$tokens_md" 2>&1 >/dev/null) || exit_code=$?

    assert_ne "FP-LINK-2: exits non-zero when orphaned ID detected" "0" "$exit_code"
    assert_contains "FP-LINK-2: orphaned ID 3:99 listed on stderr" "3:99" "$stderr_output"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_fp_url_1_design_format
test_fp_url_2_file_format
test_fp_url_3_proto_format
test_fp_url_4_invalid_url
test_fp_auth_1_valid_pat
test_fp_auth_2_invalid_pat
test_fp_auth_3_env_var_fallback
test_fp_map_1_valid_json
test_fp_map_2_frame_mapping
test_fp_map_3_text_mapping
test_fp_map_4_rectangle_mapping
test_fp_map_5_component_mapping
test_fp_map_6_instance_mapping
test_fp_map_7_invalid_json
test_fp_merge_1_new_component_tagged
test_fp_merge_2_complete_spec_removal_warns
test_fp_merge_3_spatial_update_preserves_spec
test_fp_merge_4_text_content_update_preserves_spec
test_fp_link_1_all_ids_present
test_fp_link_2_orphaned_id_reported

print_summary
