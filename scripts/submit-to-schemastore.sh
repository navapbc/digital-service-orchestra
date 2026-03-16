#!/usr/bin/env bash
set -uo pipefail
# scripts/submit-to-schemastore.sh
# Prepares the schemastore.org contribution for workflow-config-schema.json.
#
# This is a dry-run preparation helper. It does NOT make any HTTP requests
# or git operations.
#
# Usage:
#   bash submit-to-schemastore.sh [path/to/workflow-config-schema.json]
#
# Arguments:
#   [schema-file]  optional path to workflow-config-schema.json
#                  Defaults to the schema in docs/ relative
#                  to this script.
#
# Exit codes:
#   0  — schema is valid and ready for schemastore.org submission
#   1  — schema $id is missing, uses localhost, or is not valid JSON
#
# Output:
#   stdout — catalog.json entry and PR submission URL
#   stderr — error messages for invalid schema

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Resolve schema file path ---
if [[ $# -ge 1 ]]; then
    SCHEMA_FILE="$1"
else
    SCHEMA_FILE="$PLUGIN_ROOT/docs/workflow-config-schema.json"
fi

if [[ ! -f "$SCHEMA_FILE" ]]; then
    echo "ERROR: schema file not found: $SCHEMA_FILE" >&2
    exit 1
fi

# --- Validate schema is valid JSON ---
if ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$SCHEMA_FILE" 2>/dev/null; then
    echo "ERROR: $SCHEMA_FILE is not valid JSON" >&2
    exit 1
fi

# --- Extract $id field ---
SCHEMA_ID="$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('\$id', ''))" "$SCHEMA_FILE")"

# --- Validate $id ---
if [[ -z "$SCHEMA_ID" ]]; then
    echo "ERROR: schema \$id field is missing in $SCHEMA_FILE" >&2
    exit 1
fi

if echo "$SCHEMA_ID" | grep -qi "localhost"; then
    echo "ERROR: schema \$id points to localhost — must use a public GitHub URL" >&2
    echo "  Current \$id: $SCHEMA_ID" >&2
    echo "  Expected:     https://raw.githubusercontent.com/navapbc/digital-service-orchestra/main/docs/workflow-config-schema.json" >&2
    exit 1
fi

if ! echo "$SCHEMA_ID" | grep -q "github"; then
    echo "ERROR: schema \$id does not reference a GitHub URL" >&2
    echo "  Current \$id: $SCHEMA_ID" >&2
    echo "  Expected:     https://raw.githubusercontent.com/navapbc/digital-service-orchestra/main/docs/workflow-config-schema.json" >&2
    exit 1
fi

# --- Validate $schema field is draft-07 ---
SCHEMA_META="$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('\$schema', ''))" "$SCHEMA_FILE")"
if ! echo "$SCHEMA_META" | grep -q "draft-07"; then
    echo "WARNING: schema \$schema field does not reference draft-07: $SCHEMA_META" >&2
fi

# --- Print the catalog.json entry ---
SCHEMA_RAW_URL="https://raw.githubusercontent.com/navapbc/digital-service-orchestra/main/docs/workflow-config-schema.json"

echo "Schema is valid and ready for schemastore.org submission."
echo ""
echo "Add the following entry to src/api/json/catalog.json in the SchemaStore PR:"
echo ""
echo '{'
echo '  "name": "workflow-config",'
echo '  "description": "Schema for workflow-config.conf — Digital Service Orchestra plugin configuration",'
echo '  "fileMatch": ["workflow-config.conf"],'
echo "  \"url\": \"$SCHEMA_RAW_URL\""
echo '}'
echo ""
echo "Submit PR to: https://github.com/SchemaStore/schemastore/pulls"
echo ""
echo "Steps:"
echo "  1. Fork https://github.com/SchemaStore/schemastore"
echo "  2. Add the catalog.json entry above to src/api/json/catalog.json"
echo "  3. Ensure workflow-config-schema.json is publicly accessible at:"
echo "     $SCHEMA_RAW_URL"
echo "  4. Open a PR to https://github.com/SchemaStore/schemastore"

exit 0
