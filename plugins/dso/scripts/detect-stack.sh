#!/usr/bin/env bash
set -uo pipefail
# scripts/detect-stack.sh
# Auto-detect the project type by inspecting marker files in the given directory.
#
# Usage: detect-stack.sh [project-dir]
#   [project-dir]: optional path to scan; defaults to $(pwd)
#
# Output (stdout): one of:
#   python-poetry    — pyproject.toml (non-empty, with [tool.poetry], [build-system], or [project]) found
#   rust-cargo       — Cargo.toml (non-empty) found
#   golang           — go.mod (non-empty) found
#   node-npm         — package.json (valid JSON) found
#   convention-based — Makefile with at least 2 of: test:, lint:, format: targets
#   unknown          — none of the above markers found
#
# Detection priority (first match wins):
#   1. python-poetry  (pyproject.toml) — takes priority over node-npm
#   2. rust-cargo     (Cargo.toml)     — takes priority over golang
#   3. golang         (go.mod)
#   4. node-npm       (package.json)
#   5. convention-based (Makefile with ≥2 standard targets)
#   6. unknown
#
# Multi-marker handling:
#   Python (pyproject.toml) takes priority over Node (package.json) because many
#   Python projects include package.json for frontend tooling.
#   Rust (Cargo.toml) takes priority over Go (go.mod) as Cargo.toml is unambiguous.
#
# Exit codes:
#   0 — always (detection always succeeds, falling through to 'unknown')

set -uo pipefail

# ── Argument parsing ───────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    PROJECT_DIR="$1"
else
    PROJECT_DIR="$(pwd)"
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: not a directory: $PROJECT_DIR" >&2
    exit 1
fi

# ── Detection logic (priority order — first match wins) ────────────────────────

# 1. python-poetry: pyproject.toml present AND non-empty AND contains a recognized section
#    Takes priority over node-npm (package.json) — many Python projects include
#    package.json for frontend tooling. pyproject.toml is the definitive Python marker.
#    CoVe: file must be non-empty and contain [tool.poetry], [build-system], or [project].
if [[ -f "$PROJECT_DIR/pyproject.toml" ]]; then
    if test -s "$PROJECT_DIR/pyproject.toml" && \
       grep -qE '^\[(tool\.poetry|build-system|project)\]' "$PROJECT_DIR/pyproject.toml"; then
        echo "python-poetry"
        exit 0
    fi
fi

# 2. rust-cargo: Cargo.toml present AND non-empty
#    CoVe: file must be non-empty.
if [[ -f "$PROJECT_DIR/Cargo.toml" ]]; then
    if test -s "$PROJECT_DIR/Cargo.toml"; then
        echo "rust-cargo"
        exit 0
    fi
fi

# 3. golang: go.mod present AND non-empty
#    CoVe: file must be non-empty.
if [[ -f "$PROJECT_DIR/go.mod" ]]; then
    if test -s "$PROJECT_DIR/go.mod"; then
        echo "golang"
        exit 0
    fi
fi

# 4. node-npm: package.json present AND valid JSON
#    CoVe: file must be parseable as JSON.
if [[ -f "$PROJECT_DIR/package.json" ]]; then
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PROJECT_DIR/package.json" 2>/dev/null; then
        echo "node-npm"
        exit 0
    fi
fi

# 5. convention-based: Makefile with at least 2 of: test:, lint:, format: targets
if [[ -f "$PROJECT_DIR/Makefile" ]]; then
    target_count=0
    if grep -q "^test:" "$PROJECT_DIR/Makefile"; then
        target_count=$(( target_count + 1 ))
    fi
    if grep -q "^lint:" "$PROJECT_DIR/Makefile"; then
        target_count=$(( target_count + 1 ))
    fi
    if grep -q "^format:" "$PROJECT_DIR/Makefile"; then
        target_count=$(( target_count + 1 ))
    fi
    if [[ "$target_count" -ge 2 ]]; then
        echo "convention-based"
        exit 0
    fi
fi

# 6. unknown: no recognized markers found
echo "unknown"
exit 0
