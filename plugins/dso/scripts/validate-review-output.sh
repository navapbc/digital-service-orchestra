#!/usr/bin/env bash
set -euo pipefail
# scripts/validate-review-output.sh
# Validates review agent output against the expected schema for a given prompt.
#
# Usage:
#   validate-review-output.sh <prompt-id> <output-file> [--caller <caller-id>]
#   validate-review-output.sh --list
#   validate-review-output.sh --list-callers
#
# Prompt IDs and their schema hashes:
#   code-review-dispatch   d2c2c0f6c66b4ae5   (reviewer-findings.json schema)
#   review-protocol        3053fa9a43e12b79   (REVIEW-SCHEMA.md base structure)
#   plan-review            9dba6875b85b7bc3   (structured text verdict format)
#
# For review-protocol, pass --caller <id> to also validate per-caller perspective
# names, dimension names, and reviewer-specific finding fields.
#
# Caller IDs and their schema hashes (--caller for review-protocol):
#   roadmap                f4e5f5a355e4c145
#   brainstorm             f4e5f5a355e4c145
#   ui-designer            2c3ece1bc2820109
#   implementation-plan    0271e511c0161eec
#   retro                  8a1a3dd74e54f101
#   design-review          1a50fe899037ef49
#   dev-onboarding         9ec70789c77bcca2
#   architect-foundation   9ec70789c77bcca2
#   preplanning            dba581aa06265af0
#
# Schema hashes are SHA-256[:16] of the canonical JSON schema definition.
# They change only when schema RULES change (field names, allowed values,
# required structure) — not when review content changes.
#
# To recompute a prompt-level hash:
#   python3 -c "
#   import hashlib, json
#   s = { ... schema dict ... }
#   print(hashlib.sha256(json.dumps(s, sort_keys=True, separators=(',',':')).encode()).hexdigest()[:16])
#   "
#
# Exit codes:
#   0 = output is valid
#   1 = validation failed (details printed to stderr)
#   2 = usage error (bad prompt-id, missing file, etc.)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_SCRIPT_DIR/.." && pwd)}"

# --- Load extracted schema validators (validate_review_protocol_base, validate_plan_review) ---
# shellcheck source=${_PLUGIN_ROOT}/hooks/lib/validate-review-schemas.sh
if [[ -f "${_PLUGIN_ROOT}/hooks/lib/validate-review-schemas.sh" ]]; then
    source "${_PLUGIN_ROOT}/hooks/lib/validate-review-schemas.sh"
fi


# --- Prompt-level schema hashes ---
HASH_CODE_REVIEW_DISPATCH="d2c2c0f6c66b4ae5"
HASH_REVIEW_PROTOCOL="3053fa9a43e12b79"
HASH_PLAN_REVIEW="9dba6875b85b7bc3"

# --- Per-caller schema hashes (for --caller with review-protocol) ---
HASH_CALLER_ROADMAP="f4e5f5a355e4c145"
HASH_CALLER_BRAINSTORM="f4e5f5a355e4c145"
HASH_CALLER_UI_DESIGNER="2c3ece1bc2820109"
HASH_CALLER_IMPLEMENTATION_PLAN="0271e511c0161eec"
HASH_CALLER_RETRO="8a1a3dd74e54f101"
HASH_CALLER_DESIGN_REVIEW="1a50fe899037ef49"
HASH_CALLER_DEV_ONBOARDING="9ec70789c77bcca2"
# REVIEW-DEFENSE: architect-foundation intentionally shares the same hash as dev-onboarding
# (9ec70789c77bcca2). This is a SCHEMA hash (SHA-256[:16] of the canonical JSON schema
# definition), not a skill identity hash. Both skills use the same review output schema
# — identical field names, required structure, and allowed severity values. The hash
# collision is expected and correct; it does not indicate a missing schema distinction.
# If the architect-foundation schema ever diverges (new fields, changed constraints), a new
# hash will be computed and this variable will be updated independently.
HASH_CALLER_ARCHITECT_FOUNDATION="9ec70789c77bcca2"
HASH_CALLER_PREPLANNING="dba581aa06265af0"

usage() {
    cat >&2 <<EOF
Usage: $SCRIPT_NAME <prompt-id> <output-file> [--caller <caller-id>]
       $SCRIPT_NAME --list
       $SCRIPT_NAME --list-callers

Validates review agent output against the expected schema.

Prompt IDs:
  code-review-dispatch   Schema hash: ${HASH_CODE_REVIEW_DISPATCH}
                         Validates: reviewer-findings.json (3 required top-level
                         keys + optional review_tier, 5 score dimensions, findings with severity/category)

  review-protocol        Schema hash: ${HASH_REVIEW_PROTOCOL}
                         Validates: REVIEW-SCHEMA.md JSON (subject, reviews[],
                         conflicts[] with required fields and enum values).
                         Add --caller <id> to also check per-caller perspectives,
                         dimensions, and reviewer-specific finding fields.

  plan-review            Schema hash: ${HASH_PLAN_REVIEW}
                         Validates: structured text output (VERDICT, SCORES,
                         FINDINGS markers; valid dimension names and severities)

Caller IDs (use with: review-protocol <file> --caller <id>):
  roadmap                ${HASH_CALLER_ROADMAP}
  brainstorm             ${HASH_CALLER_BRAINSTORM}
  ui-designer            ${HASH_CALLER_UI_DESIGNER}
  implementation-plan    ${HASH_CALLER_IMPLEMENTATION_PLAN}
  retro                  ${HASH_CALLER_RETRO}
  design-review          ${HASH_CALLER_DESIGN_REVIEW}
  dev-onboarding         ${HASH_CALLER_DEV_ONBOARDING}
  architect-foundation   ${HASH_CALLER_ARCHITECT_FOUNDATION}
  preplanning            ${HASH_CALLER_PREPLANNING}
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 2
fi

if [[ "$1" == "--list" ]]; then
    echo "code-review-dispatch   ${HASH_CODE_REVIEW_DISPATCH}"
    echo "review-protocol        ${HASH_REVIEW_PROTOCOL}"
    echo "plan-review            ${HASH_PLAN_REVIEW}"
    exit 0
fi

if [[ "$1" == "--list-callers" ]]; then
    echo "roadmap                ${HASH_CALLER_ROADMAP}"
    echo "brainstorm             ${HASH_CALLER_BRAINSTORM}"
    echo "ui-designer            ${HASH_CALLER_UI_DESIGNER}"
    echo "implementation-plan    ${HASH_CALLER_IMPLEMENTATION_PLAN}"
    echo "retro                  ${HASH_CALLER_RETRO}"
    echo "design-review          ${HASH_CALLER_DESIGN_REVIEW}"
    echo "dev-onboarding         ${HASH_CALLER_DEV_ONBOARDING}"
    echo "architect-foundation   ${HASH_CALLER_ARCHITECT_FOUNDATION}"
    echo "preplanning            ${HASH_CALLER_PREPLANNING}"
    exit 0
fi

if [[ $# -lt 2 ]]; then
    usage
    exit 2
fi

PROMPT_ID="$1"
OUTPUT_FILE="$2"
CALLER_ID=""

# Parse optional --caller flag
shift 2
while [[ $# -gt 0 ]]; do
    case "$1" in
        --caller)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --caller requires an argument" >&2
                exit 2
            fi
            CALLER_ID="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

# Validate known prompt IDs
case "$PROMPT_ID" in
    code-review-dispatch|review-protocol|plan-review) ;;
    *)
        echo "ERROR: unknown prompt-id: '$PROMPT_ID'" >&2
        echo "Run '$SCRIPT_NAME --list' to see valid prompt IDs." >&2
        exit 2
        ;;
esac

# Validate --caller is only used with review-protocol
if [[ -n "$CALLER_ID" && "$PROMPT_ID" != "review-protocol" ]]; then
    echo "ERROR: --caller is only valid with prompt-id 'review-protocol'" >&2
    exit 2
fi

# Validate known caller IDs
if [[ -n "$CALLER_ID" ]]; then
    case "$CALLER_ID" in
        roadmap|brainstorm|ui-designer|implementation-plan|retro|design-review|dev-onboarding|architect-foundation|preplanning) ;;
        *)
            echo "ERROR: unknown caller-id: '$CALLER_ID'" >&2
            echo "Run '$SCRIPT_NAME --list-callers' to see valid caller IDs." >&2
            exit 2
            ;;
    esac
fi

# Check output file exists and is non-empty
if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo "ERROR: output file not found: $OUTPUT_FILE" >&2
    exit 1
fi
if [[ ! -s "$OUTPUT_FILE" ]]; then
    echo "ERROR: output file is empty: $OUTPUT_FILE" >&2
    exit 1
fi

# --- Validator: code-review-dispatch ---
validate_code_review_dispatch() {
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

# Must have required top-level keys; review_tier, selected_tier, and escalate_review are optional
required_top = {"scores", "findings", "summary"}
optional_top = {"review_tier", "selected_tier", "escalate_review"}
allowed_top = required_top | optional_top
actual_top = set(data.keys())
extra = actual_top - allowed_top
missing = required_top - actual_top
if extra:
    errors.append(f"unexpected top-level keys: {sorted(extra)} (only {sorted(allowed_top)} allowed)")
if missing:
    errors.append(f"missing top-level keys: {sorted(missing)}")

# Validate review_tier if present
if "review_tier" in data:
    if data["review_tier"] not in ("light", "standard", "deep"):
        errors.append(f"'review_tier' must be one of: light, standard, deep (got '{data['review_tier']}')")

# Validate selected_tier if present
if "selected_tier" in data:
    if data["selected_tier"] not in ("light", "standard", "deep"):
        errors.append(f"'selected_tier' must be one of: light, standard, deep (got '{data['selected_tier']}')")

# Validate scores
scores = data.get("scores")
if not isinstance(scores, dict):
    errors.append("'scores' must be an object")
else:
    required_dims = ["hygiene", "design", "maintainability", "correctness", "verification"]
    for dim in required_dims:
        if dim not in scores:
            errors.append(f"missing score dimension: '{dim}'")
        else:
            val = scores[dim]
            if val != "N/A":
                if not isinstance(val, (int, float)) or not (1 <= val <= 5):
                    errors.append(f"score '{dim}' must be 1-5 or 'N/A', got: {val!r}")
    extra_dims = set(scores.keys()) - set(required_dims)
    if extra_dims:
        errors.append(f"unexpected score dimensions: {sorted(extra_dims)}")

# Validate findings
findings = data.get("findings")
if findings is None:
    errors.append("missing 'findings' array")
elif not isinstance(findings, list):
    errors.append("'findings' must be an array")
else:
    valid_severities = {"critical", "important", "minor", "fragile"}
    valid_categories = {"hygiene", "design", "maintainability", "correctness", "verification"}
    for i, finding in enumerate(findings):
        prefix = f"findings[{i}]"
        if not isinstance(finding, dict):
            errors.append(f"{prefix}: must be an object")
            continue
        for field in ["severity", "category", "description", "file"]:
            if field not in finding:
                errors.append(f"{prefix}: missing required field '{field}'")
        sev = finding.get("severity")
        if sev is not None and sev not in valid_severities:
            errors.append(f"{prefix}.severity: must be one of {sorted(valid_severities)}, got: {sev!r}")
        cat = finding.get("category")
        if cat is not None and cat not in valid_categories:
            errors.append(f"{prefix}.category: must be one of {sorted(valid_categories)}, got: {cat!r}")
        if sev == "critical" and cat in (scores or {}):
            score = (scores or {}).get(cat)
            if isinstance(score, (int, float)) and score > 2:
                errors.append(f"{prefix}: severity='critical' but scores[{cat}]={score} (critical requires score 1-2)")

# Score-severity consistency: scores are driven by the worst finding severity.
# No findings → 5, minor only → 4, important → 3, critical → 1-2.
if isinstance(findings, list) and isinstance(scores, dict):
    from collections import defaultdict
    dim_severities: dict = defaultdict(set)
    for finding in findings:
        cat = finding.get("category")
        sev = finding.get("severity")
        if cat and sev:
            dim_severities[cat].add(sev)
    for dim, score in scores.items():
        if not isinstance(score, (int, float)):
            continue
        sevs = dim_severities.get(dim, set())
        if not sevs and score != 5:
            errors.append(f"score '{dim}'={score}: no findings requires score 5")
        elif sevs == {"minor"} and score != 4:
            errors.append(f"score '{dim}'={score}: minor-only findings requires score 4")
        elif ("important" in sevs or "fragile" in sevs) and "critical" not in sevs and score != 3:
            errors.append(f"score '{dim}'={score}: important (no critical) findings requires score 3")

# Validate summary
summary = data.get("summary")
if summary is None:
    errors.append("missing 'summary' field")
elif not isinstance(summary, str) or len(summary.strip()) < 10:
    errors.append("'summary' must be a non-empty string (min 10 chars)")

# Validate escalate_review if present
if "escalate_review" in data:
    escalate = data["escalate_review"]
    if not isinstance(escalate, list):
        errors.append("'escalate_review' must be an array")
    else:
        findings_count = len(findings) if isinstance(findings, list) else 0
        for i, item in enumerate(escalate):
            prefix = f"escalate_review[{i}]"
            if not isinstance(item, dict):
                errors.append(f"{prefix}: must be an object")
                continue
            if "finding_index" not in item:
                errors.append(f"{prefix}: missing required field 'finding_index'")
            else:
                idx = item["finding_index"]
                if not isinstance(idx, int):
                    errors.append(f"{prefix}.finding_index: must be an integer, got: {idx!r}")
                elif not (0 <= idx < findings_count):
                    errors.append(f"{prefix}.finding_index: {idx} is out of bounds (findings has {findings_count} elements)")
            if "reason" not in item:
                errors.append(f"{prefix}: missing required field 'reason'")
            else:
                reason = item["reason"]
                if not isinstance(reason, str) or not reason.strip():
                    errors.append(f"{prefix}.reason: must be a non-empty string")

if errors:
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

print("OK")
PYEOF
}

# --- Validator: review-protocol with per-caller schema ---
validate_review_protocol_caller() {
    local file="$1"
    local caller_id="$2"
    python3 - "$file" "$caller_id" <<'PYEOF'
import sys, json

output_file = sys.argv[1]
caller_id = sys.argv[2]

# Per-caller schema definitions.
# Each perspective entry:
#   perspective           : exact label string expected in reviews[].perspective
#   required_dimensions   : dimension keys that must be present in dimensions map
#   required_finding_fields: list of field specs for domain-specific fields:
#     field      : field name
#     type       : 'string' | 'array' | 'enum'
#     when       : 'all' (every finding) | list of dimension names (conditional)
#     optional   : if True, field is recommended but not required (warn only)
#     enum_values: valid values when type='enum'
CALLER_SCHEMAS = {
    "roadmap": {
        "schema_hash": "f4e5f5a355e4c145",
        "perspectives": [
            {
                "perspective": "Agent Clarity",
                "required_dimensions": ["self_contained", "success_measurable"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Scope",
                "required_dimensions": ["right_sized", "no_overlap", "dependency_aware"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Value",
                "required_dimensions": ["user_impact", "validation_signal"],
                "required_finding_fields": [],
            },
        ],
    },
    "brainstorm": {
        "schema_hash": "f4e5f5a355e4c145",
        "perspectives": [
            {
                "perspective": "Agent Clarity",
                "required_dimensions": ["self_contained", "success_measurable"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Scope",
                "required_dimensions": ["right_sized", "no_overlap", "dependency_aware"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Value",
                "required_dimensions": ["user_impact", "validation_signal"],
                "required_finding_fields": [],
            },
        ],
    },
    "ui-designer": {
        "schema_hash": "2c3ece1bc2820109",
        "perspectives": [
            {
                "perspective": "Product Management",
                "required_dimensions": ["story_alignment", "user_value", "scope_appropriateness", "consistency", "epic_coherence", "anti_pattern_compliance"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Design Systems",
                "required_dimensions": ["component_reuse", "visual_hierarchy", "design_system_compliance", "new_component_justification", "cross_story_consistency"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Accessibility",
                "required_dimensions": ["wcag_compliance", "keyboard_navigation", "screen_reader_support", "inclusive_design", "hcd_heuristics"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Frontend Engineering",
                "required_dimensions": ["implementation_feasibility", "performance", "state_complexity", "specification_clarity"],
                "required_finding_fields": [],
            },
        ],
    },
    "implementation-plan": {
        "schema_hash": "0271e511c0161eec",
        "perspectives": [
            {
                "perspective": "Task Design",
                "required_dimensions": ["atomicity", "acceptance_criteria"],
                "required_finding_fields": [],
            },
            {
                "perspective": "TDD",
                "required_dimensions": ["tdd_discipline", "test_isolation", "red_green_sequence", "test_boundary_coverage", "bidirectional_test_coverage"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Safety",
                "required_dimensions": ["incremental_deploy", "backward_compat"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Dependencies",
                "required_dimensions": ["dag_validity", "no_coupling"],
                "required_finding_fields": [],
            },
            {
                "perspective": "Completeness",
                "required_dimensions": ["criteria_coverage", "e2e_coverage"],
                "required_finding_fields": [],
            },
        ],
    },
    "retro": {
        "schema_hash": "8a1a3dd74e54f101",
        "perspectives": [
            {
                "perspective": "Test Quality",
                "required_dimensions": ["assertion_coverage", "mock_discipline", "naming_clarity", "determinism", "risk_coverage"],
                "required_finding_fields": [
                    {"field": "offending_files", "type": "array", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Documentation",
                "required_dimensions": ["freshness", "completeness", "navigability"],
                "required_finding_fields": [
                    {"field": "stale_location", "type": "string", "when": ["freshness"], "optional": False},
                ],
            },
            {
                "perspective": "Code Quality",
                "required_dimensions": ["file_size", "complexity", "duplication", "dead_code"],
                "required_finding_fields": [
                    {"field": "violating_location", "type": "string", "when": "all", "optional": True},
                ],
            },
            {
                "perspective": "Naming Conventions",
                "required_dimensions": ["consistency"],
                "required_finding_fields": [
                    {"field": "convention_violated", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Architecture",
                "required_dimensions": ["layering", "separation", "error_resilience", "observability"],
                "required_finding_fields": [
                    {"field": "invariant_violated", "type": "string", "when": "all", "optional": False},
                ],
            },
        ],
    },
    "design-review": {
        "schema_hash": "1a50fe899037ef49",
        "perspectives": [
            {
                "perspective": "North Star Alignment",
                "required_dimensions": ["user_archetype_fit", "anti_pattern_free", "design_system_compliance", "scope_fit", "future_readiness"],
                "required_finding_fields": [
                    {"field": "design_notes_ref", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Usability (HCD)",
                "required_dimensions": ["user_feedback", "interaction_quality", "accessibility", "content_clarity"],
                "required_finding_fields": [
                    {"field": "heuristic_ref", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Visual Design",
                "required_dimensions": ["visual_hierarchy", "intentional_layout", "fidelity_balance"],
                "required_finding_fields": [
                    {"field": "design_principle", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Component Reuse",
                "required_dimensions": ["library_first", "portability", "trope_vs_useful", "removal_impact"],
                "required_finding_fields": [
                    {"field": "component_ref", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Form & Input Design",
                "required_dimensions": ["minimal_input", "validation_guidance", "review_before_submit"],
                "required_finding_fields": [
                    {"field": "form_element", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Tech Compliance",
                "required_dimensions": ["stack_correct", "architecture_consistent"],
                "required_finding_fields": [
                    {"field": "design_notes_ref", "type": "string", "when": "all", "optional": False},
                ],
            },
        ],
    },
    "dev-onboarding": {
        "schema_hash": "9ec70789c77bcca2",
        "perspectives": [
            {
                "perspective": "Failure Modes",
                "required_dimensions": ["resource_boundaries", "failure_isolation", "recovery_by_design", "degradation_paths"],
                "required_finding_fields": [
                    {"field": "failure_scenario", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Hardening",
                "required_dimensions": ["secure_by_default", "observable_by_default"],
                "required_finding_fields": [
                    {
                        "field": "risk_category",
                        "type": "enum",
                        "enum_values": ["auth_default", "secrets_pattern", "input_boundary", "access_control", "logging_framework", "health_endpoint", "graceful_lifecycle", "error_reporting", "other"],
                        "when": "all",
                        "optional": False,
                    },
                ],
            },
            {
                "perspective": "Scalability",
                "required_dimensions": ["stateless_by_default", "data_patterns"],
                "required_finding_fields": [
                    {"field": "growth_constraint", "type": "string", "when": "all", "optional": False},
                ],
            },
        ],
    },
    "architect-foundation": {
        "schema_hash": "9ec70789c77bcca2",
        "perspectives": [
            {
                "perspective": "Failure Modes",
                "required_dimensions": ["resource_boundaries", "failure_isolation", "recovery_by_design", "degradation_paths"],
                "required_finding_fields": [
                    {"field": "failure_scenario", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Hardening",
                "required_dimensions": ["secure_by_default", "observable_by_default"],
                "required_finding_fields": [
                    {
                        "field": "risk_category",
                        "type": "enum",
                        "enum_values": ["auth_default", "secrets_pattern", "input_boundary", "access_control", "logging_framework", "health_endpoint", "graceful_lifecycle", "error_reporting", "other"],
                        "when": "all",
                        "optional": False,
                    },
                ],
            },
            {
                "perspective": "Scalability",
                "required_dimensions": ["stateless_by_default", "data_patterns"],
                "required_finding_fields": [
                    {"field": "growth_constraint", "type": "string", "when": "all", "optional": False},
                ],
            },
        ],
    },
    "preplanning": {
        "schema_hash": "dba581aa06265af0",
        "perspectives": [
            {
                "perspective": "Security",
                "required_dimensions": ["access_classification", "data_protection"],
                "required_finding_fields": [
                    {"field": "owasp_category", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Performance",
                "required_dimensions": ["latency", "resource_efficiency", "scalability"],
                "required_finding_fields": [
                    {"field": "impact_estimate", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Accessibility",
                "required_dimensions": ["wcag_compliance", "inclusive_ux"],
                "required_finding_fields": [
                    {"field": "wcag_criterion", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Testing",
                "required_dimensions": ["user_journey_coverage", "boundary_scenarios", "verifiable_outcomes"],
                "required_finding_fields": [
                    {"field": "affected_path", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Reliability",
                "required_dimensions": ["error_handling", "failover"],
                "required_finding_fields": [
                    {"field": "blast_radius", "type": "string", "when": "all", "optional": False},
                ],
            },
            {
                "perspective": "Maintainability",
                "required_dimensions": ["coupling_risk", "changeability", "documentation"],
                "required_finding_fields": [
                    {"field": "affected_docs", "type": "array", "when": "all", "optional": False},
                ],
            },
        ],
    },
}

if caller_id not in CALLER_SCHEMAS:
    print(f"ERROR: unknown caller-id: '{caller_id}'")
    sys.exit(1)

schema = CALLER_SCHEMAS[caller_id]
caller_hash = schema["schema_hash"]
expected_perspectives = schema["perspectives"]

with open(output_file) as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON: {e}")
        sys.exit(1)

errors = []
warnings = []

reviews = data.get("reviews", [])
if not isinstance(reviews, list):
    print("  - 'reviews' must be an array (cannot validate caller schema)")
    sys.exit(1)

# Build index of actual reviews by perspective
actual_by_perspective = {}
for review in reviews:
    if isinstance(review, dict):
        p = review.get("perspective", "")
        actual_by_perspective[p] = review

# Check each expected perspective
for pdef in expected_perspectives:
    pname = pdef["perspective"]
    required_dims = pdef["required_dimensions"]
    required_fields = pdef["required_finding_fields"]

    if pname not in actual_by_perspective:
        errors.append(f"missing perspective: '{pname}'")
        continue

    review = actual_by_perspective[pname]
    status = review.get("status", "reviewed")
    prefix = f"reviews[perspective='{pname}']"

    if status == "not_applicable":
        # Skip dimension and finding checks for not_applicable perspectives
        continue

    # Check required dimensions
    dims = review.get("dimensions", {}) or {}
    if isinstance(dims, dict):
        for dim in required_dims:
            if dim not in dims:
                errors.append(f"{prefix}.dimensions: missing required dimension '{dim}'")

    # Check required finding fields
    findings = review.get("findings", []) or []
    if isinstance(findings, list) and required_fields:
        for j, finding in enumerate(findings):
            if not isinstance(finding, dict):
                continue
            fp = f"{prefix}.findings[{j}]"
            finding_dim = finding.get("dimension", "")

            for field_spec in required_fields:
                field_name = field_spec["field"]
                field_type = field_spec["type"]
                when = field_spec["when"]
                is_optional = field_spec.get("optional", False)
                enum_values = field_spec.get("enum_values")

                # Determine if this field is required for this finding
                if when == "all":
                    field_required = True
                elif isinstance(when, list):
                    field_required = finding_dim in when
                else:
                    field_required = False

                if not field_required:
                    continue

                if field_name not in finding:
                    if is_optional:
                        warnings.append(f"{fp}: recommended field '{field_name}' is missing")
                    else:
                        errors.append(f"{fp}: missing required field '{field_name}' (required for {pname} findings)")
                    continue

                # Validate field type
                val = finding[field_name]
                if field_type == "string":
                    if not isinstance(val, str) or not val.strip():
                        errors.append(f"{fp}.{field_name}: must be a non-empty string, got: {type(val).__name__}")
                elif field_type == "array":
                    if not isinstance(val, list):
                        errors.append(f"{fp}.{field_name}: must be an array, got: {type(val).__name__}")
                    elif len(val) == 0:
                        errors.append(f"{fp}.{field_name}: array must not be empty")
                elif field_type == "enum":
                    if val not in enum_values:
                        errors.append(f"{fp}.{field_name}: must be one of {enum_values}, got: {val!r}")

# Check for unexpected perspectives (informational warning, not error)
expected_names = {p["perspective"] for p in expected_perspectives}
for pname in actual_by_perspective:
    if pname not in expected_names:
        warnings.append(f"unexpected perspective: '{pname}' (not in {caller_id} schema)")

if warnings:
    for w in warnings:
        print(f"  ! {w}")

if errors:
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

print(f"OK (caller-schema-hash={caller_hash})")
PYEOF
}

# --- Dispatch ---

FAILED=0
CALLER_FAILED=0

case "$PROMPT_ID" in
    code-review-dispatch)
        SCHEMA_HASH="$HASH_CODE_REVIEW_DISPATCH"
        RESULT=$(validate_code_review_dispatch "$OUTPUT_FILE" 2>&1) || FAILED=1
        ;;
    review-protocol)
        SCHEMA_HASH="$HASH_REVIEW_PROTOCOL"
        RESULT=$(validate_review_protocol_base "$OUTPUT_FILE" 2>&1) || FAILED=1
        # Run per-caller validation if requested and base validation passed
        if [[ "$FAILED" -eq 0 && -n "$CALLER_ID" ]]; then
            case "$CALLER_ID" in
                roadmap)              CALLER_HASH="$HASH_CALLER_ROADMAP" ;;
                brainstorm)           CALLER_HASH="$HASH_CALLER_BRAINSTORM" ;;
                ui-designer)          CALLER_HASH="$HASH_CALLER_UI_DESIGNER" ;;
                implementation-plan)  CALLER_HASH="$HASH_CALLER_IMPLEMENTATION_PLAN" ;;
                retro)                CALLER_HASH="$HASH_CALLER_RETRO" ;;
                design-review)        CALLER_HASH="$HASH_CALLER_DESIGN_REVIEW" ;;
                dev-onboarding)       CALLER_HASH="$HASH_CALLER_DEV_ONBOARDING" ;;
                architect-foundation) CALLER_HASH="$HASH_CALLER_ARCHITECT_FOUNDATION" ;;
                preplanning)          CALLER_HASH="$HASH_CALLER_PREPLANNING" ;;
            esac
            CALLER_RESULT=$(validate_review_protocol_caller "$OUTPUT_FILE" "$CALLER_ID" 2>&1) || CALLER_FAILED=1
        fi
        ;;
    plan-review)
        SCHEMA_HASH="$HASH_PLAN_REVIEW"
        RESULT=$(validate_plan_review "$OUTPUT_FILE" 2>&1) || FAILED=1
        ;;
esac

if [[ "$FAILED" -ne 0 ]]; then
    echo "SCHEMA_VALID: no (prompt-id=${PROMPT_ID}, schema-hash=${SCHEMA_HASH})" >&2
    echo "Validation errors:" >&2
    echo "$RESULT" >&2
    exit 1
fi

if [[ "$CALLER_FAILED" -ne 0 ]]; then
    echo "SCHEMA_VALID: no (prompt-id=${PROMPT_ID}, caller=${CALLER_ID}, schema-hash=${SCHEMA_HASH}, caller-schema-hash=${CALLER_HASH})" >&2
    echo "Per-caller validation errors:" >&2
    echo "$CALLER_RESULT" >&2
    exit 1
fi

# Print any warnings from caller validation (exit 0)
if [[ -n "$CALLER_ID" && -n "${CALLER_RESULT:-}" ]]; then
    # Warnings start with "  !" — print them but still pass
    if echo "$CALLER_RESULT" | grep -q "^  !"; then
        echo "$CALLER_RESULT" | grep "^  !" >&2
    fi
    echo "SCHEMA_VALID: yes (prompt-id=${PROMPT_ID}, caller=${CALLER_ID}, schema-hash=${SCHEMA_HASH}, caller-schema-hash=${CALLER_HASH})"
elif [[ -n "$CALLER_ID" ]]; then
    echo "SCHEMA_VALID: yes (prompt-id=${PROMPT_ID}, caller=${CALLER_ID}, schema-hash=${SCHEMA_HASH}, caller-schema-hash=${CALLER_HASH})"
else
    echo "SCHEMA_VALID: yes (prompt-id=${PROMPT_ID}, schema-hash=${SCHEMA_HASH})"
fi
exit 0
