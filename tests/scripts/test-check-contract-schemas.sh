#!/usr/bin/env bash
# tests/scripts/test-check-contract-schemas.sh
# Behavioral RED tests for check-contract-schemas.sh — contract structural validator.
#
# Tests:
#  1. test_valid_signal_contract              — full signal contract structure → exit 0
#  2. test_valid_tag_contract                 — tag contract (no Signal Format) → exit 0
#  3. test_missing_purpose_section            — contract without ## Purpose → exit 1
#  4. test_missing_heading                    — contract without # Contract: heading → exit 1
#  5. test_empty_purpose_content              — ## Purpose present but empty → exit 1
#  6. test_signal_contract_missing_canonical_prefix — has ## Signal Format but no ### Canonical parsing prefix → exit 1
#  7. test_signal_contract_empty_canonical_prefix   — has ### Canonical parsing prefix but empty content → exit 1
#  8. test_real_contracts_pass                — run against actual contracts/ dir → exit 0
#
# Usage: bash tests/scripts/test-check-contract-schemas.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# REVIEW-DEFENSE: '-e' is intentionally omitted. The test harness captures
# non-zero exit codes from script invocations via || assignment. With '-e',
# expected non-zero exits would abort the script before assertions run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-contract-schemas.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-contract-schemas.sh ==="

_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap '_cleanup' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── test_valid_signal_contract ─────────────────────────────────────────────────
# A contract file with a valid signal contract structure (# Contract: heading,
# ## Purpose with content, ## Signal Format, and ### Canonical parsing prefix
# with content) must exit 0.
test_valid_signal_contract() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/valid-signal-contract.md"
    cat > "$_file" <<'EOF'
# Contract: Example Signal Contract

## Purpose

This contract defines the output interface for the example signal emitted by sub-agents.

## Signal Name

`EXAMPLE`

## Signal Format

The emitter outputs the signal as a single standalone line:

```
EXAMPLE:<value>
```

### Canonical parsing prefix

The parser MUST match against:

- `EXAMPLE:` — prefix match on the line.

Parsers must not treat a bare `EXAMPLE` with no colon as valid.

## Consumers

| Component | Role |
|---|---|
| emitter.sh | Emitter |
| parser.sh | Parser |
EOF
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_valid_signal_contract: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_valid_signal_contract"
}

# ── test_valid_tag_contract ────────────────────────────────────────────────────
# A contract file with only the universal required sections (# Contract: heading
# and ## Purpose with content) but no ## Signal Format section must exit 0 —
# signal-specific rules do not apply.
test_valid_tag_contract() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/valid-tag-contract.md"
    cat > "$_file" <<'EOF'
# Contract: Tag Contract Schema

## Purpose

This contract defines the tags that can be applied to tickets within the system.
Tags must follow the namespaced colon-separated format.

## Allowed Tags

| Tag | Meaning |
|---|---|
| `CLI_user` | Ticket created by explicit user request during interactive session |
| `scrutiny:pending` | Epic blocked pending brainstorm review |
EOF
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_valid_tag_contract: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_valid_tag_contract"
}

# ── test_missing_purpose_section ───────────────────────────────────────────────
# A contract file missing ## Purpose must exit 1.
test_missing_purpose_section() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/missing-purpose.md"
    cat > "$_file" <<'EOF'
# Contract: Missing Purpose Contract

## Consumers

This contract has no purpose section at all.
EOF
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_missing_purpose_section: exit non-zero" "0" "$_exit"
    assert_pass_if_clean "test_missing_purpose_section"
}

# ── test_missing_heading ───────────────────────────────────────────────────────
# A contract file whose first level-1 heading does not start with # Contract:
# must exit 1.
test_missing_heading() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/missing-heading.md"
    cat > "$_file" <<'EOF'
# Wrong Title Format

## Purpose

This file has a level-1 heading but it does not start with "# Contract:".
EOF
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_missing_heading: exit non-zero" "0" "$_exit"
    assert_pass_if_clean "test_missing_heading"
}

# ── test_empty_purpose_content ─────────────────────────────────────────────────
# A contract file with ## Purpose present but with no non-empty content
# beneath it must exit 1.
test_empty_purpose_content() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/empty-purpose.md"
    cat > "$_file" <<'EOF'
# Contract: Empty Purpose Contract

## Purpose

## Consumers

Some content here but the purpose section is blank.
EOF
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_empty_purpose_content: exit non-zero" "0" "$_exit"
    assert_pass_if_clean "test_empty_purpose_content"
}

# ── test_signal_contract_missing_canonical_prefix ─────────────────────────────
# A contract file with ## Signal Format (making it a signal contract) but
# missing the ### Canonical parsing prefix subsection must exit 1.
test_signal_contract_missing_canonical_prefix() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/signal-no-canonical-prefix.md"
    cat > "$_file" <<'EOF'
# Contract: Signal Without Canonical Prefix

## Purpose

This contract defines a signal but is missing the canonical parsing prefix section.

## Signal Format

The emitter outputs:

```
EXAMPLE:<value>
```

### Field definitions

| Field | Description |
|---|---|
| value | The payload |

## Consumers

| Component | Role |
|---|---|
| emitter.sh | Emitter |
EOF
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_signal_contract_missing_canonical_prefix: exit non-zero" "0" "$_exit"
    assert_pass_if_clean "test_signal_contract_missing_canonical_prefix"
}

# ── test_signal_contract_empty_canonical_prefix ───────────────────────────────
# A contract file with ## Signal Format and ### Canonical parsing prefix
# present but with no non-empty content beneath the subsection must exit 1.
test_signal_contract_empty_canonical_prefix() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/signal-empty-canonical-prefix.md"
    cat > "$_file" <<'EOF'
# Contract: Signal With Empty Canonical Prefix

## Purpose

This contract defines a signal with an empty canonical parsing prefix section.

## Signal Format

The emitter outputs:

```
EXAMPLE:<value>
```

### Canonical parsing prefix

### Field definitions

| Field | Description |
|---|---|
| value | The payload |
EOF
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_signal_contract_empty_canonical_prefix: exit non-zero" "0" "$_exit"
    assert_pass_if_clean "test_signal_contract_empty_canonical_prefix"
}

# ── test_real_contracts_pass ───────────────────────────────────────────────────
# Running check-contract-schemas.sh against the actual plugins/dso/docs/contracts/
# directory must exit 0 — all real contracts must conform to the schema.
test_real_contracts_pass() {
    _snapshot_fail
    local _exit _out
    _exit=0
    _out=$(bash "$SCRIPT" "$PLUGIN_ROOT/plugins/dso/docs/contracts/" 2>&1) || _exit=$?
    assert_eq "test_real_contracts_pass: all real contracts exit 0" "0" "$_exit"
    assert_pass_if_clean "test_real_contracts_pass"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_valid_signal_contract
test_valid_tag_contract
test_missing_purpose_section
test_missing_heading
test_empty_purpose_content
test_signal_contract_missing_canonical_prefix
test_signal_contract_empty_canonical_prefix
test_real_contracts_pass

print_summary
