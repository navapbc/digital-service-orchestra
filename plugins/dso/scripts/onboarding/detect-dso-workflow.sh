#!/usr/bin/env bash
# detect-dso-workflow.sh
# Detects the appropriate dso.workflow value based on git remote URL.
# Outputs 'ci-pr' for github.com (https or ssh), 'local' for everything else.
#
# Usage: detect-dso-workflow.sh [<remote-url-or-repo-dir>]
#   If argument is a directory, reads origin URL from git remote get-url origin in that dir.
#   If argument is a URL string, uses it directly.
#   If omitted, reads from git remote get-url origin in the current directory.
#
# Exit codes:
#   0 — always (outputs ci-pr or local on stdout)
set -euo pipefail

_arg="${1:-}"
_remote_url=""

if [[ -z "$_arg" ]]; then
    # No argument: read from current directory
    _remote_url=$(git remote get-url origin 2>/dev/null || echo "")
elif [[ -d "$_arg" ]]; then
    # Argument is a directory: read origin URL from that git repo
    _remote_url=$(git -C "$_arg" remote get-url origin 2>/dev/null || echo "")
else
    # Argument is a URL string: use it directly
    _remote_url="$_arg"
fi

# Match ONLY public github.com — not enterprise GitHub hosts
if [[ "$_remote_url" == https://github.com/* ]] || [[ "$_remote_url" == git@github.com:* ]]; then
    echo "ci-pr"
else
    echo "local"
fi
