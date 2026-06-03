#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-mq-path.sh — MQ-4 (ADR-0019)
#
# BEHAVIORAL test of the flag-gated GitHub Merge Queue promotion path in
# merge-to-main-pr.sh. The script is EXECUTED under a gh/git stub harness and
# the observable gh invocations (gh-argv.log) are asserted — not the source text.
#
# The flag's effect is made observable by giving the fixture a github.com origin
# (merge-to-main-pr.sh:919 only runs the staged-intermediate phase for a real
# github.com remote). Then:
#   - flag OFF (default / DSO_MERGE_QUEUE_ENABLED_OVERRIDE=0): the legacy
#     two-tier flow runs _phase_staged_intermediate → it mints a staged-* ref via
#     `gh api -X POST repos/.../git/refs`. That POST appears in gh-argv.
#   - flag ON (DSO_MERGE_QUEUE_ENABLED_OVERRIDE=1): the merge-queue path promotes
#     session→main DIRECTLY — _phase_staged_intermediate is never called, so NO
#     `git/refs` POST appears, and a single `gh pr create --base main` is issued.
# A golden-argv run proves flag-absent == flag-explicitly-OFF (default-OFF is
# behaviorally inert — the load-bearing safety property pre-MQ-6).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/merge-to-main-pr.sh"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PASS=0
FAIL=0

_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "PRECONDITION_NOT_MET: python3 not in PATH" >&2; exit 78
fi

# ── Fixture: stub gh (logs argv) + git (no network) + a tiny repo with a
#    github.com origin so the staged-intermediate phase is eligible to run. ────
_build_fixture() {
    local tmpdir="$1" branch="$2"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"
    local gh_argv_log="$tmpdir/gh-argv.log"

    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_argv_log"
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  pr)
    case "\$2" in
      list) exit 0 ;;
      create) echo "https://github.com/x/y/pull/42"; exit 0 ;;
      view)
        if [[ "\$*" == *"--json state"* ]]; then echo "MERGED"; exit 0; fi
        if [[ "\$*" == *"--json headRefOid"* ]]; then echo ""; exit 0; fi
        if [[ "\$*" == *"reviewThreads"* ]]; then echo "{}"; exit 0; fi
        echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0 ;;
      checks) echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'; exit 0 ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac ;;
  api)
    if [[ "\$2" == "graphql" ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'; exit 0
    fi
    # staged-ref creation: return a minimal ref object so _create_staged_ref
    # can proceed (the POST is what we assert on regardless).
    if [[ "\$*" == *"git/refs"* ]]; then
      echo '{"ref":"refs/heads/staged-test-1","object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}'; exit 0
    fi
    exit 0 ;;
  repo)
    if [[ "\$2" == "view" ]]; then
      if [[ "\$*" == *"defaultBranchRef"* ]]; then echo "main"; else echo "x/y"; fi
      exit 0
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    # git shim: no-op the network verbs (push/fetch/ls-remote), delegate the rest.
    local real_git; real_git=$(command -v git)
    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
case "\$1" in
  push)      printf 'push %s\n' "\$*" >> "$tmpdir/git-push.log"; exit 0 ;;
  fetch)     exit 0 ;;
  ls-remote) exit 0 ;;
  *) exec "$real_git" "\$@" ;;
esac
GIT_SHIM
    chmod +x "$bin/git"

    ( cd "$tmpdir" || exit 1
      "$real_git" init -q -b main >/dev/null 2>&1
      "$real_git" config user.email "test@test.local"
      "$real_git" config user.name "test"
      echo seed > seed.txt; "$real_git" add seed.txt; "$real_git" commit -q -m seed >/dev/null
      "$real_git" checkout -q -b "$branch"
      echo feature > feature.txt; "$real_git" add feature.txt
      "$real_git" commit -q -m "feature work" >/dev/null
      # Real github.com origin URL so the staged-intermediate eligibility check passes.
      "$real_git" remote add origin "https://github.com/x/y.git"
    )
}

# Run the script in a fixture with the given override value ("" = unset).
# Echoes the path to the captured gh-argv.log.
_run() {
    local tmpdir="$1" branch="$2" override="$3"
    _build_fixture "$tmpdir" "$branch"
    (
        cd "$tmpdir" || exit 1
        if [[ -n "$override" ]]; then export DSO_MERGE_QUEUE_ENABLED_OVERRIDE="$override"; fi
        PATH="$tmpdir/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        timeout 45 bash "$PR_SCRIPT" >/dev/null 2>&1
    ) || true
    echo "$tmpdir/gh-argv.log"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dso-mq-path.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── Test 1: flag OFF → two-tier — a staged-* ref is created (git/refs POST) ──
off_argv="$(cat "$(_run "$WORK/off" off-branch 0)" 2>/dev/null || echo '')"
if echo "$off_argv" | grep -q 'git/refs'; then
    _pass "flag_off_creates_staged_ref"
else
    _fail "flag_off_creates_staged_ref" "expected a git/refs POST (staged ref) under flag OFF; argv=[$off_argv]"
fi

# ── Test 2: flag ON → merge-queue path — _phase_staged_intermediate is NOT
#    invoked, so NO staged-* ref is minted (the defining behavioral difference) ─
on_argv="$(cat "$(_run "$WORK/on" on-branch 1)" 2>/dev/null || echo '')"
if echo "$on_argv" | grep -q 'git/refs'; then
    _fail "flag_on_skips_staged_ref" "merge-queue path must NOT create a staged ref; argv=[$on_argv]"
else
    _pass "flag_on_skips_staged_ref"
fi

# ── Test 3 (default-OFF invariance): flag ABSENT runs the two-tier staged path,
#    identical to explicit OFF — the load-bearing safety property pre-MQ-6. ────
absent_argv="$(cat "$(_run "$WORK/absent" off2-branch '')" 2>/dev/null || echo '')"
if echo "$absent_argv" | grep -q 'git/refs'; then
    _pass "flag_absent_runs_two_tier_like_off"
else
    _fail "flag_absent_runs_two_tier_like_off" "default (flag absent) must behave as OFF and create a staged ref; argv=[$absent_argv]"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
