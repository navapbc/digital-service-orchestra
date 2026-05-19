#!/usr/bin/env bash
set -uo pipefail
# format-recipe-result.sh
# Translates structured JSON output from recipe-executor.sh into a human-readable
# summary for the sprint log.
#
# Usage:
#   echo '<json>' | format-recipe-result.sh <recipe-name>
#
# Arguments:
#   $1 — recipe name (e.g., add-parameter)
#
# Stdin:
#   JSON from recipe-executor.sh with fields:
#     exit_code, transforms_applied, files_changed, errors, degraded, engine_name
#
# Stdout:
#   Human-readable summary (multi-line)
#
# Exit codes:
#   0 — success
#   1 — invalid JSON input (error written to stderr)

RECIPE_NAME="${1:-}"

# Read all stdin into a temp file so python3 can read it cleanly
TMPFILE="$(mktemp /tmp/format-recipe-result.XXXXXX)"
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE"

python3 - "$RECIPE_NAME" "$TMPFILE" <<'PYEOF'
import sys
import json

recipe_name = sys.argv[1]
tmpfile = sys.argv[2]

with open(tmpfile, 'r') as f:
    raw = f.read()

try:
    data = json.loads(raw)
except (json.JSONDecodeError, ValueError) as e:
    print("Invalid JSON input: " + str(e), file=sys.stderr)
    sys.exit(1)

exit_code = data.get('exit_code', 0)
transforms_applied = data.get('transforms_applied', 0)
files_changed = data.get('files_changed', [])
errors = data.get('errors', [])
degraded = data.get('degraded', False)
engine_name = data.get('engine_name', 'unknown')

# Determine status
if degraded:
    status = 'DEGRADED'
elif exit_code != 0:
    status = 'FAILED'
else:
    status = 'SUCCESS'

# Files list
if files_changed:
    files_str = ', '.join(files_changed)
else:
    files_str = 'none'

print("Recipe task completed: {} ({})".format(recipe_name, engine_name))
print("Status: {}".format(status))
print("Files changed: {}".format(files_str))
print("Transforms applied: {}".format(transforms_applied))

if status == 'FAILED':
    if errors:
        print("Errors: " + "; ".join(errors))
    print("Pre-recipe git stash snapshot preserved — run git stash pop to revert")

if status == 'DEGRADED':
    print("Note: engine fell back to degraded mode ({})".format(engine_name))
    if errors:
        print("Errors: " + "; ".join(errors))
PYEOF
