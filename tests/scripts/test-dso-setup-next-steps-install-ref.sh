#!/usr/bin/env bash
# tests/scripts/test-dso-setup-next-steps-install-ref.sh
# RED-phase test for bug b3f0-d08b:
#   dso-setup.sh's next-steps output line "3. See INSTALL.md for full documentation"
#   references a bare filename. INSTALL.md lives in the plugin repo root, NOT in
#   the scaffolded project, so a user has no way to find it from the bare name.
#
# This test asserts the next-steps line points to a reachable location —
# either a URL, or explicit language that tells the user where to look.
#
# RED (before fix): fails because the line says "INSTALL.md" with no path/URL.
# GREEN (after fix): passes because the line contains a URL or clear location hint.
#
# Usage:
#   bash tests/scripts/test-dso-setup-next-steps-install-ref.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/dso-setup.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-dso-setup-next-steps-install-ref.sh ==="

# Read the exact line emitted for step 3 of the next-steps guidance.
_line=$(grep -E "^echo '3\. " "$SETUP_SCRIPT" | head -1)

# Behavioral assertion: the line must reference a URL (http(s)://) or contain
# an explicit plugin-repo location hint. A bare "INSTALL.md" fails.
_has_url="no"
if [[ "$_line" =~ https?:// ]]; then
    _has_url="yes"
fi
assert_eq "step 3 guidance: contains URL" "yes" "$_has_url"

# Secondary assertion: the URL (when present) points to the plugin repo
_has_plugin_url="no"
if [[ "$_line" =~ digital-service-orchestra ]]; then
    _has_plugin_url="yes"
fi
assert_eq "step 3 guidance: URL points to digital-service-orchestra repo" "yes" "$_has_plugin_url"

print_summary
