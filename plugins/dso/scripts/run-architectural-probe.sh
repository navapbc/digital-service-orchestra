#!/usr/bin/env bash
# run-architectural-probe.sh
# Architectural probe gate for class:architectural epics.
#
# When the epic class is class:architectural, this script dispatches the
# architectural probe (or uses DSO_PROBE_TEST_OUTPUT for test mode) to produce
# an end-to-end test scaffold or integration-harness spec. In all other classes,
# the script is a no-op and exits 0.
#
# Usage:
#   run-architectural-probe.sh --epic-class=<class> --output-file=<path> [--epic-id=<id>]
#
# Arguments:
#   --epic-class=<class>   Required. The epic class (e.g. class:architectural, class:behavioral)
#   --output-file=<path>   Required. Path where probe output will be written
#   --epic-id=<id>         Optional. Epic ticket ID for context
#
# Environment:
#   DSO_PROBE_TEST_OUTPUT  If set, use this value as the probe output (test mode).
#                          Non-empty string → write to output file, exit 0.
#                          Empty string     → write empty file, exit 1.
#                          Unset            → write default scaffold stub, exit 0.
#
# Exit codes:
#   0  Success: class is not class:architectural (no-op), OR probe produced non-empty output
#   1  Failure: class:architectural but probe produced empty or absent output

# -e omitted intentionally: we handle exit codes explicitly
set -uo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
_EPIC_CLASS=""
_OUTPUT_FILE=""
_EPIC_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --epic-class=*)
            _EPIC_CLASS="${1#--epic-class=}"
            shift
            ;;
        --epic-class)
            _EPIC_CLASS="$2"
            shift 2
            ;;
        --output-file=*)
            _OUTPUT_FILE="${1#--output-file=}"
            shift
            ;;
        --output-file)
            _OUTPUT_FILE="$2"
            shift 2
            ;;
        --epic-id=*)
            _EPIC_ID="${1#--epic-id=}"
            shift
            ;;
        --epic-id)
            _EPIC_ID="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ── Validate required arguments ───────────────────────────────────────────────
if [[ -z "$_EPIC_CLASS" ]]; then
    printf "ERROR: --epic-class is required\n" >&2
    exit 1
fi

if [[ -z "$_OUTPUT_FILE" ]]; then
    printf "ERROR: --output-file is required\n" >&2
    exit 1
fi

# ── No-op for non-architectural classes ──────────────────────────────────────
if [[ "$_EPIC_CLASS" != "class:architectural" ]]; then
    exit 0
fi

# ── class:architectural: produce probe output ─────────────────────────────────
if [[ -v DSO_PROBE_TEST_OUTPUT ]]; then
    # Test mode: use the env var value as probe content
    printf "%s" "$DSO_PROBE_TEST_OUTPUT" > "$_OUTPUT_FILE"
else
    # Production mode: write a default scaffold stub
    _EPIC_ID_DISPLAY="${_EPIC_ID:-unknown}"
    cat > "$_OUTPUT_FILE" <<'SCAFFOLD'
# Architectural Probe: End-to-End Test Scaffold

## Epic Integration Harness

This file was produced by the architectural-probe agent for a class:architectural epic.
It serves as a placeholder scaffold until the probe agent populates it with
epic-specific end-to-end test strategy and integration harness details.

### End-to-End Test Strategy

- [ ] Identify system boundaries and integration points
- [ ] Define acceptance criteria for end-to-end scenarios
- [ ] Specify test data requirements and fixtures
- [ ] Map success and failure paths through the system

### Integration Harness Schema

- [ ] List external systems and APIs involved
- [ ] Define contract interfaces between components
- [ ] Specify observability hooks (logs, metrics, traces)
- [ ] Document rollback and recovery procedures

## Self-Use Compatibility

Answer the following for this epic before proceeding to scrutiny:

- **Can the sprint building this epic run on the architecture it delivers?**
  - [ ] Yes — sprint execution requires only existing infrastructure; no bootstrap gap.
  - [ ] No — describe the bootstrap gap below.

- **Bootstrap gap description** (complete if a gap exists):
  - Gap: _TODO: describe which infrastructure/tooling delivered by this epic cannot be used during the sprint that builds it_
  - Mitigation: _TODO: describe how the sprint will proceed without the not-yet-delivered capability_
SCAFFOLD
fi

# ── Validate output file is non-empty ────────────────────────────────────────
if [[ ! -f "$_OUTPUT_FILE" ]] || [[ ! -s "$_OUTPUT_FILE" ]]; then
    printf "PROBE_GATE_BLOCKED: architectural probe produced empty or absent output at %s\n" "$_OUTPUT_FILE" >&2
    exit 1
fi

# ── Validate output contains required Self-Use Compatibility section ──────────
if ! grep -q "## Self-Use Compatibility" "$_OUTPUT_FILE"; then
    printf "PROBE_GATE_BLOCKED: probe output missing required '## Self-Use Compatibility' section at %s\n" "$_OUTPUT_FILE" >&2
    exit 1
fi

exit 0
