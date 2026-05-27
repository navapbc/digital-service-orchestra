#!/usr/bin/env bash
# pre-verifier-execute.sh — Execute DD-level Verify commands and produce a JSON trace.
#
# Input:  story ticket ID
# Output: path to JSON trace file (printed to stdout)
#
# Contract: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/execution-trace.md
# Does NOT attempt fixes or dispatch sub-agents. Pure execution and reporting.
set -euo pipefail

STORY_ID="${1:-}"
if [ -z "$STORY_ID" ]; then
    echo "Usage: pre-verifier-execute.sh <story-id>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve timeout from config (default 60s)
DEFAULT_TIMEOUT=60
TIMEOUT_SECONDS="${DSO_VERIFY_TIMEOUT:-$DEFAULT_TIMEOUT}"
if [ "$TIMEOUT_SECONDS" = "$DEFAULT_TIMEOUT" ] && [ -f "$SCRIPT_DIR/read-config.sh" ]; then
    _cfg_timeout=$(bash "$SCRIPT_DIR/read-config.sh" verify.timeout_seconds 2>/dev/null) || true
    if [ -n "$_cfg_timeout" ] && [ "$_cfg_timeout" -gt 0 ] 2>/dev/null; then
        TIMEOUT_SECONDS="$_cfg_timeout"
    fi
fi

# ── Load ticket data ─────────────────────────────────────────────────────────

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"

# Allow overriding the ticket script path for testing
TICKET_CMD="${DSO_TICKET_CMD:-$REPO_ROOT/.claude/scripts/dso ticket}"

TICKET_JSON=$($TICKET_CMD show "$STORY_ID" 2>/dev/null) || {
    echo "Error: could not load ticket $STORY_ID" >&2
    exit 1
}

# Extract DDs from the ticket description
DESCRIPTION=$(printf '%s' "$TICKET_JSON" | jq -r '.description // ""')

# Build manifest from DD list (independent of verify_commands)
MANIFEST_JSON=$(python3 -c "
import json, re, sys

desc = sys.argv[1]
dds = []
in_dd_section = False
dd_counter = 0

for line in desc.split('\n'):
    stripped = line.strip()
    if re.match(r'^#{1,3}\s*Done\s+Def', stripped, re.IGNORECASE):
        in_dd_section = True
        continue
    if in_dd_section and re.match(r'^#{1,3}\s', stripped):
        in_dd_section = False
        continue
    if in_dd_section and stripped.startswith('- '):
        dd_counter += 1
        dd_text = stripped[2:].strip()
        # Remove sub-bullets and metadata lines
        if dd_text and not dd_text.startswith('<-') and not dd_text.startswith('Verify:'):
            dds.append({'dd_id': f'dd-{dd_counter}', 'dd_text': dd_text})

print(json.dumps(dds))
" "$DESCRIPTION" 2>/dev/null) || MANIFEST_JSON="[]"

# Load verify_commands from structured field
VERIFY_COMMANDS=$($TICKET_CMD get-verify-commands "$STORY_ID" 2>/dev/null) || VERIFY_COMMANDS="[]"

# ── Build manifest and execute ───────────────────────────────────────────────

TRACE_FILE=$(mktemp /tmp/verify-trace.XXXXXX)

# Known test runners for confidence classification
KNOWN_RUNNERS="pytest|make test|make test-|npm test|npm run test|curl |httpie |http |validate\.sh"

python3 -c "
import json, subprocess, sys, time, os, re

manifest_dds = json.loads(sys.argv[1])
verify_cmds_raw = json.loads(sys.argv[2])
timeout_secs = int(sys.argv[3])
trace_file = sys.argv[4]
known_runners = sys.argv[5]
story_id = sys.argv[6]

# Build a lookup from dd_id to command
cmd_lookup = {}
for vc in verify_cmds_raw:
    did = vc.get('dd_id', '')
    cmd = vc.get('command', '')
    if did and cmd:
        cmd_lookup[did] = cmd

# Build manifest entries
manifest = []
for dd in manifest_dds:
    dd_id = dd['dd_id']
    cmd = cmd_lookup.get(dd_id)
    entry = {
        'dd_id': dd_id,
        'dd_text': dd['dd_text'],
        'verify_command': cmd,
        'executed': False,
        'skip_reason': None if cmd else 'no verify command'
    }
    manifest.append(entry)

# Also add any verify_commands entries not in the DD list
manifest_ids = {m['dd_id'] for m in manifest}
for vc in verify_cmds_raw:
    did = vc.get('dd_id', '')
    if did and did not in manifest_ids:
        cmd = vc.get('command', '')
        manifest.append({
            'dd_id': did,
            'dd_text': vc.get('dd_text', ''),
            'verify_command': cmd if cmd else None,
            'executed': False,
            'skip_reason': None if cmd else 'no verify command'
        })

# Classify confidence
def classify_confidence(cmd):
    if re.search(known_runners, cmd):
        return 'high'
    if re.search(r'test-[^ ]*\.sh', cmd):
        return 'high'
    return 'normal'

# Execute commands
results = []
summary = {
    'total_dds': len(manifest),
    'executed': 0,
    'passed': 0,
    'failed': 0,
    'timeout': 0,
    'skipped': 0,
    'no_command': 0
}

for entry in manifest:
    if not entry['verify_command']:
        summary['no_command'] += 1
        continue

    entry['executed'] = True
    entry['skip_reason'] = None
    summary['executed'] += 1

    cmd = entry['verify_command']
    confidence = classify_confidence(cmd)

    for attempt in (1, 2):
        start_ms = int(time.time() * 1000)
        try:
            proc = subprocess.run(
                ['bash', '-c', cmd],
                capture_output=True,
                text=True,
                timeout=timeout_secs,
                cwd=os.environ.get('PROJECT_ROOT', os.getcwd())
            )
            duration_ms = int(time.time() * 1000) - start_ms
            exit_code = proc.returncode

            stdout_lines = (proc.stdout or '').strip().split('\n')
            stderr_lines = (proc.stderr or '').strip().split('\n')

            if exit_code == 0:
                outcome = 'PASS'
                summary['passed'] += 1
                results.append({
                    'dd_id': entry['dd_id'],
                    'verify_command': cmd,
                    'exit_code': exit_code,
                    'stdout_tail': '\n'.join(stdout_lines[-20:]),
                    'stderr_tail': '\n'.join(stderr_lines[-20:]),
                    'duration_ms': duration_ms,
                    'attempt': attempt,
                    'outcome': outcome,
                    'confidence': confidence
                })
                break
            else:
                if attempt == 1:
                    continue  # retry
                outcome = 'FAIL'
                summary['failed'] += 1
                results.append({
                    'dd_id': entry['dd_id'],
                    'verify_command': cmd,
                    'exit_code': exit_code,
                    'stdout_tail': '\n'.join(stdout_lines[-20:]),
                    'stderr_tail': '\n'.join(stderr_lines[-20:]),
                    'duration_ms': duration_ms,
                    'attempt': attempt,
                    'outcome': outcome,
                    'confidence': confidence
                })

        except subprocess.TimeoutExpired:
            duration_ms = int(time.time() * 1000) - start_ms
            if attempt == 1:
                continue  # retry
            outcome = 'TIMEOUT'
            summary['timeout'] += 1
            results.append({
                'dd_id': entry['dd_id'],
                'verify_command': cmd,
                'exit_code': -1,
                'stdout_tail': '',
                'stderr_tail': f'Command timed out after {timeout_secs}s',
                'duration_ms': duration_ms,
                'attempt': attempt,
                'outcome': outcome,
                'confidence': confidence
            })
            break

trace = {
    'schema_version': 1,
    'trace': {
        'story_id': story_id,
        'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'manifest': manifest,
        'results': results,
        'summary': summary
    }
}

with open(trace_file, 'w') as f:
    json.dump(trace, f, indent=2, ensure_ascii=False)
" "$MANIFEST_JSON" "$VERIFY_COMMANDS" "$TIMEOUT_SECONDS" "$TRACE_FILE" "$KNOWN_RUNNERS" "$STORY_ID"

echo "$TRACE_FILE"
