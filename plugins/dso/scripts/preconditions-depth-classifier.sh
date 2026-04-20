#!/usr/bin/env bash
# preconditions-depth-classifier.sh
# Provides _classify_manifest_depth() — maps complexity classification to
# (manifest_depth, schema_version) for use by _write_preconditions() callers.
#
# Usage:
#   source preconditions-depth-classifier.sh
#   _classify_manifest_depth TRIVIAL    # → manifest_depth=minimal schema_version=1
#   _classify_manifest_depth MODERATE   # → manifest_depth=standard schema_version=2
#   _classify_manifest_depth COMPLEX    # → manifest_depth=deep schema_version=2
#   _classify_manifest_depth SIMPLE     # → manifest_depth=minimal schema_version=1
#   _classify_manifest_depth UNKNOWN    # → manifest_depth=minimal schema_version=1 (fail-open)
#
# Mapping (per preconditions-schema-v2.md contract):
#   TRIVIAL / SIMPLE → minimal  (schema_version=1)
#   MODERATE         → standard (schema_version=2)
#   COMPLEX          → deep     (schema_version=2)
#   unknown values   → minimal  (schema_version=1, fail-open)

set -uo pipefail

# _classify_manifest_depth <classification>
# Prints two lines to stdout:
#   manifest_depth=<minimal|standard|deep>
#   schema_version=<1|2>
_classify_manifest_depth() {
    local classification="${1:-}"
    case "$classification" in
        TRIVIAL|SIMPLE)
            echo "manifest_depth=minimal"
            echo "schema_version=1"
            ;;
        MODERATE)
            echo "manifest_depth=standard"
            echo "schema_version=2"
            ;;
        COMPLEX)
            echo "manifest_depth=deep"
            echo "schema_version=2"
            ;;
        *)
            # fail-open: unknown classification → minimal tier
            echo "manifest_depth=minimal"
            echo "schema_version=1"
            ;;
    esac
}
