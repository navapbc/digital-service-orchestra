#!/usr/bin/env bash
# capture-baseline.sh
#
# Measures per-op latency for the current ticket CLI dispatcher and produces a
# JSON fixture at tests/fixtures/ticket-cli-baseline.json.
#
# This script captures the PRE-REFACTOR baseline used by the regression test
# suite (epic 78fc-3858) to verify ≥60% latency reduction after
# ticket-lib-api.sh is implemented.
#
# Usage:
#   tests/scripts/capture-baseline.sh [--output-path <path>] [--runs <n>]
#
# Must be run from the repository root (where .claude/scripts/dso lives).

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OUTPUT_PATH="tests/fixtures/ticket-cli-baseline.json"
RUNS=10
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-path)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --runs)
      RUNS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Dependency check: hyperfine
# ---------------------------------------------------------------------------
if ! command -v hyperfine >/dev/null 2>&1; then
  cat <<'EOF' >&2
Error: hyperfine is required. Install via:
  Linux: curl -LO https://github.com/sharkdp/hyperfine/releases/download/v1.18.0/hyperfine_1.18.0_amd64.deb && sudo dpkg -i hyperfine_1.18.0_amd64.deb
  macOS: brew install hyperfine
EOF
  exit 1
fi

# Resolve repo root so TICKETS_TRACKER_DIR paths and the dso shim stay valid
# inside the hyperfine-spawned subshells (which run in the temp cwd).
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_SHIM="$REPO_ROOT/.claude/scripts/dso"

if [[ ! -x "$DSO_SHIM" ]]; then
  echo "Error: .claude/scripts/dso shim not found or not executable at: $DSO_SHIM" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Temp environment setup
# ---------------------------------------------------------------------------
TMP_ROOT="$(mktemp -d)"
BENCH_TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_ROOT" "$BENCH_TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

pushd "$TMP_ROOT" >/dev/null

git init -q
git config user.email "bench@test"
git config user.name "Bench"
# Create an initial commit so the repo has a HEAD (some ticket paths need it).
git commit --allow-empty -q -m "bench init"

export TICKETS_TRACKER_DIR="$TMP_ROOT/.tickets-tracker"
export _TICKET_TEST_NO_SYNC=1

"$DSO_SHIM" ticket init >/dev/null

# Create two tickets we can reference repeatedly.
T1="$("$DSO_SHIM" ticket create task "bench ticket 1" 2>/dev/null | awk '/^[a-f0-9]{4}-[a-f0-9]{4}$/ {print; exit}')"
T2="$("$DSO_SHIM" ticket create task "bench ticket 2" 2>/dev/null | awk '/^[a-f0-9]{4}-[a-f0-9]{4}$/ {print; exit}')"

if [[ -z "${T1:-}" || -z "${T2:-}" ]]; then
  # Fall back: grab the most recent ticket IDs from list output (portable, no mapfile).
  _ids=$("$DSO_SHIM" ticket list 2>/dev/null | python3 -c "import json,sys; ids=[t['ticket_id'] for t in json.load(sys.stdin)[:2]]; print(' '.join(ids))" 2>/dev/null || echo "")
  T1="${T1:-$(echo "$_ids" | cut -d' ' -f1)}"
  T2="${T2:-$(echo "$_ids" | cut -d' ' -f2)}"
fi

if [[ -z "${T1:-}" || -z "${T2:-}" ]]; then
  echo "Error: failed to create baseline tickets in temp env" >&2
  exit 1
fi

popd >/dev/null

# ---------------------------------------------------------------------------
# Benchmark ops
# ---------------------------------------------------------------------------
# Each op is: name|command. Commands inherit TICKETS_TRACKER_DIR + _TICKET_TEST_NO_SYNC
# via hyperfine's environment passthrough (hyperfine inherits the parent env).
OP_NAMES="show list comment create tag untag edit transition link"

_op_cmd() {
  local op="$1"
  case "$op" in
    show)       printf '%s ticket show %s'                  "$DSO_SHIM" "$T1" ;;
    list)       printf '%s ticket list'                     "$DSO_SHIM" ;;
    comment)    printf '%s ticket comment %s bench-comment' "$DSO_SHIM" "$T1" ;;
    create)     printf '%s ticket create task bench-create' "$DSO_SHIM" ;;
    tag)        printf '%s ticket tag %s bench-tag'         "$DSO_SHIM" "$T1" ;;
    untag)      printf '%s ticket untag %s bench-tag'       "$DSO_SHIM" "$T1" ;;
    edit)       printf '%s ticket edit %s --title edited-title' "$DSO_SHIM" "$T1" ;;
    transition) printf '%s ticket transition %s open in_progress' "$DSO_SHIM" "$T1" ;;
    link)       printf '%s ticket link %s %s relates_to'    "$DSO_SHIM" "$T1" "$T2" ;;
  esac
}

# For stateful ops that change ticket state between runs, a --prepare command
# resets the ticket to its required initial state before each hyperfine iteration.
_op_prepare() {
  local op="$1"
  case "$op" in
    # transition: reset ticket back to open before each run so open→in_progress always works
    transition) printf '%s ticket transition %s in_progress open' "$DSO_SHIM" "$T1" ;;
    # tag: ensure bench-tag does NOT exist before each tag run (so the tag op is always fresh)
    tag)        printf '%s ticket untag %s bench-tag' "$DSO_SHIM" "$T1" ;;
    # untag: ensure bench-tag EXISTS before each untag run
    untag)      printf '%s ticket tag %s bench-tag' "$DSO_SHIM" "$T1" ;;
    # link: remove the link before each run so each iteration measures creation, not dup-detect
    link)       printf '%s ticket unlink %s %s' "$DSO_SHIM" "$T1" "$T2" ;;
    *)          printf 'true' ;;
  esac
}

# Dry-run: validate environment and exit without running full benchmarks.
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo ">>> DRY RUN: environment check passed (hyperfine found, tickets created: $T1 $T2)"
  echo ">>> Would benchmark: $OP_NAMES"
  echo ">>> Would write fixture to: $OUTPUT_PATH"
  exit 0
fi

echo ">>> Running $RUNS iterations per op (warmup=3)..."
for op in $OP_NAMES; do
  cmd="$(_op_cmd "$op")"
  prepare="$(_op_prepare "$op")"
  out="$BENCH_TMP_DIR/bench-$op.json"
  echo "  [$op]"
  (
    cd "$TMP_ROOT"
    # Pre-warm: run the benchmark COMMAND once before hyperfine starts.
    # --prepare runs BEFORE each hyperfine iteration to reset state (e.g., for
    # transition: in_progress→open). On iteration 1, hyperfine calls --prepare
    # first, but the ticket is still in its initial state (open), so the
    # in_progress→open reset would fail. By running the command once here, the
    # ticket is left in the post-command state (in_progress), so the first
    # --prepare call finds what it expects and succeeds.
    if ! eval "$cmd" >/dev/null 2>&1; then
      echo "  [pre-warm failed for $op — hyperfine may abort]" >&2
    fi
    hyperfine \
      --runs "$RUNS" \
      --warmup 3 \
      --prepare "$prepare" \
      --export-json "$out" \
      --shell=bash \
      "$cmd" >/dev/null
  )
done

# ---------------------------------------------------------------------------
# Aggregate and write fixture JSON
# ---------------------------------------------------------------------------
CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CODEBASE_REF="$(git -C "$REPO_ROOT" describe --always --dirty --abbrev=40 2>/dev/null || git -C "$REPO_ROOT" rev-parse HEAD)"
PLATFORM="$(uname -sm)"
HF_VERSION="$(hyperfine --version | awk '{print $2}')"

# Make sure the output directory exists.
OUT_ABS="$OUTPUT_PATH"
case "$OUT_ABS" in
  /*) ;;
  *) OUT_ABS="$REPO_ROOT/$OUT_ABS" ;;
esac
mkdir -p "$(dirname "$OUT_ABS")"

# shellcheck disable=SC2086  # intentional word-split to pass op names as separate argv
python3 - "$OUT_ABS" "$CAPTURED_AT" "$CODEBASE_REF" "$PLATFORM" "$HF_VERSION" "$BENCH_TMP_DIR" $OP_NAMES <<'PYEOF'
import json
import sys
from pathlib import Path

out_path      = sys.argv[1]
captured_at   = sys.argv[2]
codebase_ref  = sys.argv[3]
platform      = sys.argv[4]
hf_version    = sys.argv[5]
bench_dir     = sys.argv[6]
op_names      = sys.argv[7:]

def metrics_for(op):
    p = Path(bench_dir) / f"bench-{op}.json"
    with p.open() as f:
        data = json.load(f)
    r = data["results"][0]
    times = sorted(r.get("times", []))
    if times:
        idx = min(len(times) - 1, int(len(times) * 0.95))
        p95 = times[idx]
    else:
        p95 = r.get("max", r.get("mean", 0.0))
    return {
        "mean_s":   round(r["mean"],   6),
        "p50_s":    round(r.get("median", r["mean"]), 6),
        "p95_s":    round(p95, 6),
        "stddev_s": round(r.get("stddev") or 0.0, 6),
    }

fixture = {
    "captured_at":       captured_at,
    "codebase_ref":      codebase_ref,
    "platform":          platform,
    "hyperfine_version": hf_version,
    "ops":               {op: metrics_for(op) for op in op_names},
}

Path(out_path).write_text(json.dumps(fixture, indent=2) + "\n")
print(f"Wrote baseline fixture: {out_path}")
PYEOF

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
echo
echo ">>> Summary (seconds):"
printf '  %-12s %10s %10s %10s %10s\n' "op" "mean" "p50" "p95" "stddev"
printf '  %-12s %10s %10s %10s %10s\n' "------------" "----------" "----------" "----------" "----------"
python3 - "$OUT_ABS" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    fx = json.load(f)
for op, m in fx["ops"].items():
    print(f"  {op:<12} {m['mean_s']:>10.4f} {m['p50_s']:>10.4f} {m['p95_s']:>10.4f} {m['stddev_s']:>10.4f}")
PYEOF

echo
echo "Done."
