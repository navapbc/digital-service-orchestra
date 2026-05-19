#!/usr/bin/env bash
# bug-classification-audit.sh — Validate the bug classification registry.
#
# Usage:
#   bug-classification-audit.sh [<registry-file>]
#   bug-classification-audit.sh --verify-registry [<registry-file>]
#
# When no registry file is given, defaults to:
#   ${CLAUDE_PLUGIN_ROOT}/docs/bug-classification-registry.json
#
# Env vars:
#   REGISTRY_FILE   — fallback path if no positional arg given
#   CLAUDE_PLUGIN_ROOT — overrides default plugin root resolution
#   PROJECT_ROOT / REPO_ROOT — overrides git-based repo root resolution
#
# Validation steps (in order):
#   1. File existence
#   2. JSON parse
#   3. Count check (entries array must have 27 items matching total field)
#   4. Required fields present and non-empty per entry
#   5. primary_defense_layer enum check
#   6. slug kebab-case format check
#   7. applies_to_project_classes enum check
#   8. defense_artifact_ref path resolution (repo:, plugin:, absolute:)
#
# Exit 0 on success, exit 1 on any validation failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
# Always resolve intra-plugin paths from the script location so they work
# correctly in worktree sessions where CLAUDE_PLUGIN_ROOT may point at the
# main repo rather than the worktree copy.
_PLUGIN_ROOT="$SCRIPT_DIR/.."
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"

# ── Argument parsing ──────────────────────────────────────────────────────────

# Check for --check-tags mode (mutually exclusive with --verify-registry)
CHECK_TAGS_MODE=0
args=()
for arg in "$@"; do
    if [[ "$arg" == "--check-tags" ]]; then
        CHECK_TAGS_MODE=1
    elif [[ "$arg" != "--verify-registry" ]]; then
        args+=("$arg")
    fi
done

# ── --check-tags mode ─────────────────────────────────────────────────────────
if [[ "$CHECK_TAGS_MODE" -eq 1 ]]; then
    REGISTRY_FILE="${REGISTRY_FILE:-${_PLUGIN_ROOT}/docs/bug-classification-registry.json}"
    TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"

    python3 - "$REGISTRY_FILE" "$TICKET_CMD" <<'PYEOF'
import json
import subprocess
import sys

registry_path = sys.argv[1]
ticket_cmd = sys.argv[2]

# Load known slugs from registry
with open(registry_path) as f:
    data = json.load(f)
known_slugs = {entry["slug"] for entry in data.get("entries", [])}

# Fetch closed tickets via ticket command
result = subprocess.run(
    [ticket_cmd, "list", "--status=closed"],
    capture_output=True,
    text=True,
)
tickets = json.loads(result.stdout)

# Validate bug-type-* tags
validated = 0
for ticket in tickets:
    for tag in ticket.get("tags", []):
        if tag.startswith("bug-type-"):
            slug = tag[len("bug-type-"):]
            # System-generated tags: uncategorized and classifier-failed-* are
            # always valid regardless of registry contents.
            if slug == "uncategorized" or slug.startswith("classifier-failed-"):
                validated += 1
                continue
            if slug not in known_slugs:
                msg = f"AUDIT FAIL: tag={tag} references unknown slug '{slug}'"
                print(msg)
                print(msg, file=sys.stderr)
                sys.exit(1)
            validated += 1

print(f"AUDIT PASS: {validated} in-use bug-type tags validated")
sys.exit(0)
PYEOF
    exit $?
fi

# Resolve registry file: positional arg > REGISTRY_FILE env > default
if [[ ${#args[@]} -gt 0 ]]; then
    REGISTRY_FILE="${args[0]}"
elif [[ -z "${REGISTRY_FILE:-}" ]]; then
    REGISTRY_FILE="${_PLUGIN_ROOT}/docs/bug-classification-registry.json"
fi

# ── Step 1: File existence ────────────────────────────────────────────────────
if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "AUDIT ERROR: registry file not found: $REGISTRY_FILE" >&2
    exit 1
fi

# ── Step 2: JSON parse ────────────────────────────────────────────────────────
if ! python3 -c "import json; json.load(open('$REGISTRY_FILE'))" 2>/dev/null; then
    echo "AUDIT ERROR: registry file is not valid JSON: $REGISTRY_FILE" >&2
    exit 1
fi

# ── Steps 3–8: All remaining validation via a single Python pass ──────────────
python3 - "$REGISTRY_FILE" "$REPO_ROOT" "$_PLUGIN_ROOT" <<'PYEOF'
import json
import os
import re
import sys

registry_path = sys.argv[1]
repo_root = sys.argv[2]
plugin_root = sys.argv[3]

with open(registry_path) as f:
    data = json.load(f)

# ── Step 3: Count check ───────────────────────────────────────────────────────
EXPECTED_COUNT = 27
entries = data.get("entries", [])
declared_total = data.get("total", None)
actual_count = len(entries)

if actual_count != EXPECTED_COUNT or declared_total != actual_count:
    print(
        f"AUDIT ERROR: count mismatch — "
        f"total field={declared_total}, entries count={actual_count}, expected={EXPECTED_COUNT}",
        file=sys.stderr,
    )
    sys.exit(1)

REQUIRED_FIELDS = [
    "slug",
    "classification_question",
    "primary_defense_layer",
    "defense_artifact_ref",
    "applies_to_project_classes",
]

ALLOWED_DEFENSE_LAYERS = {
    "planning_review",
    "prose_manifest_test",
    "code_review",
    "matrix_ci",
    "concurrency_test",
    "failure_path_test",
    "defense_manifest_test",
    "release_e2e",
    "operational_process",
}

ALLOWED_PROJECT_CLASSES = {"all", "agent_orchestration"}

KEBAB_RE = re.compile(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$')

errors = []

for i, entry in enumerate(entries):
    slug = entry.get("slug", "") or ""
    loc = f"entry[{i}] slug={slug!r}"

    # ── Step 4: Required fields ───────────────────────────────────────────────
    for field in REQUIRED_FIELDS:
        value = entry.get(field, "")
        if not value:
            errors.append(f"AUDIT FAIL: {loc} field={field} reason=missing or empty")

    # Skip further checks on this entry if required fields are absent
    if any(f"slug={slug!r}" in e and "field=" in e for e in errors):
        continue

    # ── Step 5: primary_defense_layer enum ───────────────────────────────────
    layer = entry.get("primary_defense_layer", "")
    if layer not in ALLOWED_DEFENSE_LAYERS:
        errors.append(
            f"AUDIT FAIL: slug={slug} field=primary_defense_layer "
            f"reason=invalid value: {layer!r}"
        )

    # ── Step 6: slug kebab-case format ────────────────────────────────────────
    if not KEBAB_RE.match(slug):
        errors.append(
            f"AUDIT FAIL: slug={slug} field=slug reason=not kebab-case"
        )

    # ── Step 7: applies_to_project_classes enum ───────────────────────────────
    project_class = entry.get("applies_to_project_classes", "")
    if project_class not in ALLOWED_PROJECT_CLASSES:
        errors.append(
            f"AUDIT FAIL: slug={slug} field=applies_to_project_classes "
            f"reason=invalid value: {project_class!r}"
        )

    # ── Step 8: defense_artifact_ref resolution ───────────────────────────────
    ref = entry.get("defense_artifact_ref", "")
    if ":" in ref:
        prefix, ref_path = ref.split(":", 1)
        if prefix == "repo":
            full_path = os.path.join(repo_root, ref_path)
        elif prefix == "plugin":
            full_path = os.path.join(plugin_root, ref_path)
        elif prefix == "absolute":
            full_path = ref_path
        else:
            errors.append(
                f"AUDIT FAIL: slug={slug} field=defense_artifact_ref "
                f"reason=unknown prefix: {prefix!r}"
            )
            full_path = None

        if full_path is not None and not os.path.exists(full_path):
            msg = (
                f"AUDIT FAIL: slug={slug} field=defense_artifact_ref "
                f"reason=path not found: {full_path}"
            )
            print(msg, file=sys.stderr)
            print(msg)
            sys.exit(1)
    else:
        errors.append(
            f"AUDIT FAIL: slug={slug} field=defense_artifact_ref "
            f"reason=missing prefix (expected repo:/plugin:/absolute:)"
        )

if errors:
    for err in errors:
        print(err, file=sys.stderr)
    sys.exit(1)

print(f"AUDIT PASS: {EXPECTED_COUNT} entries validated")
sys.exit(0)
PYEOF
