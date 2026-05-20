#!/usr/bin/env bash
# audit-closure-checks-source-consumers.sh
# Source-file consumer audit for the `## Closure Checks` schema.
#
# Scans `.md`, `.sh`, `.py`, `.yaml`, `.yml` files under `plugins/`, `tests/`,
# and `docs/` in the host project for references to the Closure Checks schema
# (section headings, aliases, variable interpolations, static imports, and
# dynamic loads) and classifies each match into one of six precedence-ordered
# buckets. Used by SC4 + SC5 of epic a03c-d55e-1393-4f27 to plan and verify
# the bulk source-side migration.
#
# Usage:
#   audit-closure-checks-source-consumers.sh [--target <host-project-root>]
#
# Flags:
#   --target <path>     Path to the host project root (default: git rev-parse --show-toplevel)
#
# Output:
#   * Stdout — newline-separated relative paths of files with at least one
#     match, plus a `RECONCILIATION_INCOMPLETE` block if the reconciliation
#     loop fails to converge within 5 iterations.
#   * JSON artifact at
#         <target>/<plugin-git-path>/.audit-output/closure-checks-migration-<timestamp>.json
#     where <plugin-git-path> is the repo-relative path to this plugin
#     (typically "plugins" + "/" + "dso"). The schema is documented in DD5
#     of story 7e2c-2f4c-cd95-4e60.
#
# Exit codes:
#   0 — Audit complete, reconciliation converged
#   1 — Audit complete, reconciliation did NOT converge (incomplete)
#   2 — Error (no target, target not a directory, etc.)
#
# ── Test-only fixture hook (.audit-mutator) ─────────────────────────────────
# When `<target>/.audit-mutator` exists and contains the literal token
# `inject-on-pass`, the reconciliation loop creates one synthetic in-scope
# fixture file at the START of every pass after the first. This drives the
# `test_reconciliation_max_5_iterations` test toward the 5-iteration cap.
# Outside of tests this file should never be present, and absent the marker
# the audit is fully read-only.

set -euo pipefail

# ── Self-location ────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Derive the repo-relative plugin path so we do not embed the literal
# plugin self-reference string in source (see check-plugin-self-ref.sh).
_PLUGIN_ROOT="${_SCRIPT_DIR%/scripts*}"
if _PLUGIN_REPO_ROOT="$(git -C "$_PLUGIN_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
    _PLUGIN_GIT_PATH="${_PLUGIN_ROOT#"$_PLUGIN_REPO_ROOT"/}"
else
    _PLUGIN_GIT_PATH="$(basename "$(dirname "$_PLUGIN_ROOT")")/$(basename "$_PLUGIN_ROOT")"
fi

# ── Parse arguments ──────────────────────────────────────────────────────────
_TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            if [ $# -lt 2 ]; then echo "Error: --target requires a value" >&2; exit 2; fi
            _TARGET="$2"
            shift 2
            ;;
        --target=*)
            _TARGET="${1#--target=}"
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

# Resolve target (default: git rev-parse --show-toplevel from script context)
if [ -z "$_TARGET" ]; then
    _TARGET="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "Error: no --target supplied and not inside a git repository" >&2
        exit 2
    }
fi

if [ ! -d "$_TARGET" ]; then
    echo "Error: target '$_TARGET' is not a directory" >&2
    exit 2
fi

# Resolve to absolute, canonical path so relative-path computation is stable.
_TARGET="$(cd "$_TARGET" && pwd)"

# ── Output artifact location ─────────────────────────────────────────────────
# Compose <target>/<plugin-git-path>/.audit-output without a literal embed.
_OUTPUT_DIR="$_TARGET/${_PLUGIN_GIT_PATH}/.audit-output"
mkdir -p "$_OUTPUT_DIR"

# Timestamp with sub-second uniqueness so two runs within the same second do
# not collide (test 10 sleeps 1s, but we still guard against same-second).
_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Append nanoseconds (or fallback to PID) so back-to-back runs differ.
_NANO=""
if date +%N >/dev/null 2>&1 && [ "$(date +%N)" != "N" ]; then
    _NANO="$(date +%N | head -c 6)"
fi
if [ -z "$_NANO" ]; then
    _NANO="$$$RANDOM"
fi
_OUTPUT_JSON="$_OUTPUT_DIR/closure-checks-migration-${_TIMESTAMP}-${_NANO}.json"

# Ensure uniqueness (paranoid retry if a collision somehow occurs).
while [ -e "$_OUTPUT_JSON" ]; do
    _NANO="${_NANO}x$RANDOM"
    _OUTPUT_JSON="$_OUTPUT_DIR/closure-checks-migration-${_TIMESTAMP}-${_NANO}.json"
done

# ── Run audit + reconciliation via embedded Python ───────────────────────────
# The Python helper does the heavy lifting:
#   * file enumeration (.md/.sh/.py/.yaml/.yml under plugins/, tests/, docs/)
#   * pattern sweep (section regex, aliases, variable interpolation hints,
#                    static imports, dynamic loads)
#   * six-bucket classification with precedence
#   * reconciliation loop (up to 5 passes, mtime-baseline aware)
#   * `.audit-mutator` test hook invocation
#   * JSON artifact emission
_python_exit=0
python3 - "$_TARGET" "$_OUTPUT_JSON" <<'PYEOF' || _python_exit=$?
import datetime
import json
import os
import re
import sys
import time
import uuid

TARGET = sys.argv[1]
OUTPUT_JSON = sys.argv[2]

# ── Configuration ────────────────────────────────────────────────────────────
SCAN_ROOTS = ("plugins", "tests", "docs")
SCAN_EXTS = (".md", ".sh", ".py", ".yaml", ".yml")
MAX_RECONCILIATION_ITERATIONS = 5

# Known schema-consumer files referenced by `file-path-reference` bucket.
KNOWN_SCHEMA_FILES = (
    "migrate-closure-checks.sh",
    "audit-closure-checks-migration.sh",
    "coherence-walk.sh",
    "end-state-item-validator.md",
    "audit-closure-checks-source-consumers.sh",
    "apply-bucket-recipes.sh",
)

# Bucket precedence — most-specific first.
BUCKET_ORDER = (
    "migration-in-progress",
    "test-asserting-on-structure",
    "semantic-consumer",
    "user-facing-copy",
    "section-name-reference",
    "file-path-reference",
)

# ── Compiled patterns ────────────────────────────────────────────────────────
# DD2(c): section-name regex with whitespace tolerance (one-or-more between
# `##` and `Closure`, and between `Closure` and `Checks`).
RE_SECTION = re.compile(r"##\s+Closure\s+Checks\b")

# DD2(a): variable interpolation hints — any literal `Closure Checks`
# substring that isn't already part of the section heading we caught above.
# This is intentionally broad: shell var assignments, YAML values, Python
# string literals, and f-string interpolations all surface here.
RE_CLOSURE_CHECKS_LITERAL = re.compile(r"\bClosure\s+Checks\b")
RE_PY_FSTRING = re.compile(r'f["\'][^"\']*Closure\s+Checks[^"\']*["\']')
RE_SHELL_VAR_ASSIGN = re.compile(r"""[A-Z_][A-Z0-9_]*=['"][^'"]*Closure\s+Checks[^'"]*['"]""")

# DD2(b): aliases.
RE_ALIAS_CHK = re.compile(r"\bclosure-chk\b")
RE_ALIAS_CC = re.compile(r"\bcc-items\b")

# DD3 — static imports.
# Python: `import X`, `from X import Y` where X mentions closure_checks.
RE_PY_IMPORT = re.compile(
    r"^\s*(?:from\s+([\w\.]*closure[\w_]*)\s+import\s+|import\s+([\w\.]*closure[\w_]*)\b)",
)
# Markdown link to a known schema-consumer file.
RE_MD_LINK = re.compile(r"\[[^\]]*\]\(([^)]*)\)")
# Shell `source <path>` — path may be literal or start with a single $VAR.
RE_SH_SOURCE = re.compile(r"""(?:^|\s|;|\|)\s*(?:source|\.)\s+("?)([^"\s|;<>&]+)\1""")

# DD3 — dynamic loads.
# importlib.import_module(arg) where arg is NOT a plain string literal.
# Examples flagged as dynamic:
#   importlib.import_module(name)
#   importlib.import_module(f"...")
#   importlib.import_module(prefix + "_checks")
# NOT flagged (static):
#   importlib.import_module("closure_checks")
RE_PY_IMPORT_MODULE = re.compile(r"importlib\.import_module\s*\(\s*([^)]*)\)")

# Shell compound-variable source: a `source` line whose path contains TWO or
# more `$VAR` segments (e.g. `source "$PLUGIN_ROOT/$VARIABLE"`).
# Single $VAR prefix with literal tail = static, multiple = dynamic.
RE_SH_DOLLAR_VAR = re.compile(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?")

# Assertion-like patterns on a single line (test-asserting-on-structure).
RE_ASSERTION = re.compile(
    r"\b(?:assert(?:_eq|_ne|_contains|_not_contains|_equal|_in|_match|s_in)?|"
    r"grep\b|expect\b|self\.assert|check\b|"
    r"shouldBe|toEqual|toContain)\b",
    re.IGNORECASE,
)

# Parser / generator / semantic-consumer keywords (proximity hint).
RE_SEMANTIC = re.compile(
    r"\b(?:re\.(?:search|match|findall|sub)|parses?|parser|parsing|"
    r"extract(?:s|ed|ing)?|generate(?:s|d|ing)?|"
    r"walks?|scan(?:s|ned|ning)?|tokeniz(?:e|er|ed)|"
    r"items\s+from|section\s+content|render(?:s|ed|ing)?)\b",
    re.IGNORECASE,
)

# User-facing copy heuristics: print/echo/log call OR markdown body prose.
RE_USER_FACING_CALL = re.compile(
    r"\b(?:print|echo|printf|logger?\.[a-z]+|logging\.[a-z]+|"
    r"sys\.std(?:out|err)\.write|console\.(?:log|info|warn|error)|"
    r"raise\s+\w+)\b",
    re.IGNORECASE,
)

# Markdown prose that is explicitly addressed to end users (error notices,
# inline instructions). Matched only on lines that aren't section headings.
RE_USER_FACING_PROSE = re.compile(
    r"^\s*(?:Error|Warning|Note|Tip|Caution|Important|Hint)\s*[:!]|"
    r"\b(?:missing\s+the|please\s+\w+|you\s+must|"
    r"add\s+a\s+|retry\b|fix\s+the\s+)\b",
    re.IGNORECASE,
)

# MIGRATION-IN-PROGRESS marker (file-level).
RE_MIGRATION_MARKER = re.compile(r"MIGRATION[-_]IN[-_]PROGRESS")


# ── Helpers ──────────────────────────────────────────────────────────────────
def in_scope(path):
    """True if `path` (relative to target) is under a scan root with a
    supported extension."""
    if not any(path.startswith(root + os.sep) for root in SCAN_ROOTS):
        return False
    return path.endswith(SCAN_EXTS)


def enumerate_in_scope_files(target):
    """Yield absolute paths to in-scope files under target."""
    for root_name in SCAN_ROOTS:
        root = os.path.join(target, root_name)
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            # Skip the audit-output directory in case it shadows in-scope files.
            dirnames[:] = [d for d in dirnames if d != ".audit-output"]
            for fn in filenames:
                if fn.endswith(SCAN_EXTS):
                    yield os.path.join(dirpath, fn)


def relpath(p, target):
    return os.path.relpath(p, target)


def file_has_migration_marker(content, filename):
    """File-level migration-in-progress detection."""
    if "migrate" in os.path.basename(filename).lower():
        return True
    return bool(RE_MIGRATION_MARKER.search(content))


def is_dynamic_import_arg(arg):
    """Decide whether the argument to `importlib.import_module(...)` is a
    dynamic (non-literal) value.

    Static: a single string literal — e.g. `"closure_checks"`, `'closure_checks'`.
    Dynamic: bare identifier, f-string, concatenation, function call, etc.
    """
    s = arg.strip()
    if not s:
        return False
    # f-string prefix → dynamic.
    if s.startswith(("f'", 'f"', "F'", 'F"', "rf'", 'rf"', "fr'", 'fr"')):
        return True
    # Plain string literal (and nothing else) → static.
    if (s.startswith('"') and s.endswith('"') and s.count('"') == 2) or \
       (s.startswith("'") and s.endswith("'") and s.count("'") == 2):
        return False
    return True


def is_dynamic_source_path(path_token):
    """Decide whether a `source <path>` token is dynamic.

    Dynamic if any of:
      * the path contains TWO OR MORE `$VAR` segments
      * the path is a bare variable with no literal trailing segment
        (e.g. `"$SOME_VAR"`, `$VAR`, `"${VAR}"`) — runtime alone determines
        the load target, so a static scan cannot reach the consumer.
    Static if the path contains zero or one `$VAR` followed by a literal
    trailing segment (e.g. `"$PLUGIN_ROOT/scripts/foo.sh"`).
    """
    var_count = len(RE_SH_DOLLAR_VAR.findall(path_token))
    if var_count >= 2:
        return True
    if var_count == 1:
        # Check if there is a literal trailing segment after the variable.
        # Strip surrounding quotes for the check.
        stripped = path_token.strip()
        if (stripped.startswith('"') and stripped.endswith('"')) or \
           (stripped.startswith("'") and stripped.endswith("'")):
            stripped = stripped[1:-1]
        # Remove a single leading $VAR or ${VAR} token; if nothing remains
        # (or only whitespace), the path is dynamic.
        residue = RE_SH_DOLLAR_VAR.sub("", stripped, count=1).strip()
        if not residue:
            return True
    return False


def classify_match(file_rel, line, match_kind, match_text, file_has_marker):
    """Return one of BUCKET_ORDER values, or None for unbucketed."""
    # 1. migration-in-progress (file-level).
    if file_has_marker:
        return "migration-in-progress"

    # 2. test-asserting-on-structure.
    if file_rel.startswith("tests" + os.sep) and RE_ASSERTION.search(line):
        return "test-asserting-on-structure"

    # 3. semantic-consumer.
    if RE_SEMANTIC.search(line):
        return "semantic-consumer"

    # 4. user-facing-copy — explicit user-facing signal required (not just
    #    "is in a markdown file"). Heuristics:
    #      * inside a print/echo/log/error call (RE_USER_FACING_CALL), OR
    #      * markdown prose with an explicit user-facing prefix
    #        ("Error:", "Warning:", "Note:", "Add", "Run", "missing the",
    #        instruction-style imperatives — captured by RE_USER_FACING_PROSE).
    is_user_call = bool(RE_USER_FACING_CALL.search(line))
    is_user_prose = (
        file_rel.endswith(".md")
        and not line.lstrip().startswith("#")
        and bool(RE_USER_FACING_PROSE.search(line))
    )
    if is_user_call or is_user_prose:
        return "user-facing-copy"

    # 5. section-name-reference — literal heading line.
    if match_kind == "section" and line.lstrip().startswith("##"):
        return "section-name-reference"

    # 6. file-path-reference — match text or line mentions a known schema-consumer file.
    if match_kind == "known-file-mention" or \
       any(known in match_text or known in line for known in KNOWN_SCHEMA_FILES):
        return "file-path-reference"

    return None


def detect_matches_in_file(file_abs, file_rel, content):
    """Yield (line_no, match_kind, match_text, dynamic_load) for every match
    in the file."""
    file_has_marker = file_has_migration_marker(content, file_rel)
    for lineno, line in enumerate(content.splitlines(), start=1):
        # 1. Section name regex.
        for m in RE_SECTION.finditer(line):
            yield (lineno, "section", m.group(0), False, file_has_marker, line)

        # 2. Variable interpolation hints — but only for occurrences that are
        #    NOT a section heading we already emitted above. We capture every
        #    `Closure Checks` literal that isn't preceded by `##`.
        section_spans = [(m.start(), m.end()) for m in RE_SECTION.finditer(line)]
        for m in RE_CLOSURE_CHECKS_LITERAL.finditer(line):
            # Skip if this literal is part of an already-emitted section match.
            if any(s <= m.start() < e for s, e in section_spans):
                continue
            yield (lineno, "literal", m.group(0), False, file_has_marker, line)

        # 3. Aliases.
        for m in RE_ALIAS_CHK.finditer(line):
            yield (lineno, "alias-chk", m.group(0), False, file_has_marker, line)
        for m in RE_ALIAS_CC.finditer(line):
            yield (lineno, "alias-cc", m.group(0), False, file_has_marker, line)

        # 4. Python imports of closure_checks-style modules.
        m = RE_PY_IMPORT.search(line)
        if m:
            module = m.group(1) or m.group(2) or ""
            yield (lineno, "py-import", module, False, file_has_marker, line)

        # 5. importlib.import_module(...) — distinguish static vs dynamic.
        for m in RE_PY_IMPORT_MODULE.finditer(line):
            arg = m.group(1) or ""
            dyn = is_dynamic_import_arg(arg)
            yield (lineno, "py-import-module", m.group(0), dyn, file_has_marker, line)

        # 6. Markdown links to known schema-consumer files.
        if file_rel.endswith(".md"):
            for m in RE_MD_LINK.finditer(line):
                href = m.group(1)
                if any(known in href for known in KNOWN_SCHEMA_FILES):
                    yield (lineno, "md-link", href, False, file_has_marker, line)

        # 7. Shell `source <path>` — capture every source statement.
        if file_rel.endswith(".sh") or file_rel.endswith(".bash"):
            for m in RE_SH_SOURCE.finditer(line):
                path_token = m.group(2)
                if any(known in path_token for known in KNOWN_SCHEMA_FILES) or \
                   "closure" in path_token.lower() or \
                   path_token.startswith("$") or path_token.startswith('"$'):
                    dyn = is_dynamic_source_path(path_token)
                    yield (lineno, "sh-source", path_token, dyn, file_has_marker, line)

        # 8. Generic mention of a known schema-consumer filename.
        #    Surfaces file-path-reference candidates (e.g. doc prose that names
        #    the migration script without a markdown link or import statement).
        for known in KNOWN_SCHEMA_FILES:
            if known in line:
                yield (lineno, "known-file-mention", known, False, file_has_marker, line)


def run_pass(target, mtime_baseline):
    """Run a single classification pass.

    `mtime_baseline` is a dict {abs_path: mtime}. On the first pass it is
    empty and ALL in-scope files are scanned. On subsequent passes, only
    files whose mtime exceeds the baseline (or that are absent from the
    baseline entirely — i.e. new files) are scanned.

    Returns:
      pass_results: dict {
        "files_scanned": [abs_paths...],
        "bucket_flags": [(bucket, file_rel, lineno, match_text, dyn)...],
        "unbucketed":   [(file_rel, lineno, match_text, reason)...],
        "removed":      [file_rel...],   # files in baseline but no longer present
      }
      new_mtime_map: dict {abs_path: mtime}  — current state, for next baseline
    """
    current = {}
    for f in enumerate_in_scope_files(target):
        try:
            current[f] = os.path.getmtime(f)
        except OSError:
            continue

    removed = []
    if mtime_baseline:
        for old in mtime_baseline:
            if old not in current:
                removed.append(relpath(old, target))

    # Decide which files to scan this pass.
    if not mtime_baseline:
        to_scan = list(current.keys())
    else:
        to_scan = []
        for f, mt in current.items():
            prev = mtime_baseline.get(f)
            if prev is None or mt > prev:
                to_scan.append(f)

    bucket_flags = []
    unbucketed = []

    for f in to_scan:
        rel = relpath(f, target)
        try:
            with open(f, "r", encoding="utf-8", errors="replace") as fh:
                content = fh.read()
        except OSError:
            continue

        for lineno, kind, match_text, dyn, file_has_marker, line in \
                detect_matches_in_file(f, rel, content):
            bucket = classify_match(rel, line, kind, match_text, file_has_marker)
            if bucket is None:
                unbucketed.append((rel, lineno, match_text, "no-bucket-matched", dyn))
            else:
                bucket_flags.append((bucket, rel, lineno, match_text, dyn))

    return {
        "files_scanned": list(current.keys()),
        "bucket_flags": bucket_flags,
        "unbucketed": unbucketed,
        "removed": removed,
    }, current


def apply_mutator_hook(target, pass_index):
    """If `<target>/.audit-mutator` contains `inject-on-pass`, create a new
    synthetic in-scope fixture at the start of every pass after the first.

    Test-only hook — see header comment block.
    """
    mutator = os.path.join(target, ".audit-mutator")
    if not os.path.isfile(mutator):
        return
    try:
        with open(mutator, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read().strip()
    except OSError:
        return
    if "inject-on-pass" not in content:
        return
    # Inject a brand-new in-scope file each pass.
    inject_dir = os.path.join(target, "plugins", ".mutator-injected")
    os.makedirs(inject_dir, exist_ok=True)
    inject_path = os.path.join(inject_dir, f"inject-{pass_index}-{uuid.uuid4().hex[:8]}.md")
    with open(inject_path, "w", encoding="utf-8") as fh:
        fh.write(f"## Closure Checks\n\nInjected by mutator hook for pass {pass_index}\n")


# ── Run reconciliation loop ──────────────────────────────────────────────────
run_id = str(uuid.uuid4())
started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()

aggregated_bucket_flags = []
aggregated_unbucketed = []
removed_files = []
mtime_baseline = {}
reconciliation_iterations = 0
reconciliation_status = "complete"

# Track the set of bucket flag identities we've already emitted so that
# multi-pass scans do not double-count the same match.
seen_flag_keys = set()
seen_unbucketed_keys = set()


def _flag_key(bucket, rel, lineno, match_text):
    return (bucket, rel, lineno, match_text)


def _unb_key(rel, lineno, match_text, reason, dyn):
    return (rel, lineno, match_text, reason, bool(dyn))


for pass_idx in range(MAX_RECONCILIATION_ITERATIONS):
    reconciliation_iterations += 1

    # Apply mutator hook BEFORE the pass starts so this pass's mtime baseline
    # (captured inside run_pass) includes the new file.
    if pass_idx > 0:
        apply_mutator_hook(TARGET, pass_idx)

    pass_results, new_baseline = run_pass(TARGET, mtime_baseline)

    new_flag_count = 0
    for bucket, rel, lineno, match_text, dyn in pass_results["bucket_flags"]:
        key = _flag_key(bucket, rel, lineno, match_text)
        if key in seen_flag_keys:
            continue
        seen_flag_keys.add(key)
        aggregated_bucket_flags.append((bucket, rel, lineno, match_text, dyn))
        new_flag_count += 1

    new_unb_count = 0
    for rel, lineno, match_text, reason, dyn in pass_results["unbucketed"]:
        key = _unb_key(rel, lineno, match_text, reason, dyn)
        if key in seen_unbucketed_keys:
            continue
        seen_unbucketed_keys.add(key)
        aggregated_unbucketed.append((rel, lineno, match_text, reason, dyn))
        new_unb_count += 1

    for removed in pass_results["removed"]:
        if removed not in removed_files:
            removed_files.append(removed)

    mtime_baseline = new_baseline

    # Convergence check (DD6): zero new bucket flags AND zero unbucketed delta.
    if pass_idx > 0 and new_flag_count == 0 and new_unb_count == 0:
        reconciliation_status = "complete"
        break
else:
    # Loop fell through without `break` — we ran MAX_RECONCILIATION_ITERATIONS
    # passes and never converged.
    reconciliation_status = "incomplete"

# ── Total file-count across the FINAL pass's file set ────────────────────────
file_count_scanned = len(mtime_baseline)

# ── Group bucket flags by bucket name ────────────────────────────────────────
buckets = {name: [] for name in BUCKET_ORDER}
dynamic_load_count = 0
for bucket, rel, lineno, match_text, dyn in aggregated_bucket_flags:
    item = {
        "file": rel,
        "line": lineno,
        "match_text": match_text,
        "dynamic_load": bool(dyn),
    }
    buckets[bucket].append(item)
    if dyn:
        dynamic_load_count += 1

# Include dynamic-load count from unbucketed matches too (if any tagged).
unbucketed_matches = []
for rel, lineno, match_text, reason, dyn in aggregated_unbucketed:
    item = {
        "file": rel,
        "line": lineno,
        "match_text": match_text,
        "reason": reason,
        "dynamic_load": bool(dyn),
    }
    if dyn:
        dynamic_load_count += 1
    unbucketed_matches.append(item)

completed_at = datetime.datetime.now(datetime.timezone.utc).isoformat()

envelope = {
    "schema_version": "1.0",
    "audit_run_id": run_id,
    "started_at": started_at,
    "completed_at": completed_at,
    "file_count_scanned": file_count_scanned,
    "buckets": buckets,
    "dynamic_load_count": dynamic_load_count,
    "unbucketed_matches": unbucketed_matches,
    "removed_files": removed_files,
    "reconciliation_status": reconciliation_status,
    "reconciliation_iterations": reconciliation_iterations,
}

with open(OUTPUT_JSON, "w", encoding="utf-8") as fh:
    json.dump(envelope, fh, indent=2, sort_keys=True)
    fh.write("\n")

# ── Stdout: enumerate files with matches + final markers ─────────────────────
files_with_matches = sorted({rel for _, rel, _, _, _ in aggregated_bucket_flags} |
                            {rel for rel, _, _, _, _ in aggregated_unbucketed})
for rel in files_with_matches:
    print(rel)

if reconciliation_status == "incomplete":
    print("")
    print("RECONCILIATION_INCOMPLETE")
    print(f"  iterations: {reconciliation_iterations}")
    print(f"  total bucket flags: {len(aggregated_bucket_flags)}")
    print(f"  total unbucketed:   {len(aggregated_unbucketed)}")
    sys.exit(1)

sys.exit(0)
PYEOF

# ── Propagate Python exit code ───────────────────────────────────────────────
# Python emits:
#   0 — reconciliation converged
#   1 — reconciliation incomplete (5-iteration cap)
#   other — runtime error (propagate as 2)
if [ "$_python_exit" -eq 0 ] || [ "$_python_exit" -eq 1 ]; then
    exit "$_python_exit"
fi
exit 2
