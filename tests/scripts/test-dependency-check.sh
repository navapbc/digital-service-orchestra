#!/usr/bin/env bash
# tests/scripts/test-dependency-check.sh
# RED tests for plugins/dso/scripts/fix-bug/dependency-check.sh
#
# Each test creates an isolated temp project directory with controlled dependency
# files and invokes the gate script, asserting on JSON stdout fields.
#
# RED STATE: All tests currently fail because dependency-check.sh does
# not yet exist. They will pass (GREEN) after the script is implemented.
#
# Script interface:
#   dependency-check.sh <file1> [file2 ...] --repo-root <path>
#
# Output schema (gate-signal-schema.md):
#   gate_id      string   — must be "dependency"
#   triggered    boolean  — true if new dependency/import detected
#   signal_type  string   — "primary"
#   evidence     string   — non-empty human-readable explanation
#   confidence   string   — "high" | "medium" | "low"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/fix-bug/dependency-check.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# Helper: extract a JSON field from a JSON string
_json_field() {
    local json="$1" field="$2"
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = d.get('$field', '')
    print(str(v).lower() if isinstance(v, bool) else v)
except Exception:
    print('')
" <<< "$json" 2>/dev/null || echo ""
}

echo "=== test-dependency-check.sh ==="

# ── test_detects_new_dependency ───────────────────────────────────────────────
# A Python file that imports a package not listed in pyproject.toml must cause
# triggered:true in the output.
test_detects_new_dependency() {
    _snapshot_fail

    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    # pyproject.toml that lists only 'requests'
    cat > "$tmpdir/pyproject.toml" <<'EOF'
[project]
name = "myapp"
dependencies = ["requests>=2.0"]
EOF

    # Source file that imports 'boto3' — not listed in pyproject.toml
    mkdir -p "$tmpdir/src"
    cat > "$tmpdir/src/uploader.py" <<'EOF'
import boto3
client = boto3.client('s3')
EOF

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "src/uploader.py" --repo-root "$tmpdir" 2>/dev/null) || exit_code=$?

    assert_eq "test_detects_new_dependency: gate exits 0" "0" "$exit_code"

    local triggered
    triggered=$(_json_field "$output" "triggered")
    assert_eq "test_detects_new_dependency: triggered=true for package not in pyproject.toml" "true" "$triggered"

    assert_pass_if_clean "test_detects_new_dependency"
}

# ── test_existing_dependency_no_trigger ───────────────────────────────────────
# A Python file that imports a package already listed in pyproject.toml must
# cause triggered:false — no new dependency was introduced.
test_existing_dependency_no_trigger() {
    _snapshot_fail

    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    # pyproject.toml that already lists 'requests'
    cat > "$tmpdir/pyproject.toml" <<'EOF'
[project]
name = "myapp"
dependencies = ["requests>=2.0"]
EOF

    mkdir -p "$tmpdir/src"
    cat > "$tmpdir/src/fetcher.py" <<'EOF'
import requests
response = requests.get("https://example.com")
EOF

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "src/fetcher.py" --repo-root "$tmpdir" 2>/dev/null) || exit_code=$?

    assert_eq "test_existing_dependency_no_trigger: gate exits 0" "0" "$exit_code"

    local triggered
    triggered=$(_json_field "$output" "triggered")
    assert_eq "test_existing_dependency_no_trigger: triggered=false when package already in manifest" "false" "$triggered"

    assert_pass_if_clean "test_existing_dependency_no_trigger"
}

# ── test_detects_new_import ───────────────────────────────────────────────────
# An import that does not appear anywhere else in the codebase (no sibling file
# uses it) must cause triggered:true — the import is new to the project.
test_detects_new_import() {
    _snapshot_fail

    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    # No manifest — fallback to import-only analysis
    mkdir -p "$tmpdir/src"

    # The file under analysis imports 'cryptography'
    cat > "$tmpdir/src/encrypt.py" <<'EOF'
from cryptography.fernet import Fernet
key = Fernet.generate_key()
EOF

    # Only other source file uses a completely different library
    cat > "$tmpdir/src/utils.py" <<'EOF'
import os
import sys
EOF

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "src/encrypt.py" --repo-root "$tmpdir" 2>/dev/null) || exit_code=$?

    assert_eq "test_detects_new_import: gate exits 0" "0" "$exit_code"

    local triggered
    triggered=$(_json_field "$output" "triggered")
    assert_eq "test_detects_new_import: triggered=true when import not used elsewhere in codebase" "true" "$triggered"

    assert_pass_if_clean "test_detects_new_import"
}

# ── test_existing_import_no_trigger ───────────────────────────────────────────
# When the same import already appears in a sibling file, triggered must be false
# because the import is not new to the project.
test_existing_import_no_trigger() {
    _snapshot_fail

    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    # No manifest — fallback to import-only analysis
    mkdir -p "$tmpdir/src"

    # The file under analysis imports 'requests'
    cat > "$tmpdir/src/new_feature.py" <<'EOF'
import requests
data = requests.get("https://api.example.com/data").json()
EOF

    # Sibling file that already uses the same import
    cat > "$tmpdir/src/existing_client.py" <<'EOF'
import requests
session = requests.Session()
EOF

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "src/new_feature.py" --repo-root "$tmpdir" 2>/dev/null) || exit_code=$?

    assert_eq "test_existing_import_no_trigger: gate exits 0" "0" "$exit_code"

    local triggered
    triggered=$(_json_field "$output" "triggered")
    assert_eq "test_existing_import_no_trigger: triggered=false when import already used in sibling file" "false" "$triggered"

    assert_pass_if_clean "test_existing_import_no_trigger"
}

# ── test_emits_gate_signal_json ───────────────────────────────────────────────
# The script must emit a JSON object with gate_id="dependency" and signal_type="primary"
# conforming to the gate-signal-schema contract.
test_emits_gate_signal_json() {
    _snapshot_fail

    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    cat > "$tmpdir/pyproject.toml" <<'EOF'
[project]
name = "myapp"
dependencies = []
EOF

    mkdir -p "$tmpdir/src"
    cat > "$tmpdir/src/main.py" <<'EOF'
import os
print("hello")
EOF

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "src/main.py" --repo-root "$tmpdir" 2>/dev/null) || exit_code=$?

    assert_eq "test_emits_gate_signal_json: gate exits 0" "0" "$exit_code"

    # Validate gate_id field
    local gate_id
    gate_id=$(_json_field "$output" "gate_id")
    assert_eq "test_emits_gate_signal_json: gate_id is 'dependency'" "dependency" "$gate_id"

    # Validate signal_type field
    local signal_type
    signal_type=$(_json_field "$output" "signal_type")
    assert_eq "test_emits_gate_signal_json: signal_type is 'primary'" "primary" "$signal_type"

    # Validate evidence field is present and non-empty
    local evidence
    evidence=$(_json_field "$output" "evidence")
    assert_ne "test_emits_gate_signal_json: evidence field is non-empty" "" "$evidence"

    # Validate confidence field is a valid enum value
    local confidence
    confidence=$(_json_field "$output" "confidence")
    local valid_confidence
    valid_confidence=$(python3 -c "print('yes' if '$confidence' in ('high','medium','low') else 'no')" 2>/dev/null) || valid_confidence="no"
    assert_eq "test_emits_gate_signal_json: confidence is valid enum" "yes" "$valid_confidence"

    assert_pass_if_clean "test_emits_gate_signal_json"
}

# ── test_no_manifest_graceful ─────────────────────────────────────────────────
# When neither pyproject.toml nor package.json exists, the gate must not crash.
# It must exit 0 and emit valid JSON (falling back to import-only analysis).
test_no_manifest_graceful() {
    _snapshot_fail

    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    # No manifest files at all
    mkdir -p "$tmpdir/src"
    cat > "$tmpdir/src/helper.py" <<'EOF'
def add(a, b):
    return a + b
EOF

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "src/helper.py" --repo-root "$tmpdir" 2>/dev/null) || exit_code=$?

    assert_eq "test_no_manifest_graceful: gate exits 0 with no manifest present" "0" "$exit_code"

    # Output must be parseable JSON with required fields
    local gate_id
    gate_id=$(_json_field "$output" "gate_id")
    assert_eq "test_no_manifest_graceful: gate_id present in fallback output" "dependency" "$gate_id"

    local triggered
    triggered=$(_json_field "$output" "triggered")
    local triggered_valid
    triggered_valid=$(python3 -c "print('yes' if '$triggered' in ('true','false') else 'no')" 2>/dev/null) || triggered_valid="no"
    assert_eq "test_no_manifest_graceful: triggered field is a valid boolean" "yes" "$triggered_valid"

    assert_pass_if_clean "test_no_manifest_graceful"
}

# ── test_pyproject_only ───────────────────────────────────────────────────────
# With only pyproject.toml (Python project), the gate must check Python
# dependencies and emit a valid signal. A new Python import not in the manifest
# must trigger.
test_pyproject_only() {
    _snapshot_fail

    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    # Only pyproject.toml — no package.json
    cat > "$tmpdir/pyproject.toml" <<'EOF'
[project]
name = "myapp"
dependencies = ["flask>=2.0", "sqlalchemy>=1.4"]
EOF

    mkdir -p "$tmpdir/src"
    # Import 'celery' — not listed in pyproject.toml
    cat > "$tmpdir/src/tasks.py" <<'EOF'
from celery import Celery
app = Celery('tasks')
EOF

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "src/tasks.py" --repo-root "$tmpdir" 2>/dev/null) || exit_code=$?

    assert_eq "test_pyproject_only: gate exits 0 with only pyproject.toml" "0" "$exit_code"

    local gate_id triggered
    gate_id=$(_json_field "$output" "gate_id")
    triggered=$(_json_field "$output" "triggered")

    assert_eq "test_pyproject_only: gate_id is 'dependency'" "dependency" "$gate_id"
    assert_eq "test_pyproject_only: triggered=true for new Python dep not in pyproject.toml" "true" "$triggered"

    assert_pass_if_clean "test_pyproject_only"
}

# ── test_package_json_only ────────────────────────────────────────────────────
# With only package.json (Node project), the gate must check Node dependencies
# and emit a valid signal. A new import not in package.json dependencies must
# trigger.
test_package_json_only() {
    _snapshot_fail

    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    # Only package.json — no pyproject.toml
    cat > "$tmpdir/package.json" <<'EOF'
{
  "name": "myapp",
  "dependencies": {
    "express": "^4.18.0",
    "lodash": "^4.17.21"
  }
}
EOF

    mkdir -p "$tmpdir/src"
    # Import 'axios' — not listed in package.json
    cat > "$tmpdir/src/api.js" <<'EOF'
const axios = require('axios');
module.exports = { fetch: (url) => axios.get(url) };
EOF

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "src/api.js" --repo-root "$tmpdir" 2>/dev/null) || exit_code=$?

    assert_eq "test_package_json_only: gate exits 0 with only package.json" "0" "$exit_code"

    local gate_id triggered
    gate_id=$(_json_field "$output" "gate_id")
    triggered=$(_json_field "$output" "triggered")

    assert_eq "test_package_json_only: gate_id is 'dependency'" "dependency" "$gate_id"
    assert_eq "test_package_json_only: triggered=true for new Node dep not in package.json" "true" "$triggered"

    assert_pass_if_clean "test_package_json_only"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_detects_new_dependency
test_existing_dependency_no_trigger
test_detects_new_import
test_existing_import_no_trigger
test_emits_gate_signal_json
test_no_manifest_graceful
test_pyproject_only
test_package_json_only

print_summary
