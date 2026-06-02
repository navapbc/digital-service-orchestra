#!/usr/bin/env bash
# tests/scripts/test-ruleset-provisioner-roundtrip.sh — W1 (single source of truth)
#
# Round-trip drift test: proves the provisioner (provision-ruleset.sh) emits a
# ruleset payload whose SHAPE matches (a) the canonical artifact for the main
# ruleset (.github/required-checks.txt) and (b) the LIVE GitHub ruleset config
# for the sub-PR ruleset. This closes the single-source-of-truth chain:
#
#     required-checks.txt ──▶ provisioner dry-run ──▶ live ruleset
#
# so a divergence at any link fails CI instead of silently shipping wrong config
# (the CS-2 drift class: provisioner emitted `required_workflows` while live ran
# `required_status_checks`).
#
# Two test surfaces:
#   OFFLINE (always runs): parse the provisioner --dry-run payload and assert the
#     sub-PR rule is `required_status_checks{review-sub-pr, do_not_enforce_on_create}`
#     plus a `copilot_code_review` rule, with NO dangling `workflows` /
#     `review-sub-pr.yml` binding; and the main rule's contexts equal the
#     non-comment lines of required-checks.txt.
#   LIVE (token-gated, skips without GH auth): compare the provisioner dry-run
#     sub-PR + main rule shapes against the live ruleset config.
#
# Mirrors the precondition/skip conventions of test-ruleset-design-invariants.sh.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GH_REPO="${GH_REPO:-navapbc/digital-service-orchestra}"
PROVISIONER="$REPO_ROOT/plugins/dso/scripts/onboarding/provision-ruleset.sh"
CHECKS_FILE="$REPO_ROOT/.github/required-checks.txt"

PASS=0
FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_TRACKED_TMP_FILES=()
_cleanup_tmps() {
    local _f
    for _f in "${_TRACKED_TMP_FILES[@]:-}"; do
        [[ -n "$_f" ]] && rm -f "$_f" 2>/dev/null || true
    done
}
trap _cleanup_tmps EXIT

if ! command -v python3 >/dev/null 2>&1; then
    echo "PRECONDITION_NOT_MET: python3 not in PATH" >&2
    exit 78
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "PRECONDITION_NOT_MET: jq not in PATH" >&2
    exit 78
fi

# ── Run the provisioner in dry-run and capture both payloads ─────────────────
# Deterministic + offline: pin the default branch and bypass user so the dry-run
# never needs the network. --non-interactive + DSO_DRY_RUN=1 exits before any POST.
_dryrun_out=$(mktemp "${TMPDIR:-/tmp}/dso-prov-dryrun.XXXXXX"); _TRACKED_TMP_FILES+=("$_dryrun_out")
if ! DSO_DRY_RUN=1 DSO_DEFAULT_BRANCH=main DSO_RULESET_BYPASS_USER_ID=207596960 \
        bash "$PROVISIONER" --repo "$GH_REPO" --non-interactive >"$_dryrun_out" 2>&1; then
    echo "PRECONDITION_NOT_MET: provisioner --dry-run exited non-zero" >&2
    cat "$_dryrun_out" >&2
    exit 78
fi

# Extract the MAIN and SUB-PR JSON payloads from the dry-run output. Each payload
# is a pretty-printed JSON object that follows a "--- <name> payload ... ---"
# marker line and ends at the next "---" marker line.
_extract_payload() {
    local marker_substr="$1"
    local src="${2:-$_dryrun_out}"
    python3 - "$src" "$marker_substr" <<'PY'
import sys, json
path, marker = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()
buf, capturing = [], False
for ln in lines:
    if ln.startswith("---"):
        if capturing:
            break
        if marker in ln:
            capturing = True
        continue
    if capturing:
        buf.append(ln)
blob = "\n".join(buf).strip()
# Trim to the outermost {...} so surrounding blank lines don't break json.
start, end = blob.find("{"), blob.rfind("}")
if start == -1 or end == -1:
    print("PARSE_ERROR: no JSON object found", file=sys.stderr)
    sys.exit(2)
try:
    json.loads(blob[start:end+1])
except Exception as exc:
    print(f"PARSE_ERROR: {exc}", file=sys.stderr)
    sys.exit(2)
print(blob[start:end+1])
PY
}

MAIN_PAYLOAD="$(_extract_payload "Main branch ruleset")"
if [[ -z "$MAIN_PAYLOAD" ]]; then
    echo "PRECONDITION_NOT_MET: could not extract main payload from dry-run output" >&2
    cat "$_dryrun_out" >&2
    exit 78
fi
SUB_PR_PAYLOAD="$(_extract_payload "Session-branch ruleset")"
if [[ -z "$SUB_PR_PAYLOAD" ]]; then
    echo "PRECONDITION_NOT_MET: could not extract sub-PR payload from dry-run output" >&2
    cat "$_dryrun_out" >&2
    exit 78
fi

# ── Second dry-run with the merge_queue gate ON (MQ-2, ADR-0019) ─────────────
# The default dry-run above reflects the live/default gate state (off pre-cutover).
# This run forces the gate on so R10–R12 can assert the merge_queue rule shape the
# provisioner would emit at the MQ-6 cutover.
_dryrun_mq_out=$(mktemp "${TMPDIR:-/tmp}/dso-prov-dryrun-mq.XXXXXX"); _TRACKED_TMP_FILES+=("$_dryrun_mq_out")
if ! DSO_DRY_RUN=1 DSO_DEFAULT_BRANCH=main DSO_RULESET_BYPASS_USER_ID=207596960 \
        bash "$PROVISIONER" --repo "$GH_REPO" --non-interactive --enable-merge-queue >"$_dryrun_mq_out" 2>&1; then
    echo "PRECONDITION_NOT_MET: provisioner --dry-run --enable-merge-queue exited non-zero" >&2
    cat "$_dryrun_mq_out" >&2
    exit 78
fi
MAIN_PAYLOAD_MQ_ON="$(_extract_payload "Main branch ruleset" "$_dryrun_mq_out")"
if [[ -z "$MAIN_PAYLOAD_MQ_ON" ]]; then
    echo "PRECONDITION_NOT_MET: could not extract gate-on main payload" >&2
    exit 78
fi

# ── OFFLINE assertions ───────────────────────────────────────────────────────

# R1: sub-PR rule is required_status_checks{review-sub-pr}
if echo "$SUB_PR_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('rules',[]):
    if r.get('type')=='required_status_checks':
        ctx=[c.get('context') for c in r.get('parameters',{}).get('required_status_checks',[])]
        sys.exit(0 if 'review-sub-pr' in ctx else 1)
sys.exit(1)
"; then
    _pass "R1_sub_pr_rule_is_required_status_checks_review_sub_pr"
else
    _fail "R1_sub_pr_rule_is_required_status_checks_review_sub_pr" \
        "provisioner sub-PR payload lacks a required_status_checks rule with context review-sub-pr"
fi

# R2: sub-PR required_status_checks rule has do_not_enforce_on_create=true
if echo "$SUB_PR_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('rules',[]):
    if r.get('type')=='required_status_checks':
        sys.exit(0 if r.get('parameters',{}).get('do_not_enforce_on_create') is True else 1)
sys.exit(1)
"; then
    _pass "R2_sub_pr_do_not_enforce_on_create_true"
else
    _fail "R2_sub_pr_do_not_enforce_on_create_true" \
        "provisioner sub-PR required_status_checks rule missing do_not_enforce_on_create=true"
fi

# R3: sub-PR payload has a copilot_code_review rule (matches live)
if echo "$SUB_PR_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if any(r.get('type')=='copilot_code_review' for r in d.get('rules',[])) else 1)
"; then
    _pass "R3_sub_pr_has_copilot_code_review_rule"
else
    _fail "R3_sub_pr_has_copilot_code_review_rule" \
        "provisioner sub-PR payload missing copilot_code_review rule"
fi

# R4: sub-PR payload has NO dangling `workflows` rule and no review-sub-pr.yml binding
if echo "$SUB_PR_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(1 if any(r.get('type')=='workflows' for r in d.get('rules',[])) else 0)
" && ! grep -q "review-sub-pr.yml" <<<"$SUB_PR_PAYLOAD"; then
    _pass "R4_sub_pr_no_dangling_workflows_binding"
else
    _fail "R4_sub_pr_no_dangling_workflows_binding" \
        "provisioner sub-PR payload still emits a workflows rule / review-sub-pr.yml binding"
fi

# R5: main rule contexts equal the non-comment lines of required-checks.txt
#     (file ──▶ provisioner round-trip — single source of truth for the main ruleset).
# LC_ALL=C sort to match Python's ASCII `sorted` collation on the payload side
# (a bash locale-aware `sort` orders mixed-case names differently and produces a
# spurious mismatch even when the sets are identical).
_file_checks="$(grep -v '^\s*#' "$CHECKS_FILE" | grep -v '^\s*$' | LC_ALL=C sort)"
_payload_checks="$(echo "$MAIN_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('rules',[]):
    if r.get('type')=='required_status_checks':
        for c in sorted(r.get('parameters',{}).get('required_status_checks',[]), key=lambda x:x.get('context','')):
            print(c.get('context'))
")"
if [[ "$_file_checks" == "$_payload_checks" ]]; then
    _pass "R5_main_contexts_match_required_checks_file"
else
    _fail "R5_main_contexts_match_required_checks_file" \
        "main payload contexts diverge from required-checks.txt"
fi

# R6: bypass actor shape is the named User (config-driven), not RepositoryRole
if echo "$SUB_PR_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ba=d.get('bypass_actors',[])
sys.exit(0 if ba==[{'actor_id':207596960,'actor_type':'User','bypass_mode':'pull_request'}] else 1)
"; then
    _pass "R6_bypass_actor_is_named_user"
else
    _fail "R6_bypass_actor_is_named_user" "sub-PR bypass_actors is not the named-User shape"
fi

# ── MQ-2: merge_queue gate coverage (offline) ────────────────────────────────

# R9: with the gate OFF (default), the main payload has NO merge_queue rule — so
#     running the provisioner today cannot prematurely enable the queue.
if echo "$MAIN_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(1 if any(r.get('type')=='merge_queue' for r in d.get('rules',[])) else 0)
"; then
    _pass "R9_gate_off_no_merge_queue_rule"
else
    _fail "R9_gate_off_no_merge_queue_rule" "default provisioner payload emits a merge_queue rule (gate should be off pre-cutover)"
fi

# R10: with the gate ON, the main payload includes a merge_queue rule.
if echo "$MAIN_PAYLOAD_MQ_ON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if any(r.get('type')=='merge_queue' for r in d.get('rules',[])) else 1)
"; then
    _pass "R10_gate_on_has_merge_queue_rule"
else
    _fail "R10_gate_on_has_merge_queue_rule" "gate-on provisioner payload lacks a merge_queue rule"
fi

# R11: gate-on merge_queue parameters match the ADR-0019 GO-scoped config exactly.
if echo "$MAIN_PAYLOAD_MQ_ON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
mq=next((r for r in d.get('rules',[]) if r.get('type')=='merge_queue'),None)
want={'merge_method':'MERGE','max_entries_to_build':1,'max_entries_to_merge':1,
      'min_entries_to_merge':1,'min_entries_to_merge_wait_minutes':5,
      'check_response_timeout_minutes':60,'grouping_strategy':'ALLGREEN'}
sys.exit(0 if mq and mq.get('parameters')==want else 1)
"; then
    _pass "R11_merge_queue_params_match_adr"
else
    _fail "R11_merge_queue_params_match_adr" "merge_queue parameters diverge from the ADR-0019 GO-scoped config"
fi

# R12: enabling the gate does not drop the base rules (additive only).
if echo "$MAIN_PAYLOAD_MQ_ON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
have={r.get('type') for r in d.get('rules',[])}
base={'non_fast_forward','deletion','pull_request','required_status_checks'}
sys.exit(0 if base.issubset(have) else 1)
"; then
    _pass "R12_gate_on_preserves_base_rules"
else
    _fail "R12_gate_on_preserves_base_rules" "gate-on payload dropped one or more base rules"
fi

# ── LIVE round-trip (token-gated; skip when no GH auth) ──────────────────────
_live_round_trip() {
    if [[ -z "${GH_TOKEN:-}" ]] && ! gh auth status >/dev/null 2>&1; then
        echo "SKIP: no GH_TOKEN and no local gh auth — live round-trip skipped (offline assertions still ran)"
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "SKIP: gh CLI not in PATH — live round-trip skipped"
        return 0
    fi

    local rulesets_json sub_id main_id sub_live main_live
    rulesets_json="$(gh api "repos/${GH_REPO}/rulesets" 2>/dev/null)" || {
        echo "SKIP: gh api rulesets failed — live round-trip skipped"; return 0; }
    sub_id="$(echo "$rulesets_json" | python3 -c "import json,sys;print(next((r['id'] for r in json.load(sys.stdin) if r.get('name')=='DSO Sub-PR Review Enforcement'),''))")"
    main_id="$(echo "$rulesets_json" | python3 -c "import json,sys;print(next((r['id'] for r in json.load(sys.stdin) if r.get('name')=='DSO CI Enforcement'),''))")"
    if [[ -z "$sub_id" || -z "$main_id" ]]; then
        echo "SKIP: live rulesets not found by name — live round-trip skipped"; return 0
    fi
    sub_live="$(gh api "repos/${GH_REPO}/rulesets/${sub_id}" 2>/dev/null)"
    main_live="$(gh api "repos/${GH_REPO}/rulesets/${main_id}" 2>/dev/null)"

    # R7: live sub-PR required_status_checks contexts == provisioner dry-run contexts
    local live_ctx prov_ctx
    live_ctx="$(echo "$sub_live" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps(sorted(c['context'] for r in d.get('rules',[]) if r.get('type')=='required_status_checks' for c in r.get('parameters',{}).get('required_status_checks',[]))))
")"
    prov_ctx="$(echo "$SUB_PR_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps(sorted(c['context'] for r in d.get('rules',[]) if r.get('type')=='required_status_checks' for c in r.get('parameters',{}).get('required_status_checks',[]))))
")"
    if [[ "$live_ctx" == "$prov_ctx" ]]; then
        _pass "R7_live_sub_pr_contexts_match_provisioner"
    else
        _fail "R7_live_sub_pr_contexts_match_provisioner" "live=$live_ctx provisioner=$prov_ctx"
    fi

    # R8: live main required_status_checks contexts == provisioner dry-run contexts
    local live_main prov_main
    live_main="$(echo "$main_live" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps(sorted(c['context'] for r in d.get('rules',[]) if r.get('type')=='required_status_checks' for c in r.get('parameters',{}).get('required_status_checks',[]))))
")"
    prov_main="$(echo "$MAIN_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps(sorted(c['context'] for r in d.get('rules',[]) if r.get('type')=='required_status_checks' for c in r.get('parameters',{}).get('required_status_checks',[]))))
")"
    if [[ "$live_main" == "$prov_main" ]]; then
        _pass "R8_live_main_contexts_match_provisioner"
    else
        _fail "R8_live_main_contexts_match_provisioner" "live=$live_main provisioner=$prov_main"
    fi

    # R13 (MQ-2 drift lock): the live main ruleset's merge_queue rule must match
    # what the DEFAULT (config-driven) provisioner emits. Pre-cutover both are
    # absent → match. At MQ-6 the operator flips dso.merge_queue.enabled=true AND
    # provisions live; if either side changes without the other, this fires.
    local live_mq prov_mq
    live_mq="$(echo "$main_live" | python3 -c "
import json,sys
d=json.load(sys.stdin)
mq=next((r.get('parameters') for r in d.get('rules',[]) if r.get('type')=='merge_queue'),None)
print(json.dumps(mq,sort_keys=True))
")"
    prov_mq="$(echo "$MAIN_PAYLOAD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
mq=next((r.get('parameters') for r in d.get('rules',[]) if r.get('type')=='merge_queue'),None)
print(json.dumps(mq,sort_keys=True))
")"
    if [[ "$live_mq" == "$prov_mq" ]]; then
        _pass "R13_live_merge_queue_matches_provisioner_default"
    else
        _fail "R13_live_merge_queue_matches_provisioner_default" "live merge_queue=$live_mq provisioner-default=$prov_mq (flip dso.merge_queue.enabled or re-provision)"
    fi
}
_live_round_trip

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
