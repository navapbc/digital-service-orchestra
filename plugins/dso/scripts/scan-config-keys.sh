#!/usr/bin/env bash
# scan-config-keys.sh
# Scans 4 locations for config key usages and outputs a gap list of keys that
# are used in code but NOT documented in CONFIGURATION-REFERENCE.md.
#
# Usage: scan-config-keys.sh [<repo-root>]
#   <repo-root>  Path to the target repo root (default: git rev-parse --show-toplevel)
#
# Exit codes:
#   0  — success (gap list printed to stdout, may be empty)
#   1  — error (e.g., repo-root not found, config ref doc missing)

set -uo pipefail

# ── Resolve plugin paths (_PLUGIN_ROOT + _PLUGIN_GIT_PATH) ───────────────────
# Use BASH_SOURCE to find this script's location, then derive:
#   _PLUGIN_ROOT: absolute filesystem path to the installed plugin directory
#   _PLUGIN_GIT_PATH: path relative to git repo root (for use when scanning
#     a target repo where the plugin may be under plugins/<name>/ or similar)
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

# ── Resolve target repo root ──────────────────────────────────────────────────
if [[ $# -ge 1 && -n "$1" ]]; then
    REPO_ROOT="$1"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "ERROR: could not determine repo root; pass as \$1 or run inside a git repo" >&2
        exit 1
    }
fi

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "ERROR: repo root does not exist: $REPO_ROOT" >&2
    exit 1
fi

# ── Scan paths in the target repo ────────────────────────────────────────────
# Require _PLUGIN_GIT_PATH env var to specify where the plugin is vendored in the
# target repo (relative path). If absent, derive from _PLUGIN_ROOT relative to REPO_ROOT
# (works for the development scenario where the plugin is inside the target repo).
if [[ -z "${_PLUGIN_GIT_PATH:-}" ]]; then
    _PLUGIN_GIT_PATH=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$_PLUGIN_ROOT" "$REPO_ROOT")
fi
PLUGINS_DIR="$REPO_ROOT/$_PLUGIN_GIT_PATH"
CLAUDE_DIR="$REPO_ROOT/.claude"
CONFIG_FILE="$REPO_ROOT/.claude/dso-config.conf"
CONFIG_REF="$PLUGINS_DIR/docs/CONFIGURATION-REFERENCE.md"
CONFIG_EXAMPLE="$PLUGINS_DIR/templates/dso-config.conf.example"

# ── Collect all referenced keys via Python (portable, no macOS sed issues) ───
python3 - "$PLUGINS_DIR" "$CLAUDE_DIR" "$CONFIG_FILE" "$CONFIG_EXAMPLE" "$CONFIG_REF" << 'PYEOF'
import sys
import os
import re
from pathlib import Path

plugins_dir, claude_dir, config_file, config_example, config_ref = sys.argv[1:6]

referenced_keys = set()

# (1) read-config.sh <key> — scan the plugin tree only
RC_PAT = re.compile(r'read-config\.sh\s+([A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+)')

# (2) _read_config_key "<key>" or '<key>' — scan plugin + .claude
RCK_PAT = re.compile(r'''_read_config_key\s+["']([A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+)["']''')

# (3) raw grep/cut: grep '^<key>=' .../dso-config.conf — scan plugin + .claude
GREP_PAT = re.compile(r"""grep\s+['"]\^([A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+)=['"].*dso-config\.conf""")

# (4) KEY=VALUE lines in dso-config.conf and example
KV_PAT = re.compile(r'^([A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+)=')

WORKTREES_SKIP = os.path.join(os.path.abspath(claude_dir), 'worktrees') + os.sep

def scan_tree(root, patterns):
    if not os.path.isdir(root):
        return
    for dp, dirs, files in os.walk(root):
        # Exclude .claude/worktrees/ — ephemeral test fixtures, not real plugin code
        abs_dp = os.path.abspath(dp) + os.sep
        if abs_dp.startswith(WORKTREES_SKIP):
            dirs[:] = []
            continue
        for fn in files:
            fp = os.path.join(dp, fn)
            try:
                with open(fp, 'r', errors='replace') as fh:
                    content = fh.read()
            except (OSError, UnicodeDecodeError):
                continue
            for pat in patterns:
                for m in pat.finditer(content):
                    referenced_keys.add(m.group(1))

# (1) plugin tree
scan_tree(plugins_dir, [RC_PAT])
# (2)(3) plugin + .claude
scan_tree(plugins_dir, [RCK_PAT, GREP_PAT])
scan_tree(claude_dir, [RCK_PAT, GREP_PAT])

# (4) config files (line-based KEY=VALUE)
for cfgp in (config_file, config_example):
    if cfgp and os.path.isfile(cfgp):
        try:
            with open(cfgp, 'r', errors='replace') as fh:
                for line in fh:
                    line = line.strip()
                    if line.startswith('#') or not line:
                        continue
                    m = KV_PAT.match(line)
                    if m:
                        referenced_keys.add(m.group(1))
        except OSError:
            continue

# Cross-reference against CONFIGURATION-REFERENCE.md
documented = ''
if config_ref and os.path.isfile(config_ref):
    try:
        with open(config_ref, 'r', errors='replace') as fh:
            documented = fh.read()
    except OSError:
        pass

gap = sorted(k for k in referenced_keys if k not in documented)
for k in gap:
    print(k)
PYEOF
