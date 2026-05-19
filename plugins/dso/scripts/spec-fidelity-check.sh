#!/usr/bin/env bash
# spec-fidelity-check.sh
# Spec-fidelity check: verify PIL criteria against story done definitions.
#
# Usage:
#   spec-fidelity-check.sh --pil-json=<path> --story-dds=<path>
#
# Arguments:
#   --pil-json=<path>   Path to a JSON file with:
#                         {"criteria": ["criterion text 1", "criterion text 2", ...]}
#   --story-dds=<path>  Path to a text file with one done-definition per line
#
# Exit codes:
#   0   All PIL criteria have at least one matching DD line (≥80% word overlap)
#   1   At least one PIL criterion has NO matching DD; JSON error emitted on stderr:
#         {"type":"drop","pil_text":"<criterion>","dd_matches":[]}
#
# Near-match rule: a PIL criterion is considered matched by a DD line when
# ≥80% of the criterion's words appear in the DD line (case-insensitive,
# punctuation stripped).
#
# Enrichment: DD lines with no PIL source are permitted (exits 0 for those).
#
# Requires: bash 4+, python3 (stdlib only)

set -uo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────

PIL_JSON=""
STORY_DDS=""

for arg in "$@"; do
    case "$arg" in
        --pil-json=*)  PIL_JSON="${arg#--pil-json=}" ;;
        --story-dds=*) STORY_DDS="${arg#--story-dds=}" ;;
        *)
            printf '{"error":"unknown argument","arg":"%s"}\n' "$arg" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$PIL_JSON" ]]; then
    printf '{"error":"missing required argument","arg":"--pil-json"}\n' >&2
    exit 2
fi

if [[ -z "$STORY_DDS" ]]; then
    printf '{"error":"missing required argument","arg":"--story-dds"}\n' >&2
    exit 2
fi

if [[ ! -f "$PIL_JSON" ]]; then
    printf '{"error":"file not found","path":"%s"}\n' "$PIL_JSON" >&2
    exit 2
fi

if [[ ! -f "$STORY_DDS" ]]; then
    printf '{"error":"file not found","path":"%s"}\n' "$STORY_DDS" >&2
    exit 2
fi

# ── Core logic via python3 (word-overlap computation) ─────────────────────────

python3 - "$PIL_JSON" "$STORY_DDS" <<'PYEOF'
import sys
import json
import re

def normalize(text):
    """Lowercase, strip punctuation, return list of words."""
    text = text.lower()
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return [w for w in text.split() if w]

def word_overlap_ratio(criterion_words, dd_words):
    """Fraction of criterion words that appear in dd_words (set membership)."""
    if not criterion_words:
        return 1.0
    dd_set = set(dd_words)
    matched = sum(1 for w in criterion_words if w in dd_set)
    return matched / len(criterion_words)

THRESHOLD = 0.80

pil_json_path = sys.argv[1]
story_dds_path = sys.argv[2]

# Load PIL criteria
with open(pil_json_path, "r", encoding="utf-8") as f:
    pil_data = json.load(f)

criteria = pil_data.get("criteria", [])

# Load story DDs (one per line, skip blank lines)
with open(story_dds_path, "r", encoding="utf-8") as f:
    dds = [line.rstrip("\n") for line in f if line.strip()]

# Precompute DD word lists
dd_word_lists = [normalize(dd) for dd in dds]

# Check each PIL criterion
any_fail = False
for criterion in criteria:
    criterion_words = normalize(criterion)
    matched = False
    for dd_words in dd_word_lists:
        ratio = word_overlap_ratio(criterion_words, dd_words)
        if ratio >= THRESHOLD:
            matched = True
            break
    if not matched:
        any_fail = True
        error = {
            "type": "drop",
            "pil_text": criterion,
            "dd_matches": []
        }
        print(json.dumps(error), file=sys.stderr)

sys.exit(1 if any_fail else 0)
PYEOF
