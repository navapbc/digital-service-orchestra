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

# Library-mode guard: when sourced with CI_FINDINGS_LIB_MODE=1, functions above are
# already defined; return to suppress further execution.
if [[ "${CI_FINDINGS_LIB_MODE:-0}" == "1" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
