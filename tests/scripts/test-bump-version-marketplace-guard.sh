#!/usr/bin/env bash
# tests/scripts/test-bump-version-marketplace-guard.sh — 0f17 DD3
#
# Guard: bump-version.sh must NEVER write marketplace.json. The marketplace.json
# version/ref pins the STABLE release channel by design and is owned exclusively by
# the release tooling (tag-release.sh / release.sh) — the per-promotion version bump
# (which rides PR1's reviewed path under KEEP) must leave it byte-for-byte untouched.
# This pins that scope boundary so a future refactor of bump-version.sh cannot start
# co-writing the marketplace pin.
#
#   G1 bump-version.sh --patch bumps the configured version.file_path (plugin.json)
#      AND leaves a sibling marketplace.json byte-identical.

set -uo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
REPO_ROOT="$(git rev-parse --show-toplevel)"
BUMP="$REPO_ROOT/plugins/dso/scripts/bump-version.sh"   # shim-exempt: invokes the script under test

PASS=0; FAIL=0
_ok() { echo "PASS: $1"; PASS=$((PASS+1)); }
_no() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/bump-mkt-guard.XXXXXX")"; trap 'rm -rf "$_W"' EXIT

# Fixture: a non-main git repo with a configured version file (plugin.json) and a
# sibling marketplace.json. Run on a feature branch so the primary-main refusal in
# bump-version.sh does not fire.
if ( cd "$_W" || exit 1
     git init -q -b work . 2>/dev/null
     git config user.email t@e.st; git config user.name t
     mkdir -p .claude-plugin
     printf '{\n  "version": "1.0.0"\n}\n' > plugin.json
     printf '{\n  "name": "dso",\n  "version": "9.9.9",\n  "plugins": []\n}\n' > .claude-plugin/marketplace.json
     printf 'version.file_path=plugin.json\n' > "$_W/cfg.conf"
     mkt_before="$(md5sum .claude-plugin/marketplace.json 2>/dev/null || md5 -q .claude-plugin/marketplace.json)"

     DSO_ALLOW_BUMP_ON_MAIN=1 bash "$BUMP" --patch --config "$_W/cfg.conf" >/dev/null 2>&1 || exit 1

     new_ver="$(grep -o '"version"[^,]*' plugin.json | head -1)"
     mkt_after="$(md5sum .claude-plugin/marketplace.json 2>/dev/null || md5 -q .claude-plugin/marketplace.json)"
     # plugin.json must be bumped to 1.0.1; marketplace.json must be unchanged.
     [[ "$new_ver" == *1.0.1* && "$mkt_before" == "$mkt_after" ]] ); then
    _ok "G1 bump-version bumps plugin.json, leaves marketplace.json untouched"
else
    _no "G1 marketplace guard" "marketplace.json was modified or plugin.json not bumped to 1.0.1"
fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]]
