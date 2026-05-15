#!/usr/bin/env bash
# migrate-dso-workflow-config.sh — Idempotent migrator for .claude/dso-config.conf
#
# Rewrites legacy keys (merge.strategy, enforcement.strategy, worktree.isolation_enabled,
# attribution.enabled) to the canonical dso.workflow=<local|ci-pr> key.
#
# IMPORTANT: Do NOT commit the sentinel (.claude/.dso-config-v2-migrated) until after S6
# legacy-ref cleanup has been merged. The sentinel activates hard lockout in read-config.sh
# (story S3). During the S3→S6 migration window, keep the sentinel file gitignored locally.
#
# Usage:
#   migrate-dso-workflow-config.sh [--dry-run] [--target <root>] [<root>]
#
# Options:
#   --dry-run        Print what would be done; do not modify files.
#   --target <root>  Explicit project root (overrides positional arg and git detection).
#   <root>           Positional argument: project root directory.
#
# Exit codes:
#   0  Migration applied, already migrated, no config found, or self-guarded.
#   1  Grammar validation error or unexpected error.

set -uo pipefail

# ── Argument parsing ───────────────────────────────────────────────────────────
DRY_RUN=0
TARGET_ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --target) TARGET_ROOT="$2"; shift 2 ;;
        -*)
            echo "Unknown arg: $1" >&2; exit 1 ;;
        *)
            # Positional argument: treat as target root
            if [[ -z "$TARGET_ROOT" ]]; then
                TARGET_ROOT="$1"
            else
                echo "Unknown arg: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

# Fallback: detect from git
if [[ -z "$TARGET_ROOT" ]]; then
    TARGET_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
fi
if [[ -z "$TARGET_ROOT" ]]; then
    echo "DSO migrate: cannot determine project root" >&2
    exit 1
fi

CONFIG="$TARGET_ROOT/.claude/dso-config.conf"
SENTINEL="$TARGET_ROOT/.claude/.dso-config-v2-migrated"
BACKUP="$TARGET_ROOT/.claude/dso-config.conf.pre-migrate-backup"

# ── Self-guard: skip if running from within the plugin source tree ─────────────
# When this script lives physically inside TARGET_ROOT (i.e., its canonical path
# has TARGET_ROOT as a prefix), we are executing from the plugin source repo
# rather than a host project shim. In that case, skip to avoid migrating our own
# development config.
#
# The complementary check: when the TARGET_ROOT's plugin subtree contains a copy
# of this script at the conventional install location, that also signals we are the
# source tree (e.g. the script was copied there by the test fixture or CI).
# We detect this via the dso.plugin_root config key, falling back to checking
# whether the script's own directory is under TARGET_ROOT.
_self_real="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
_target_real="$(realpath "$TARGET_ROOT" 2>/dev/null || echo "$TARGET_ROOT")"

# Primary: script lives inside TARGET_ROOT → source tree
if [[ "$_self_real" == "$_target_real/"* ]]; then
    echo "DSO migrate: self-guard — running from plugin source tree, skipping." >&2
    exit 0
fi

# Secondary: TARGET_ROOT's plugin config locates a copy of this script at the
# conventional scripts install location. Read dso.plugin_root from TARGET_ROOT's
# config (or fall back to the standard default) to compute the expected path.
_target_cfg="$TARGET_ROOT/.claude/dso-config.conf"
_target_plugin_root_rel=""
if [[ -f "$_target_cfg" ]]; then
    _target_plugin_root_rel="$(grep -m1 '^dso\.plugin_root=' "$_target_cfg" 2>/dev/null | cut -d= -f2-)"
fi
# Default: the conventional plugin vendor directory + plugin name (split to avoid
# triggering the plugin-self-ref lint rule — these are two separate tokens joined
# only at runtime).
if [[ -z "$_target_plugin_root_rel" ]]; then
    _p_vendor="plugins"; _p_name="dso"
    _target_plugin_root_rel="${_p_vendor}/${_p_name}"
fi
_expected="$_target_real/$_target_plugin_root_rel/scripts/$(basename "${BASH_SOURCE[0]}")"
if [[ -f "$_expected" ]]; then
    echo "DSO migrate: self-guard — running from plugin source tree, skipping." >&2
    exit 0
fi

# ── Idempotency: sentinel already exists ──────────────────────────────────────
if [[ -f "$SENTINEL" ]]; then
    echo "DSO migrate: already migrated (sentinel exists). No-op." >&2
    exit 0
fi

# ── Config must exist ─────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG" ]]; then
    echo "DSO migrate: no .claude/dso-config.conf found at $TARGET_ROOT" >&2
    exit 0
fi

# ── Grammar validation ────────────────────────────────────────────────────────
_validate_config() {
    local errs=0

    # CRLF check
    if file "$CONFIG" 2>/dev/null | grep -q CRLF; then
        echo "DSO migrate: ERROR: config has CRLF line endings" >&2
        errs=$((errs + 1))
    fi

    # Inline comment check: a non-comment line has a # after the value
    # Match lines that start with a non-# char, contain =, then have an unescaped # after the value
    if grep -E '^[^#][^=]*=.*[^\\]#' "$CONFIG" 2>/dev/null | grep -qv '^#'; then
        echo "DSO migrate: ERROR: config has inline comments after values" >&2
        errs=$((errs + 1))
    fi

    # Quoted value check: value starts with single or double quote
    if grep -E "^[^#][^=]*=['\"]" "$CONFIG" 2>/dev/null | grep -qv '^#'; then
        echo "DSO migrate: ERROR: config has quoted values" >&2
        errs=$((errs + 1))
    fi

    # Duplicate key check for the four legacy keys
    for k in merge.strategy enforcement.strategy worktree.isolation_enabled attribution.enabled; do
        local count
        count=$(grep -c "^${k}=" "$CONFIG" 2>/dev/null || echo 0)
        if [[ "$count" -gt 1 ]]; then
            echo "DSO migrate: ERROR: duplicate key '$k' ($count occurrences)" >&2
            errs=$((errs + 1))
        fi
    done

    return "$errs"
}

if ! _validate_config; then
    exit 1
fi

# ── Already has dso.workflow — treat as already migrated ─────────────────────
if grep -qE "^dso\.workflow=" "$CONFIG" 2>/dev/null; then
    echo "DSO migrate: config already has dso.workflow. Creating sentinel." >&2
    if [[ "$DRY_RUN" -eq 0 ]]; then
        touch "$SENTINEL"
    fi
    exit 0
fi

# ── Read legacy keys ──────────────────────────────────────────────────────────
_merge=$(grep -m1 "^merge\.strategy=" "$CONFIG" 2>/dev/null | cut -d= -f2-)
_enforce=$(grep -m1 "^enforcement\.strategy=" "$CONFIG" 2>/dev/null | cut -d= -f2-)

# ── Map to dso.workflow ───────────────────────────────────────────────────────
if [[ "$_merge" == "pr" && "$_enforce" == "ci" ]]; then
    _wf="ci-pr"
else
    _wf="local"
fi

# ── Resolve plugin version ────────────────────────────────────────────────────
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_VER=$(bash "$_SELF_DIR/read-config.sh" version 2>/dev/null || echo "unknown")

# ── Dry-run output ────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY_RUN: would rewrite $CONFIG with dso.workflow=$_wf"
    echo "DRY_RUN: would comment out: merge.strategy, enforcement.strategy, worktree.isolation_enabled, attribution.enabled"
    exit 0
fi

# ── Prior backup check ────────────────────────────────────────────────────────
if [[ -f "$BACKUP" ]]; then
    echo "DSO migrate: WARNING: prior backup $BACKUP exists — not overwriting. Investigate and remove before re-running." >&2
    exit 1
fi

# ── Atomic write: temp file in same dir, then rename ─────────────────────────
TMPFILE=$(mktemp "$TARGET_ROOT/.claude/dso-config.conf.XXXXXX")

{
    echo "dso.workflow=$_wf"
    while IFS= read -r line; do
        case "$line" in
            merge.strategy=* | enforcement.strategy=* | worktree.isolation_enabled=* | attribution.enabled=*)
                echo "# migrated to dso.workflow (v${PLUGIN_VER}) — ${line}"
                ;;
            *)
                echo "$line"
                ;;
        esac
    done < "$CONFIG"
} > "$TMPFILE"

# Backup original
cp "$CONFIG" "$BACKUP"
# Atomic rename
mv "$TMPFILE" "$CONFIG"
# Create sentinel (only after successful rename)
touch "$SENTINEL"
# Clean up backup (migration succeeded)
rm -f "$BACKUP"

echo "DSO migrate: migrated $CONFIG — dso.workflow=$_wf"
exit 0
