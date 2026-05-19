#!/usr/bin/env bash
# classify-epic-class.sh
# Reads epic ticket JSON from stdin (or --ticket-id flag) and outputs a
# machine-readable JSON classification of the epic's architectural class.
#
# Output format: {"class": "class:architectural|class:integration|class:infra|class:behavioral"}
#
# Priority: architectural > integration > infra > behavioral (default fallback)
#
# Input:
#   - stdin: epic ticket JSON (title + description are inspected)
#   - --ticket-id <id>: calls `dso ticket show <id>` and reads from stdout
#
# Exit code: always 0
#
# Prior art: ${CLAUDE_PLUGIN_ROOT}/scripts/brainstorm/classify-sc-shape.sh

# -e omitted: grep exit code drives the conditionals; -e would abort on grep non-zero no-match
set -uo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
TICKET_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ticket-id)
            TICKET_ID="$2"
            shift 2
            ;;
        --ticket-id=*)
            TICKET_ID="${1#--ticket-id=}"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ── Read epic JSON ────────────────────────────────────────────────────────────
if [[ -n "$TICKET_ID" ]]; then
    # Resolve REPO_ROOT from the script's location to find the dso shim
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _REPO_ROOT="$(cd "$_SCRIPT_DIR/../../.." && pwd)"
    epic_json=$("$_REPO_ROOT/.claude/scripts/dso" ticket show "$TICKET_ID" 2>/dev/null) || epic_json="{}"
else
    epic_json=$(cat)
fi

# ── Extract text corpus (title + description) ─────────────────────────────────
_PYEXTRACT='
import sys, json

raw = sys.stdin.read().strip()
if not raw:
    print("")
    sys.exit(0)

try:
    d = json.loads(raw)
except (json.JSONDecodeError, ValueError):
    print(raw)
    sys.exit(0)

parts = []
for key in ("title", "description", "summary", "body"):
    val = d.get(key, "")
    if isinstance(val, str) and val:
        parts.append(val)

print(" ".join(parts))
'
corpus=$(echo "$epic_json" | python3 -c "$_PYEXTRACT") || corpus=""

# ── Keyword classification (priority: architectural > integration > infra > behavioral) ──
_RESULT="class:behavioral"

# architectural: schema, migration, db/database, ADR, architecture, data model, entity, ORM
if echo "$corpus" | grep -Eiq \
    'schema|migration|database|\bdb\b|ADR|architecture|data model|entity|\bORM\b'; then
    _RESULT="class:architectural"

# integration: API, webhook, external service, third-party, oauth, connector, bridge, integration harness
elif echo "$corpus" | grep -Eiq \
    '\bAPI\b|webhook|external service|third.party|oauth|connector|bridge|integration harness'; then
    _RESULT="class:integration"

# infra: deploy, infrastructure, container, kubernetes, cluster, CI, pipeline, monitoring, observability
elif echo "$corpus" | grep -Eiq \
    'deploy|infrastructure|container|kubernetes|cluster|\bCI\b|pipeline|monitoring|observability'; then
    _RESULT="class:infra"

# behavioral (default): feature, skill, behavior, agent, workflow, prompt, UX, story
# (also the fallback — no explicit check needed; _RESULT already set to class:behavioral)
fi

# ── Output machine-readable JSON ──────────────────────────────────────────────
python3 -c "import json; print(json.dumps({'class': '$_RESULT'}))"
exit 0
