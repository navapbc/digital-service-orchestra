#!/usr/bin/env bash
# tests/runners/test-runners-manifest.sh
# Behavioral tests for plugins/dso/config/test-runners.yaml harness manifest.
#
# Tests parse the manifest with python3 yaml.safe_load and assert on extracted
# values (NOT source grep). Covers:
#   - dd-1: all four harnesses declared with non-empty invocation + verdict_adapter
#   - dd-2: kind classification (engines vs wrappers) + delegate_engine cross-ref
#   - dd-3: bash-runner invocation records test-batched.sh --runner=bash composite
#   - AC amendments: verdict_adapter shape, id uniqueness, file existence on disk
#
# Usage: bash tests/runners/test-runners-manifest.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

MANIFEST="$REPO_ROOT/plugins/dso/config/test-runners.yaml"

# ── Verify manifest exists before parsing ────────────────────────────────────
if [[ ! -f "$MANIFEST" ]]; then
    echo "FAIL: manifest-exists" >&2
    echo "  manifest not found: $MANIFEST" >&2
    (( ++FAIL ))
    print_summary
fi

# ── Parse manifest once via python3 yaml.safe_load ───────────────────────────
_PARSED=$(python3 - "$MANIFEST" <<'PYEOF'
import sys, yaml, json

manifest_path = sys.argv[1]
with open(manifest_path) as f:
    data = yaml.safe_load(f)

harnesses = data.get("harnesses", [])
out = {}
for h in harnesses:
    hid = h.get("id", "")
    out[hid] = {
        "id": hid,
        "kind": h.get("kind", ""),
        "invocation": h.get("invocation", None),
        "verdict_adapter": h.get("verdict_adapter", None),
        "delegate_engine": h.get("delegate_engine", ""),
    }

print(json.dumps({"harnesses": out, "ids": list(out.keys())}))
PYEOF
)

# ── Helper: extract field from parsed JSON ────────────────────────────────────
_field() {
    local hid="$1" field="$2"
    python3 -c "import sys, json; d=json.loads(sys.stdin.read()); print(d['harnesses'].get('$hid', {}).get('$field', '') or '')" <<< "$_PARSED"
}

_ids() {
    python3 -c "import sys, json; d=json.loads(sys.stdin.read()); print(json.dumps(d['ids']))" <<< "$_PARSED"
}

_harness_count() {
    python3 -c "import sys, json; d=json.loads(sys.stdin.read()); print(len(d['harnesses']))" <<< "$_PARSED"
}

# ── Test: dd-1(a) — all four harnesses present ───────────────────────────────
# Given: the parsed harnesses list
# When:  checking for the four required ids
# Then:  each id is present in the manifest

_count=$(_harness_count)
assert_eq "dd1_harness_count_is_4" "4" "$_count"

for _hid in "bash-runner.sh" "suite-engine.sh" "validate.sh" "run-hook-tests.sh"; do
    _kind=$(_field "$_hid" "kind")
    assert_ne "dd1_harness_present_${_hid}" "" "$_kind"
done

# ── Test: dd-1(b) — each harness has non-empty invocation ────────────────────
# Given: the parsed harnesses list
# When:  reading the invocation field for each harness
# Then:  invocation is non-empty (not null/empty string)

for _hid in "bash-runner.sh" "suite-engine.sh" "validate.sh" "run-hook-tests.sh"; do
    _inv=$(_field "$_hid" "invocation")
    assert_ne "dd1_invocation_nonempty_${_hid}" "" "$_inv"
done

# ── Test: dd-1(c) — each harness has non-empty verdict_adapter ───────────────
# Given: the parsed harnesses list
# When:  reading the verdict_adapter field for each harness
# Then:  verdict_adapter is non-empty

for _hid in "bash-runner.sh" "suite-engine.sh" "validate.sh" "run-hook-tests.sh"; do
    _va=$(_field "$_hid" "verdict_adapter")
    assert_ne "dd1_verdict_adapter_nonempty_${_hid}" "" "$_va"
done

# ── Test: dd-2(a) — kind=engine for bash-runner.sh and suite-engine.sh ───────
# Given: the parsed harnesses list
# When:  reading kind for engine harnesses
# Then:  kind == "engine"

assert_eq "dd2_kind_engine_bash_runner" "engine" "$(_field "bash-runner.sh" "kind")"
assert_eq "dd2_kind_engine_suite_engine" "engine" "$(_field "suite-engine.sh" "kind")"

# ── Test: dd-2(b) — kind=wrapper for validate.sh and run-hook-tests.sh ───────
# Given: the parsed harnesses list
# When:  reading kind for wrapper harnesses
# Then:  kind == "wrapper"

assert_eq "dd2_kind_wrapper_validate" "wrapper" "$(_field "validate.sh" "kind")"
assert_eq "dd2_kind_wrapper_run_hook_tests" "wrapper" "$(_field "run-hook-tests.sh" "kind")"

# ── Test: dd-2(c) — wrapper delegate_engine resolves to a declared engine id ──
# Given: the parsed harnesses list
# When:  reading delegate_engine for each wrapper and checking it against declared engine ids
# Then:  the delegate resolves to an existing engine harness (dangling reference fails)

_engine_ids=$(python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
engines = [hid for hid, h in d['harnesses'].items() if h.get('kind') == 'engine']
print(' '.join(engines))
" <<< "$_PARSED")

_validate_delegate=$(_field "validate.sh" "delegate_engine")
_run_hook_delegate=$(_field "run-hook-tests.sh" "delegate_engine")

# Check validate.sh delegate is a declared engine
_validate_resolved=$(python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
engines = {hid for hid, h in d['harnesses'].items() if h.get('kind') == 'engine'}
delegate = d['harnesses'].get('validate.sh', {}).get('delegate_engine', '')
print('resolved' if delegate in engines else 'dangling:' + delegate)
" <<< "$_PARSED")
assert_eq "dd2_delegate_engine_validate_resolves" "resolved" "$_validate_resolved"

# Check run-hook-tests.sh delegate is a declared engine
_run_hook_resolved=$(python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
engines = {hid for hid, h in d['harnesses'].items() if h.get('kind') == 'engine'}
delegate = d['harnesses'].get('run-hook-tests.sh', {}).get('delegate_engine', '')
print('resolved' if delegate in engines else 'dangling:' + delegate)
" <<< "$_PARSED")
assert_eq "dd2_delegate_engine_run_hook_tests_resolves" "resolved" "$_run_hook_resolved"

# ── Test: dd-3 — bash-runner invocation records test-batched.sh --runner=bash ─
# Given: the parsed harnesses list
# When:  reading the invocation field for bash-runner.sh
# Then:  invocation contains "test-batched.sh" and "--runner=bash"

_bash_runner_inv=$(_field "bash-runner.sh" "invocation")
assert_contains "dd3_bash_runner_inv_has_test_batched" "test-batched.sh" "$_bash_runner_inv"
assert_contains "dd3_bash_runner_inv_has_runner_bash" "--runner=bash" "$_bash_runner_inv"

# ── Test: AC amendment — verdict_adapter has non-empty name/path shape ────────
# Given: the parsed harnesses list
# When:  reading verdict_adapter for each harness
# Then:  verdict_adapter is a non-empty string or a dict (not bare null/empty placeholder)

_va_shapes=$(python3 - "$MANIFEST" <<'PYEOF'
import sys, yaml, json

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

results = []
for h in data.get("harnesses", []):
    hid = h.get("id", "")
    va = h.get("verdict_adapter")
    if va is None:
        results.append(f"{hid}: FAIL (null)")
    elif isinstance(va, dict):
        if va:
            results.append(f"{hid}: OK (dict)")
        else:
            results.append(f"{hid}: FAIL (empty dict)")
    elif isinstance(va, str):
        if va.strip():
            results.append(f"{hid}: OK (string)")
        else:
            results.append(f"{hid}: FAIL (empty string)")
    else:
        results.append(f"{hid}: OK (other)")

print("\n".join(results))
PYEOF
)

# All must be OK
_va_fail_count=$(echo "$_va_shapes" | grep -c "FAIL" || echo "0")
assert_eq "ac_amendment_verdict_adapter_shape_all_ok" "0" "$_va_fail_count"

# ── Test: AC amendment — harness id uniqueness ────────────────────────────────
# Given: the parsed harnesses list
# When:  counting ids vs unique ids
# Then:  all 4 ids are unique

_id_unique_check=$(python3 - "$MANIFEST" <<'PYEOF'
import sys, yaml

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

ids = [h.get("id", "") for h in data.get("harnesses", [])]
if len(ids) == len(set(ids)) == 4:
    print("unique_4")
else:
    print(f"fail:ids={ids}")
PYEOF
)
assert_eq "ac_amendment_id_uniqueness" "unique_4" "$_id_unique_check"

# ── Test: AC amendment — invocation target files exist on disk ────────────────
# Given: the known harness file paths on disk
# When:  checking for file existence
# Then:  all four harness files and test-batched.sh exist

for _fpath in \
    "plugins/dso/scripts/runners/bash-runner.sh" \
    "tests/lib/suite-engine.sh" \
    "plugins/dso/scripts/validate.sh" \
    "tests/hooks/run-hook-tests.sh" \
    "plugins/dso/scripts/test-batched.sh"
do
    _label="ac_amendment_file_exists_$(basename "$_fpath" .sh | tr '-' '_')"
    if [[ -f "$REPO_ROOT/$_fpath" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  at: %s:%s\n  file not found: %s\n" "$_label" "${BASH_SOURCE[0]}" "$LINENO" "$REPO_ROOT/$_fpath" >&2
    fi
done

# ── Test: manifest is parseable YAML (structural sanity) ─────────────────────
# Given: the manifest file
# When:  parsing with yaml.safe_load
# Then:  no exception is raised (exit 0 from the parse above already covers this)

_parse_ok=$(python3 -c "
import yaml
with open('$MANIFEST') as f:
    data = yaml.safe_load(f)
assert 'harnesses' in data, 'missing top-level harnesses key'
print('ok')
" 2>&1)
assert_eq "manifest_is_valid_yaml_with_harnesses_key" "ok" "$_parse_ok"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
