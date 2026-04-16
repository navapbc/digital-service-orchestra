#!/usr/bin/env bash
# hooks/lib/validate-review-schemas.sh
# Schema validator functions extracted from validate-review-output.sh:
#   - validate_review_protocol_base: validates review-protocol base JSON schema
#   - validate_plan_review: validates plan-review structured text output
#
# These functions are self-contained Python validators invoked via heredoc.
# They do not depend on any external state from the calling script.
#
# Source this file from validate-review-output.sh:
#   source "${_PLUGIN_ROOT}/hooks/lib/validate-review-schemas.sh"

# --- Validator: review-protocol base schema ---
validate_review_protocol_base() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import sys, json

output_file = sys.argv[1]
with open(output_file) as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON: {e}")
        sys.exit(1)

errors = []

required_top = {"subject", "reviews", "conflicts"}
actual_top = set(data.keys())
missing = required_top - actual_top
extra = actual_top - required_top
if missing:
    errors.append(f"missing top-level keys: {sorted(missing)}")
if extra:
    errors.append(f"unexpected top-level keys: {sorted(extra)} (only 'subject', 'reviews', 'conflicts' allowed)")

subject = data.get("subject")
if subject is None:
    errors.append("missing 'subject' field")
elif not isinstance(subject, str) or not subject.strip():
    errors.append("'subject' must be a non-empty string")

reviews = data.get("reviews")
if reviews is None:
    errors.append("missing 'reviews' array")
elif not isinstance(reviews, list):
    errors.append("'reviews' must be an array")
elif len(reviews) == 0:
    errors.append("'reviews' must contain at least one entry")
else:
    valid_statuses = {"reviewed", "not_applicable"}
    valid_finding_severities = {"critical", "major", "minor"}
    for i, review in enumerate(reviews):
        prefix = f"reviews[{i}]"
        if not isinstance(review, dict):
            errors.append(f"{prefix}: must be an object")
            continue
        for field in ["perspective", "status", "dimensions", "findings"]:
            if field not in review:
                errors.append(f"{prefix}: missing required field '{field}'")
        status = review.get("status")
        if status is not None and status not in valid_statuses:
            errors.append(f"{prefix}.status: must be 'reviewed' or 'not_applicable', got: {status!r}")
        if status == "not_applicable" and "rationale" not in review:
            errors.append(f"{prefix}: 'rationale' is required when status is 'not_applicable'")
        dims = review.get("dimensions")
        if dims is not None:
            if not isinstance(dims, dict):
                errors.append(f"{prefix}.dimensions: must be an object")
            else:
                for dim_name, dim_score in dims.items():
                    if dim_score is not None:
                        if not isinstance(dim_score, int) or not (1 <= dim_score <= 5):
                            errors.append(f"{prefix}.dimensions.{dim_name}: must be integer 1-5 or null, got: {dim_score!r}")
        findings = review.get("findings")
        if findings is not None:
            if not isinstance(findings, list):
                errors.append(f"{prefix}.findings: must be an array")
            else:
                for j, finding in enumerate(findings):
                    fp = f"{prefix}.findings[{j}]"
                    if not isinstance(finding, dict):
                        errors.append(f"{fp}: must be an object")
                        continue
                    for field in ["dimension", "severity", "description", "suggestion"]:
                        if field not in finding:
                            errors.append(f"{fp}: missing required field '{field}'")
                    sev = finding.get("severity")
                    if sev is not None and sev not in valid_finding_severities:
                        errors.append(f"{fp}.severity: must be one of {sorted(valid_finding_severities)}, got: {sev!r}")

conflicts = data.get("conflicts")
if conflicts is None:
    errors.append("missing 'conflicts' array")
elif not isinstance(conflicts, list):
    errors.append("'conflicts' must be an array")
else:
    valid_patterns = {"add_vs_remove", "more_vs_less", "strict_vs_flexible", "expand_vs_reduce"}
    for i, conflict in enumerate(conflicts):
        prefix = f"conflicts[{i}]"
        if not isinstance(conflict, dict):
            errors.append(f"{prefix}: must be an object")
            continue
        for field in ["perspectives", "target", "finding_a", "finding_b", "pattern"]:
            if field not in conflict:
                errors.append(f"{prefix}: missing required field '{field}'")
        perspectives = conflict.get("perspectives")
        if perspectives is not None:
            if not isinstance(perspectives, list) or len(perspectives) != 2:
                errors.append(f"{prefix}.perspectives: must be an array of exactly 2 strings")
        pattern = conflict.get("pattern")
        if pattern is not None and pattern not in valid_patterns:
            errors.append(f"{prefix}.pattern: must be one of {sorted(valid_patterns)}, got: {pattern!r}")

if errors:
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

print("OK")
PYEOF
}

# --- Validator: plan-review ---
validate_plan_review() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import sys, re

output_file = sys.argv[1]
with open(output_file) as f:
    content = f.read()

errors = []
valid_verdicts = {"PASS", "REVISE"}
valid_dims = {"feasibility", "completeness", "yagni", "codebase_alignment"}
valid_severities = {"critical", "major", "minor"}

verdict_match = re.search(r'^VERDICT:\s*(\S+)', content, re.MULTILINE)
if not verdict_match:
    errors.append("missing 'VERDICT:' line")
else:
    verdict = verdict_match.group(1).strip()
    if verdict not in valid_verdicts:
        errors.append(f"VERDICT must be 'PASS' or 'REVISE', got: {verdict!r}")

if "SCORES:" not in content:
    errors.append("missing 'SCORES:' section marker")
else:
    score_lines = re.findall(r'^\s*-\s*(\w+):\s*(\d+)/5', content, re.MULTILINE)
    found_dims = set()
    for dim, score_val in score_lines:
        if dim not in valid_dims:
            errors.append(f"unknown score dimension: {dim!r} (valid: {sorted(valid_dims)})")
        else:
            found_dims.add(dim)
            score_int = int(score_val)
            if not (1 <= score_int <= 5):
                errors.append(f"score for '{dim}' must be 1-5, got: {score_int}")
    missing_dims = valid_dims - found_dims
    if missing_dims:
        errors.append(f"missing score dimensions: {sorted(missing_dims)}")

if "FINDINGS:" not in content:
    errors.append("missing 'FINDINGS:' section marker")
else:
    finding_blocks = re.findall(r'^FINDING:\s+\[(\w+)\]\s+\[severity:\s*(\w+)\]', content, re.MULTILINE)
    for dim, sev in finding_blocks:
        if dim not in valid_dims:
            errors.append(f"FINDING dimension {dim!r} not in valid set {sorted(valid_dims)}")
        if sev not in valid_severities:
            errors.append(f"FINDING severity {sev!r} not in valid set {sorted(valid_severities)}")
    if finding_blocks and "SUGGESTION:" not in content:
        errors.append("FINDING blocks present but no 'SUGGESTION:' line found")

if errors:
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

print("OK")
PYEOF
}
