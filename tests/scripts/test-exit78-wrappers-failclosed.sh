#!/usr/bin/env bash
# tests/scripts/test-exit78-wrappers-failclosed.sh
#
# Story a85d-5f7f-8898-4a4f — fail-close the silent-pass review gates.
#
# The three backstop workflows each wrap a fail-closed script in a `run:` block
# that maps the script's exit 78 (PRECONDITION_NOT_MET) to a pass. Pre-fix that
# mapping was UNCONDITIONAL (78 → exit 0 always), so after the enforce-flip a
# token-scope regression or transient API blip silently green-stamps an
# un-reviewed candidate. This test asserts the wrapper logic is now mode-gated:
#
#   - WARN (default): exit 78 → exit 0 (advisory, ::warning) — unchanged today.
#   - ENFORCE:        exit 78 → non-zero (fail-closed, ::error).
#
# These are behavioral assertions against the ACTUAL `run:` script shipped in
# each YAML: we extract the wrapper block, replace the real `bash <script>`
# invocation with a stub that exits 78, and assert the wrapper's exit code by
# posture. No change-detector string matching on the YAML body.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WF_DIR="$REPO_ROOT/.github/workflows"

PASS=0
FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# Extract the multi-line shell body of the FIRST `run: |` block in a workflow
# file that contains the given anchor substring (so we pick the right step in a
# multi-step file). Emits the dedented script to stdout.
_extract_run_block() {
    local wf="$1" anchor="$2"
    python3 - "$wf" "$anchor" <<'PY'
import sys
path, anchor = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()
i = 0
n = len(lines)
while i < n:
    stripped = lines[i].strip()
    if stripped == "run: |":
        run_indent = len(lines[i]) - len(lines[i].lstrip())
        body = []
        j = i + 1
        block_indent = None
        while j < n:
            ln = lines[j]
            if ln.strip() == "":
                body.append("")
                j += 1
                continue
            cur_indent = len(ln) - len(ln.lstrip())
            if cur_indent <= run_indent:
                break
            if block_indent is None:
                block_indent = cur_indent
            body.append(ln[block_indent:])
            j += 1
        text = "\n".join(body)
        if anchor in text:
            print(text)
            sys.exit(0)
        i = j
        continue
    i += 1
sys.exit(3)  # not found
PY
}

# Run a wrapper body with the real script invocation replaced by a stub that
# exits 78, under a given posture. Echoes the wrapper exit code.
_run_wrapper() {
    local body="$1" script_token="$2" mode_var="$3" mode_val="$4"
    # Replace the `bash <script...>` line with `bash -c 'exit 78'` so rc=78 is
    # forced deterministically without invoking the heavy real check.
    local stubbed
    stubbed="$(echo "$body" | sed -E "s#bash ${script_token}[^\n]*#bash -c 'exit 78'#")"
    local script
    script="$(mktemp "${TMPDIR:-/tmp}/dso-wrapper.XXXXXX")"
    printf '%s\n' "$stubbed" >"$script"
    if [[ -n "$mode_val" ]]; then
        env "$mode_var=$mode_val" bash "$script" >/dev/null 2>&1
    else
        env -u "$mode_var" bash "$script" >/dev/null 2>&1
    fi
    local rc=$?
    rm -f "$script"
    echo "$rc"
}

# (workflow file, run-block anchor, script-token regex, mode var)
# script-token is an extended-regex fragment that matches the `bash <script>`
# line so we can stub it out.
_cases=(
    "review-coverage-invariant.yml|review-coverage-invariant.sh|plugins/dso/scripts/ci/review-coverage-invariant\.sh|DSO_COVERAGE_INVARIANT_MODE"
    "dangling-references.yml|check-dangling-references.sh|plugins/dso/scripts/ci/check-dangling-references\.sh|DSO_DANGLING_MODE"
    "ruleset-invariants.yml|test-ruleset-design-invariants.sh|tests/scripts/test-ruleset-design-invariants\.sh|DSO_RULESET_INVARIANTS_MODE"
)

for _case in "${_cases[@]}"; do
    IFS='|' read -r wf_name anchor script_token mode_var <<<"$_case"
    wf="$WF_DIR/$wf_name"
    body="$(_extract_run_block "$wf" "$anchor")" || {
        _fail "${wf_name}_run_block_extracted" "could not locate run block with anchor '$anchor'"
        continue
    }

    # Behavior 1: WARN posture → exit 78 maps to exit 0.
    warn_rc="$(_run_wrapper "$body" "$script_token" "$mode_var" "warn")"
    if [[ "$warn_rc" -eq 0 ]]; then
        _pass "${wf_name}_warn_exit78_maps_to_zero"
    else
        _fail "${wf_name}_warn_exit78_maps_to_zero" "expected 0, got $warn_rc"
    fi

    # Behavior 2: ENFORCE posture → exit 78 blocks (non-zero).
    enforce_rc="$(_run_wrapper "$body" "$script_token" "$mode_var" "enforce")"
    if [[ "$enforce_rc" -ne 0 ]]; then
        _pass "${wf_name}_enforce_exit78_blocks"
    else
        _fail "${wf_name}_enforce_exit78_blocks" "expected non-zero, got $enforce_rc — silent pass"
    fi

    # Behavior 3: DEFAULT (mode var unset) behaves like warn → exit 0.
    default_rc="$(_run_wrapper "$body" "$script_token" "$mode_var" "")"
    if [[ "$default_rc" -eq 0 ]]; then
        _pass "${wf_name}_default_is_warn_exits_zero"
    else
        _fail "${wf_name}_default_is_warn_exits_zero" "expected 0, got $default_rc"
    fi
done

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
