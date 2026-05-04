#!/usr/bin/env bash

_normalize_tier1() {
    local _input="$1"
    local _output="$2"

    # Validate input has findings key
    local _has_findings
    _has_findings=$(python3 - "$_input" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as fh:
        d = json.load(fh)
    print('yes' if 'findings' in d else 'no')
except Exception:
    print('error')
PYEOF
)

    if [[ "$_has_findings" != "yes" ]]; then
        return 1
    fi

    # Normalize and write output
    python3 - "$_input" "$_output" <<'PYEOF'
import json, sys
input_path = sys.argv[1]
output_path = sys.argv[2]
try:
    with open(input_path) as fh:
        d = json.load(fh)
    findings = d.get('findings', [])
    normalized = []
    for f in findings:
        normalized.append({
            'severity': f.get('severity', ''),
            'description': f.get('description', ''),
            'file': f.get('file', '')
        })
    out = {'schema_version': 1, 'tier': 'llm-review', 'findings': normalized}
    with open(output_path, 'w') as fh:
        json.dump(out, fh, indent=2)
except Exception as e:
    print('ci-findings-normalize: error writing output: ' + str(e), file=sys.stderr)
    sys.exit(1)
PYEOF
}

_fetch_ci_log() {
    local _run_id="$1" _output="$2"
    gh run view --log-failed "$_run_id" > "$_output" 2>/dev/null
}

_normalize_tier2() {
    local _input="$1"
    local _output="$2"

    # Empty input → ARTIFACT_MISSING
    if [[ -z "$_input" ]] || [[ ! -f "$_input" ]]; then
        return 3
    fi

    python3 - "$_input" "$_output" <<'PYEOF'
import json, sys, re
input_path = sys.argv[1]
output_path = sys.argv[2]
try:
    with open(input_path) as fh:
        text = fh.read()
    findings = []
    for line in text.splitlines():
        # pytest FAILED
        m = re.match(r'^FAILED ([\w/.\-]+\.py)(?:::([\w_]+))?', line)
        if m:
            findings.append({'severity': 'important', 'description': m.group(2) or 'test failed', 'file': m.group(1)})
            continue
        # pytest ERROR
        m = re.match(r'^ERROR ([\w/.\-]+\.py)', line)
        if m:
            findings.append({'severity': 'critical', 'description': 'ERROR', 'file': m.group(1)})
            continue
    # If no structured findings, emit a generic one
    if not findings and text.strip():
        findings.append({'severity': 'important', 'description': 'test failure — see log', 'file': ''})
    out = {'schema_version': 1, 'tier': 'test', 'findings': findings}
    with open(output_path, 'w') as fh:
        json.dump(out, fh, indent=2)
except Exception as e:
    print('ci-findings-normalize: error in tier2: ' + str(e), file=sys.stderr)
    sys.exit(1)
PYEOF
}

_normalize_tier3() {
    local _input="$1"
    local _output="$2"

    # Empty input → ARTIFACT_MISSING
    if [[ -z "$_input" ]] || [[ ! -f "$_input" ]]; then
        return 3
    fi

    python3 - "$_input" "$_output" <<'PYEOF'
import json, sys, re
input_path = sys.argv[1]
output_path = sys.argv[2]
try:
    with open(input_path) as fh:
        text = fh.read()
    findings = []
    for line in text.splitlines():
        # ruff: path:line:col: CODE message
        m = re.match(r'^([\w/.\-]+\.\w+):(\d+):\d+:\s+([EWF]\d+)\s+(.*)', line)
        if m:
            sev = 'critical' if m.group(3).startswith('E') else 'important'
            findings.append({'severity': sev, 'description': '%s %s' % (m.group(3), m.group(4)), 'file': m.group(1)})
            continue
        # eslint: path  line:col  error/warning  message  rule
        m = re.match(r'^([\w/.\-]+\.\w+)\s+\d+:\d+\s+(error|warning)\s+(.*)', line)
        if m:
            sev = 'critical' if m.group(2) == 'error' else 'important'
            findings.append({'severity': sev, 'description': m.group(3), 'file': m.group(1)})
            continue
    if not findings and text.strip():
        findings.append({'severity': 'important', 'description': 'lint failure — see log', 'file': ''})
    out = {'schema_version': 1, 'tier': 'lint', 'findings': findings}
    with open(output_path, 'w') as fh:
        json.dump(out, fh, indent=2)
except Exception as e:
    print('ci-findings-normalize: error in tier3: ' + str(e), file=sys.stderr)
    sys.exit(1)
PYEOF
}

_normalize_tier4() {
    local _input="$1"
    local _output="$2"

    # Empty input → ARTIFACT_MISSING
    if [[ -z "$_input" ]] || [[ ! -f "$_input" ]]; then
        return 3
    fi

    python3 - "$_input" "$_output" <<'PYEOF'
import json, sys, re
input_path = sys.argv[1]
output_path = sys.argv[2]
try:
    with open(input_path) as fh:
        text = fh.read()
    findings = []
    for line in text.splitlines():
        if re.search(r'error|fail|warning|exception|critical', line, re.IGNORECASE):
            findings.append({'severity': 'important', 'description': line.strip()[:200], 'file': ''})
    if not findings and text.strip():
        findings.append({'severity': 'important', 'description': 'Unknown CI failure — see log', 'file': ''})
    out = {'schema_version': 1, 'tier': 'other', 'findings': findings}
    with open(output_path, 'w') as fh:
        json.dump(out, fh, indent=2)
except Exception as e:
    print('ci-findings-normalize: error in tier4: ' + str(e), file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Library-mode guard: when sourced with CI_FINDINGS_LIB_MODE=1, functions above are
# already defined; return to suppress further execution.
if [[ "${CI_FINDINGS_LIB_MODE:-0}" == "1" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
