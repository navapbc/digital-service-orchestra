#!/usr/bin/env bash
# ci-dso-fetch.sh
# Resolve-and-fetch helper for DSO plugin in CI.
#
# Steps:
#   1. Call resolve-dso-version.sh to determine VERSION (git ref) and SOURCE_TIER.
#   2. Derive CLONE_DIR=${RUNNER_TEMP:-<mktemp>}/dso/<VERSION>/
#   3. Check for sentinel file at CLONE_DIR/dso-sentinel.json.
#      Sentinel schema: {"version": "<ref>", "commit_sha": "<sha>"}
#   4. If sentinel exists: call git ls-remote to verify recorded SHA matches
#      the ref's actual HEAD SHA — mismatch triggers a fresh clone.
#   5. On cache miss or SHA mismatch: clone to a tmpdir, rename into CLONE_DIR
#      atomically (handles concurrent CI jobs safely).
#   6. After a successful clone: write dso-sentinel.json.
#   7. Export CLONE_DIR so subsequent CI steps can reference it.
#   8. Validate CLONE_DIR/<plugin-path>/marketplace.json exists (post-clone check).
#
# Environment variables (all optional, for test isolation):
#   RESOLVE_DSO_VERSION_SCRIPT  — override path to resolve-dso-version.sh
#   DSO_REPO_URL                — override the repo URL to clone from
#   RUNNER_TEMP                 — base temp dir (set automatically by GitHub Actions)
#   CI_DSO_FETCH_GIT_CMD        — override git binary (for testing; default: git)
#   CI_DSO_FETCH_SKIP_LS_REMOTE — set to "1" to skip git ls-remote SHA verification
#
# Exit codes:
#   0  Success; CLONE_DIR exported and populated
#   1  Failure (resolve, clone, or validation error)

set -euo pipefail

# ── Resolve script directory and plugin root ───────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

# ── Constants ──────────────────────────────────────────────────────────────────
readonly _DEFAULT_DSO_REPO_URL="https://github.com/navapbc/digital-service-orchestra.git"
readonly _SENTINEL_FILE="dso-sentinel.json"

# Path to marketplace.json within the cloned DSO repo, derived from the plugin's
# own install path relative to the repo root. This avoids hardcoding a literal
# path and adapts automatically if the plugin is installed at a non-default location.
_REPO_ROOT_FOR_PATH="$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$_REPO_ROOT_FOR_PATH" && "$_PLUGIN_ROOT" == "$_REPO_ROOT_FOR_PATH"* ]]; then
    _PLUGIN_GIT_PATH="${_PLUGIN_ROOT#"$_REPO_ROOT_FOR_PATH"/}"
else
    # Fallback: _PLUGIN_ROOT is not under the git root (e.g. tmp install); use dirname only.
    _PLUGIN_GIT_PATH="$(basename "$_PLUGIN_ROOT")"
fi
readonly _MARKETPLACE_RELATIVE="${_PLUGIN_GIT_PATH}/marketplace.json"

# ── Helpers ────────────────────────────────────────────────────────────────────

_log() { printf '[ci-dso-fetch] %s\n' "$*" >&2; }
_die() { _log "ERROR: $*"; exit 1; }

# Write dso-sentinel.json to a given directory.
# Args: $1=target_dir, $2=version, $3=commit_sha
_write_sentinel() {
    local target_dir="$1"
    local version="$2"
    local commit_sha="$3"

    python3 -c "
import json, sys
sentinel = {'version': sys.argv[1], 'commit_sha': sys.argv[2]}
with open(sys.argv[3], 'w') as f:
    json.dump(sentinel, f, indent=2)
    f.write('\n')
" "$version" "$commit_sha" "$target_dir/$_SENTINEL_FILE"
}

# Read the commit_sha field from an existing sentinel file.
# Prints the sha on stdout; exits non-zero on parse failure.
_read_sentinel_sha() {
    local sentinel_path="$1"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    sha = d.get('commit_sha', '').strip()
    if not sha:
        sys.exit(1)
    print(sha)
except Exception:
    sys.exit(1)
" "$sentinel_path"
}

# ── Step 1: Resolve DSO version ────────────────────────────────────────────────
_resolve_version_script="${RESOLVE_DSO_VERSION_SCRIPT:-$_SCRIPT_DIR/resolve-dso-version.sh}"

if [[ ! -f "$_resolve_version_script" ]]; then
    _die "resolve-dso-version.sh not found at: $_resolve_version_script"
fi

_log "Resolving DSO version via: $_resolve_version_script"

_resolve_output=""
_resolve_output=$(bash "$_resolve_version_script") || \
    _die "resolve-dso-version.sh failed (see above for tier diagnostics)"

# Parse RESOLVED_VERSION and RESOLVED_TIER from key=value output.
VERSION=""
SOURCE_TIER=""
while IFS='=' read -r key value; do
    case "$key" in
        RESOLVED_VERSION) VERSION="$value" ;;
        RESOLVED_TIER)    SOURCE_TIER="$value" ;;
    esac
done <<< "$_resolve_output"

if [[ -z "$VERSION" ]]; then
    _die "resolve-dso-version.sh did not emit RESOLVED_VERSION"
fi

_log "Resolved VERSION=$VERSION SOURCE_TIER=$SOURCE_TIER"

# ── Step 2: Derive CLONE_DIR ───────────────────────────────────────────────────
# Sanitize VERSION for use in a path (replace '/' with '_' for branch refs).
_version_path="${VERSION//\//_}"
_base_tmp="${RUNNER_TEMP:-}"
if [[ -z "$_base_tmp" ]]; then
    _base_tmp="$(mktemp -d)"
    _log "RUNNER_TEMP not set; using mktemp base: $_base_tmp"
fi

CLONE_DIR="${_base_tmp}/dso/${_version_path}"
export CLONE_DIR
_log "CLONE_DIR=$CLONE_DIR"

# ── Step 3 & 4: Sentinel check and SHA verification ───────────────────────────
_DSO_REPO_URL="${DSO_REPO_URL:-$_DEFAULT_DSO_REPO_URL}"
_GIT="${CI_DSO_FETCH_GIT_CMD:-git}"
_SKIP_LS_REMOTE="${CI_DSO_FETCH_SKIP_LS_REMOTE:-0}"

_need_clone=1  # default: assume we need to clone

_sentinel_path="$CLONE_DIR/$_SENTINEL_FILE"

if [[ -f "$_sentinel_path" ]]; then
    _log "Sentinel found at: $_sentinel_path"
    _cached_sha=""
    _cached_sha=$(_read_sentinel_sha "$_sentinel_path") || {
        _log "Sentinel parse failed — will re-clone"
        _need_clone=1
    }

    if [[ -n "$_cached_sha" ]]; then
        if [[ "$_SKIP_LS_REMOTE" == "1" ]]; then
            _log "CI_DSO_FETCH_SKIP_LS_REMOTE=1 — skipping ls-remote SHA verification"
            _need_clone=0
        else
            _log "Verifying cached SHA=$_cached_sha against remote ref=$VERSION"
            _remote_sha=""
            _remote_sha=$("$_GIT" ls-remote "$_DSO_REPO_URL" "refs/tags/$VERSION" "refs/heads/$VERSION" 2>/dev/null \
                | awk '{print $1}' | head -1) || true

            if [[ -z "$_remote_sha" ]]; then
                _log "git ls-remote returned no SHA for ref=$VERSION — will re-clone"
                _need_clone=1
            elif [[ "$_remote_sha" == "$_cached_sha" ]]; then
                _log "SHA match ($_cached_sha) — reusing cached clone"
                _need_clone=0
            else
                _log "SHA mismatch: cached=$_cached_sha remote=$_remote_sha — will re-clone"
                _need_clone=1
            fi
        fi
    fi
else
    _log "No sentinel at: $_sentinel_path — fresh clone required"
fi

# ── Step 5: Clone (atomic: clone to tmpdir, then rename) ──────────────────────
if [[ "$_need_clone" -eq 1 ]]; then
    _log "Cloning $VERSION from $_DSO_REPO_URL"

    # Create a tmpdir sibling to CLONE_DIR's parent for atomic rename.
    _clone_parent="$(dirname "$CLONE_DIR")"
    mkdir -p "$_clone_parent"

    _tmp_clone=""
    _tmp_clone="$(mktemp -d "${_clone_parent}/dso-clone-tmp.XXXXXX")"

    # Clean up tmpdir on any failure after this point.
    # shellcheck disable=SC2064
    trap "rm -rf '$_tmp_clone'" EXIT

    "$_GIT" clone --depth=1 --branch="$VERSION" "$_DSO_REPO_URL" "$_tmp_clone" \
        || _die "git clone failed for ref=$VERSION from $_DSO_REPO_URL"

    # Resolve the actual commit SHA from the freshly cloned HEAD.
    _cloned_sha=""
    _cloned_sha=$("$_GIT" -C "$_tmp_clone" rev-parse HEAD 2>/dev/null) \
        || _die "git rev-parse HEAD failed in cloned directory"

    # ── Step 6: Write sentinel before rename ──────────────────────────────────
    _log "Writing sentinel: version=$VERSION commit_sha=$_cloned_sha"
    _write_sentinel "$_tmp_clone" "$VERSION" "$_cloned_sha" \
        || _die "Failed to write sentinel file"

    # Atomic rename: if CLONE_DIR already exists, remove it first.
    # mv -T is GNU-only; use rm+mv for portability across macOS/Linux.
    if [[ -e "$CLONE_DIR" ]]; then
        _log "Removing stale CLONE_DIR before rename"
        rm -rf "$CLONE_DIR"
    fi
    mv "$_tmp_clone" "$CLONE_DIR" \
        || _die "Atomic rename from $_tmp_clone to $CLONE_DIR failed"

    # Disarm the EXIT trap now that rename succeeded.
    trap - EXIT

    _log "Clone complete at: $CLONE_DIR"
else
    _log "Cache hit — skipping clone"
fi

# ── Step 8: Post-clone validation ─────────────────────────────────────────────
_marketplace_path="$CLONE_DIR/$_MARKETPLACE_RELATIVE"
if [[ ! -f "$_marketplace_path" ]]; then
    _die "Post-clone validation failed: $_marketplace_path not found (SHA cache validation)"
fi
_log "Post-clone validation passed: $_marketplace_path exists"

# ── Emit CLONE_DIR for callers that source this script ────────────────────────
_log "CLONE_DIR=$CLONE_DIR (exported)"
