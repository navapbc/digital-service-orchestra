#!/usr/bin/env bash
# Re-run all four litellm-contract spikes. Use this whenever the litellm pin
# in plugins/dso/scripts/pyproject.toml changes — each spike prints PASS/FAIL
# and exits non-zero on regression.
#
# Spikes validate contracts the dso_ci_review parallelization plan depends on:
#   01 — sync-under-async serializes (current dispatch.py shape)
#   02 — litellm does not amplify retries at default config
#   03 — Anthropic rate-limit headers reachable via response._hidden_params
#   04 — litellm.acompletion parallelizes under asyncio.gather

set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
for s in "$DIR"/spike_*.py; do
    name="$(basename "$s")"
    echo "=== Running $name ==="
    if ! python3 "$s"; then
        fails=$((fails + 1))
        echo "FAIL: $name"
    fi
    echo
done
if [ "$fails" -gt 0 ]; then
    echo "$fails spike(s) failed."
    exit 1
fi
echo "All spikes passed."
