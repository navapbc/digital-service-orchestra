#!/usr/bin/env bash
# tests/fixtures/818-corpus/generate-corpus-fixture.sh
# Generates tests/fixtures/818-corpus/sample-bugs.json with ≥100 synthetic bug records.
#
# Each record: {"id":"bug-NNN","description":"...","type":"linting|logic|schema|runtime|boundary","severity":"low|medium|high|critical"}
#
# Idempotent: re-running produces the same file (deterministic output).
# Output path overridable via CORPUS_OUTPUT env variable (for tests).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${CORPUS_OUTPUT:-$SCRIPT_DIR/sample-bugs.json}"

python3 - "$OUTPUT" <<'PYEOF'
import json, os, sys

output_path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CORPUS_OUTPUT", "sample-bugs.json")

types = ["linting", "logic", "schema", "runtime", "boundary"]
severities = ["low", "medium", "high", "critical"]

# Deterministic descriptions per type/severity combination
descriptions = {
    "linting": [
        "Variable declared but never used in hook script",
        "Missing shellcheck directive for SC2086 unquoted expansion",
        "Function defined after first use without forward declaration",
        "Inconsistent indentation (tabs vs spaces) in configuration file",
        "Hard-coded debug print statement left in production code",
    ],
    "logic": [
        "Off-by-one error in loop boundary causes last element to be skipped",
        "Incorrect operator: uses assignment (=) instead of equality (==) in conditional",
        "Boolean logic inverted: NOT applied to wrong subexpression",
        "Integer overflow when ticket count exceeds 16-bit boundary",
        "Race condition: file read between existence check and open",
        "Null dereference when optional field absent from PRECONDITIONS event",
        "Wrong base for percentage calculation: divides by 100 instead of total",
        "Truncation error: integer division loses fractional restart rate",
        "Missing guard: continues processing after validator returns non-zero",
        "Stale cache not invalidated after ticket state transition",
    ],
    "schema": [
        "PRECONDITIONS event missing required schema_version field",
        "tier field accepts undeclared value 'ultra-deep' not in schema",
        "manifest_depth value 'EXTREME' not in {minimal,standard,deep}",
        "timestamp field stored as string instead of integer milliseconds",
        "gate_name field allows empty string, violating schema constraint",
        "session_id missing from event written by batch-lifecycle handler",
        "worktree_id set to null instead of empty string when not in worktree",
        "data field is array instead of object for fp_flagged events",
        "event_type field uses underscore (PRECONDITIONS_V2) instead of canonical form",
        "Schema version field is integer 2 instead of string '2'",
    ],
    "runtime": [
        "flock timeout exceeded when tickets branch has >10k events",
        "gc.auto not set to 0 before batch write, triggering git gc mid-operation",
        "Temp file created in /tmp/ not cleaned up on SIGTERM",
        "EAGAIN on socket when OAuth usage endpoint rate-limits heavy polling",
        "File descriptor leak: fd not closed after flock acquisition fails",
        "mktemp falls back to predictable path when TMPDIR unset on NixOS",
        "Recursive ticket compact triggers another compact, causing loop",
        "SIGPIPE when downstream consumer closes pipe during streaming output",
        "Exit 144 from test runner not distinguished from other non-zero exits",
        "Stale lock file from killed process blocks next session for 30s",
        "JSON parse error on malformed event causes entire batch to abort",
        "Python3 fcntl.flock unavailable on Windows Subsystem for Linux v1",
    ],
    "boundary": [
        "Empty ticket directory handled incorrectly: returns error instead of empty list",
        "Single-event corpus reports division-by-zero in prevention_rate calculation",
        "Zero-byte PRECONDITIONS.json file treated as valid event",
        "Corpus with exactly 100 bugs triggers off-by-one in >= comparison",
        "Ticket ID containing path separator (/) breaks directory resolution",
        "Unicode in description field causes JSON parse to fail on macOS locale",
        "Baseline rate of 0.0 causes Wilson CI calculation to return NaN",
        "Post rate higher than baseline produces negative drop_pct",
        "Sample size of 1 produces degenerate 95% CI bounds [0, 1]",
        "Threshold of 0 trivially passes; gate should reject threshold < 1",
        "FP rate exactly at threshold (0.10) should not trigger fallback",
        "manifest_depth defaults to 'standard' when field absent from old event",
    ],
}

records = []
record_num = 1

for bug_type, descs in descriptions.items():
    for i, desc in enumerate(descs):
        sev = severities[i % len(severities)]
        records.append({
            "id": f"bug-{record_num:03d}",
            "description": desc,
            "type": bug_type,
            "severity": sev,
        })
        record_num += 1

# Pad to 120 records with additional boundary and logic bugs for coverage
extra_logic = [
    ("logic", "medium", "Comparison uses string equality for numeric ticket count"),
    ("logic", "high", "Short-circuit evaluation bypasses mandatory side effect"),
    ("logic", "low", "Dead branch: condition is always true due to prior assignment"),
    ("boundary", "critical", "MAX_AGENTS cap of 0 not enforced when orchestration.max_agents is null"),
    ("boundary", "high", "Batch size of exactly max_agents triggers fence-post error"),
    ("schema", "medium", "Extra field 'debug_info' in event passes write but rejected by validator"),
    ("schema", "low", "Field order in JSON output differs from contract specification"),
    ("linting", "low", "Trailing whitespace in heredoc body causes SC1009 in strict mode"),
    ("runtime", "high", "Concurrent writes to same ticket directory without flock cause corruption"),
    ("runtime", "medium", "Log rotation mid-session truncates breadcrumb file to zero bytes"),
    ("logic", "critical", "Validator returns exit 0 for unknown gate_name instead of exit 2"),
    ("boundary", "medium", "Empty corpus produces COVERAGE_RESULT with prevention_rate NaN"),
    ("schema", "critical", "Missing required 'signal' field causes parser to raise KeyError"),
    ("linting", "medium", "Unused import statement in Python bridge module"),
    ("runtime", "low", "Warning suppressed via 2>/dev/null hides legitimate stderr diagnostic"),
    ("logic", "high", "Regex captures wrong group when ticket ID contains hyphen"),
    ("boundary", "low", "Ticket ID of length 1 accepted but violates 8-char minimum"),
    ("logic", "medium", "Confidence interval uses Z=1.64 for 90% instead of 1.96 for 95%"),
    ("schema", "high", "fp_rate field stored as string '0.15' instead of float 0.15"),
    ("runtime", "critical", "PRECONDITIONS write fails silently when .tickets-tracker is read-only"),
    ("boundary", "high", "Wilson CI lower bound returns negative value for small samples"),
    ("logic", "low", "Fallback engagement flag not cleared when fp_rate drops below threshold"),
    ("schema", "medium", "event_type field truncated to 12 characters on some filesystems"),
    ("linting", "high", "SC2155: local variable assigned from command substitution in one step"),
    ("runtime", "medium", "Temp directory not removed when generator called with CORPUS_OUTPUT=/dev/null"),
    ("boundary", "critical", "Corpus with 0 records of a given type causes type distribution check to fail"),
    ("logic", "high", "Drop_pct rounds to 0 when baseline and post are both very small floats"),
    ("schema", "low", "schema_version field has value '2.0' instead of '2'"),
    ("runtime", "high", "Git commit in flock critical section times out when repo has 100k objects"),
    ("boundary", "medium", "Benchmark p95 undefined when iterations < 20 samples"),
    # Additional records to reach ≥ 100 total
    ("logic", "critical", "Preconditions validator treats exit 2 as passed when gate name is unknown"),
    ("linting", "low", "Function name uses camelCase instead of project snake_case convention"),
    ("schema", "medium", "FALLBACK_ENGAGED signal lacks required ticket_id field in output"),
    ("runtime", "high", "Orphaned lock file from SIGKILL blocks all writes for 30-min TTL"),
    ("boundary", "low", "Negative sample size passed to sc13-restart-analysis causes divide-by-zero"),
    ("logic", "medium", "Benchmark p95 computed before sorting samples, giving wrong percentile"),
    ("schema", "high", "ci_lower and ci_upper swapped in Wilson CI output when post > baseline"),
    ("linting", "medium", "Deprecated bash construct: uses backtick instead of $() for substitution"),
    ("runtime", "critical", "PRECONDITIONS read returns empty on first call due to filesystem cache lag"),
    ("boundary", "high", "Corpus size of exactly threshold (100) requires >= not > comparison"),
    ("logic", "low", "String comparison for ticket_id 'None' fails when id is Python None"),
    ("schema", "critical", "manifest_depth absent from minimal-tier events, violates schema_version 2"),
    ("linting", "high", "set -e not present in corpus generator script, masks python3 exit code"),
    ("runtime", "medium", "flock acquire succeeds but file renamed by concurrent process before write"),
    ("boundary", "medium", "fp_rate threshold of exactly 0.0 causes division by zero in rate calc"),
    ("logic", "high", "Gate_name field present but empty string treated as valid gate by validator"),
    ("schema", "low", "Sample-bugs.json uses Windows line endings (CRLF), breaks json.load on Linux"),
    ("runtime", "low", "Python3 subprocess encoding defaults to ASCII, fails on Unicode bug descriptions"),
    ("boundary", "critical", "Preconditions compact skips last event when count is exact power of 2"),
    ("logic", "medium", "Fallback writes minimal event with wrong ticket_id (uses env var instead of arg)"),
    ("schema", "high", "p95_ms field is integer in spec but float in implementation output"),
]

for bug_type, sev, desc in extra_logic:
    records.append({
        "id": f"bug-{record_num:03d}",
        "description": desc,
        "type": bug_type,
        "severity": sev,
    })
    record_num += 1

# Ensure we have >= 100 records
assert len(records) >= 100, f"Expected >= 100 records, got {len(records)}"

with open(output_path, "w") as f:
    json.dump(records, f, indent=2)
    f.write("\n")

print(f"Generated {len(records)} bug records → {output_path}", file=sys.stderr)
PYEOF
