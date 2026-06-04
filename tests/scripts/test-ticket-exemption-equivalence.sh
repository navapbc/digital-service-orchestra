#!/usr/bin/env bash
# tests/scripts/test-ticket-exemption-equivalence.sh — 0cd7 DD6
#
# THREE-CONSUMER SHARED-FIXTURE EQUIVALENCE TEST for the diff-scoped ticket-store
# exemption (rc_diff_is_tickets_only). The exemption is wired into THREE independent
# gates that each walk a SHA set and decide "carries reviewable content?":
#   1. review-coverage-invariant.sh   (fail-closed BLOCK posture)
#   2. verify-session-provenance.sh   (dispatch-decision posture)
#   3. fp-recovery-audit-sweep.sh     (non-blocking REPORTING posture)
# The v4 trailer-removal lesson + DD6: two independent per-path checks can both pass
# while the implementations diverge on a case neither fixture exercises ("the shortcut
# survived in one path after removal from another"). This drives ALL THREE production
# consumers over the SAME commit fixtures and asserts they agree on exempt/not-exempt.
#
# Each gate is configured so that, ABSENT the exemption, the fixture SHA would be
# flagged (no covering PR / no passing review). So an "exempt" verdict is ATTRIBUTABLE
# to the ticket-exemption path, not to some unrelated coverage success.
#
#   F_TICKETS  commit touches ONLY .tickets-tracker/*  -> EXEMPT      (all three)
#   F_CODE     commit touches ONLY a code path         -> NOT exempt  (all three)
#   F_MIXED    commit touches ticket + code            -> NOT exempt  (all three, no launder)

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY DSO_RULESET_BYPASS_USER_IDS DSO_RULESET_BYPASS_USER_ID
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

REPO_ROOT="$(git rev-parse --show-toplevel)"
RCI="$REPO_ROOT/plugins/dso/scripts/ci/review-coverage-invariant.sh"   # shim-exempt: invokes the script under test
VSP="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"      # shim-exempt: invokes the script under test
FPA="$REPO_ROOT/plugins/dso/scripts/ci/fp-recovery-audit-sweep.sh"     # shim-exempt: invokes the script under test

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-tktequiv.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
_BIN="$_W/bin"; mkdir -p "$_BIN"

# Shared mock gh. No covering PR (pulls -> []), no passing review (check-runs -> []).
# For the audit sweep, the closed-PR list returns ONE merged PR whose merge_commit_sha
# and head are the fixture SHA (so absent the exemption it is flagged as a bypass).
cat > "$_BIN/gh" <<'GH'
#!/usr/bin/env bash
arg="$*"
case "$arg" in
  *"repo view"*) printf '%s' "o/r"; exit 0 ;;
  *"pulls?state=closed"*)
    printf '%s' '[{"number":77,"state":"closed","merged_at":"2026-06-04T00:00:00Z","merge_commit_sha":"'"${MOCK_SHA:-}"'","head":{"sha":"'"${MOCK_SHA:-}"'"}}]'
    exit 0 ;;
  *"/commits/"*"/pulls"*) printf '%s' '[]'; exit 0 ;;        # no covering PR
  *"/check-runs"*)        printf '%s' '{"check_runs":[]}'; exit 0 ;;  # no passing review
  *"/pulls/"*)            printf '%s' ''; exit 0 ;;
  *) printf '%s' '[]'; exit 0 ;;
esac
GH
chmod +x "$_BIN/gh"

# Build a one-commit-over-base repo for a given fixture kind; echo "<base> <feature>".
_mk_repo() { # _mk_repo <kind> <repodir>
    local kind="$1" r="$2"
    mkdir -p "$r"
    ( cd "$r" || exit 1
      git init -q -b main; git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
      mkdir -p .tickets-tracker src
      echo base > README.md; git add README.md; git commit -q -m base
      local b; b="$(git rev-parse HEAD)"
      case "$kind" in
        tickets) echo a > .tickets-tracker/x.json; git add .tickets-tracker/x.json ;;
        code)    echo x > src/code.sh; git add src/code.sh ;;
        mixed)   echo a > .tickets-tracker/x.json; echo x > src/code.sh; git add .tickets-tracker/x.json src/code.sh ;;
      esac
      git commit -q -m "$kind"
      local f; f="$(git rev-parse HEAD)"
      # origin/main = base (coverage-invariant fail-closes if the base ref is unresolvable)
      git update-ref refs/remotes/origin/main "$b"
      echo "$b $f" )
}

# ── per-consumer verdicts: echo "exempt" | "not" ─────────────────────────────
_rci_verdict() { # <repo> <base> <feat>
    local r="$1" f="$3"
    ( cd "$r" && DSO_GH_BIN="$_BIN/gh" GH_REPO="o/r" GITHUB_BASE_REF=main \
        DSO_HEAD_SHA="$f" DSO_COVERAGE_INVARIANT_MODE=enforce GH_RETRY_MAX=1 \
        bash "$RCI" >/dev/null 2>&1 ) && echo exempt || echo not
}

_vsp_verdict() { # <repo> <base> <feat>
    local r="$1" b="$2" f="$3" ad; ad="$(mktemp -d "$_W/art.XXXXXX")"
    ( PATH="$_BIN:$PATH" DSO_REPO_PATH="$r" DSO_BASE_SHA="$b" DSO_SESSION_HEAD="$f" \
        DSO_ARTIFACT_DIR="$ad" DSO_GH_REPO="o/r" GH_RETRY_MAX=1 \
        bash "$VSP" >/dev/null 2>&1 )
    if [[ -f "$ad/unprovenanced-shas.txt" ]] && grep -q "$f" "$ad/unprovenanced-shas.txt"; then echo not; else echo exempt; fi
}

_fpa_verdict() { # <repo> <base> <feat>
    local r="$1" f="$3" out
    out="$( cd "$r" && DSO_GH_BIN="$_BIN/gh" GH_REPO="o/r" DSO_AUDIT_HMAC_KEY=k \
        MOCK_SHA="$f" bash "$FPA" 2>/dev/null )"
    # A bypass marker for PR #77 means NOT exempt; no marker means exempt.
    if printf '%s' "$out" | grep -q '"pr":77'; then echo not; else echo exempt; fi
}

_run() { # _run <name> <kind> <expected>
    local name="$1" kind="$2" exp="$3" r bf b f rci vsp fpa
    r="$(mktemp -d "$_W/repo.XXXXXX")"
    bf="$(_mk_repo "$kind" "$r")" || { _fail "$name" "fixture setup failed"; return; }
    b="${bf% *}"; f="${bf#* }"
    rci="$(_rci_verdict "$r" "$b" "$f")"
    vsp="$(_vsp_verdict "$r" "$b" "$f")"
    fpa="$(_fpa_verdict "$r" "$b" "$f")"
    if [[ "$rci" == "$exp" && "$vsp" == "$exp" && "$fpa" == "$exp" ]]; then
        _pass "$name (all three=$exp)"
    else
        _fail "$name" "rci=$rci vsp=$vsp fpa=$fpa expected=$exp — CONSUMERS DISAGREE or wrong"
    fi
}

_run "F_TICKETS_exempt"     tickets exempt
_run "F_CODE_notexempt"     code    not
_run "F_MIXED_notexempt"    mixed   not

echo ""
echo "=== test-ticket-exemption-equivalence.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
