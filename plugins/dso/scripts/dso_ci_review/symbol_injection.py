"""dso_ci_review.symbol_injection — deterministic cross-chunk symbol injection.

Component #2 of the chunked-review FP-reduction proposal. M-1 measurement: a
cross-chunk hallucinated-reference is 55% of chunked-review false positives —
the reviewer flags a symbol/test/script as "not visible in diff" / "HAS NO TEST
COVERAGE" when it provably exists in ANOTHER chunk it cannot see. Component #3'
reduces how OFTEN we chunk (raised gate); #2 is the tail-case lever: for
genuinely-large PRs that STILL chunk above the raised gate, inject the
cross-chunk symbol DEFINITIONS into each chunk's reviewer context so the
reviewer stops hallucinating "missing" references.

This is a pure-deterministic preprocessing step — NO LLM. For each chunk C it
(a) extracts the identifiers C *references* but does not *define*, (b) locates a
single unambiguous definition of each in the SIBLING chunks, and (c) renders a
read-only "Definitions referenced in other chunks of this PR" appendix that the
caller attaches to C's reviewer context (NOT the diff under review).

## Why this is its own module (G-3, no cross-consumer coupling)

The W6 check ``check-dangling-references.sh`` extracts the SAME class of symbol
(``.py`` def/class, ``.sh`` function defs). But the two consumers have OPPOSITE
error tolerances:

  - W6 wants high RECALL — a missed definition is a false-negative on a blocking
    gate (a dangling reference slips through).
  - #2 wants high PRECISION — a WRONG injected definition can make a reviewer
    DISMISS a real finding (e.g. an arity-mismatch), suppressing a true positive.

A shared regex tuned for one tolerance is a footgun for the other. Per the
proposal's G-3, this module implements its OWN Python extractor and does NOT
shell out to ``check-dangling-references.sh``. The def/class/function regexes
below are *deliberately copied* (not imported) from that script's ``_defs_for``
helper so the two can diverge independently; see the inline cross-reference
comments on each pattern.

## Guards (all three are non-negotiable per the proposal)

  - **G-1 uniqueness + extractor-confidence.** Inject a definition ONLY when the
    symbol has a SINGLE, UNAMBIGUOUS definition across the searched scope AND the
    extractor handles that language precisely (``.py`` / ``.sh``). Ambiguity
    (>=2 candidate defs) OR low confidence (any other language/construct) →
    inject NOTHING for that symbol.
  - **G-2 bounded appendix.** The injected appendix has a deterministic byte
    budget with truncate-toward-OMISSION: whole definitions are dropped, never
    truncated mid-definition. So #2 can NEVER push a chunk over the model
    context limit.
  - **G-3 no cross-consumer coupling.** See above — own extractor, no shell-out.
"""

from __future__ import annotations

import re
from collections import defaultdict
from typing import NamedTuple

from dso_ci_review._config import read_config_bool, read_config_int

# ---------------------------------------------------------------------------
# Config keys / defaults
# ---------------------------------------------------------------------------
#
#   review.region_split.symbol_injection         (default true)  — master on/off
#   review.region_split.symbol_injection_budget  (default 8000)  — appendix byte cap (G-2)
#
# The byte budget (G-2) is deliberately small relative to the model context
# window: #2 only runs on chunks that exist *because* the diff was already
# large, so the appendix must never be the straw that overflows the chunk.
_SYMBOL_INJECTION_ENABLED_DEFAULT = True
_SYMBOL_INJECTION_BUDGET_DEFAULT = 8000

# Languages the extractor handles PRECISELY (G-1 confidence floor). Any other
# extension is treated as low-confidence and contributes neither definitions
# nor reference-resolution targets.
_PRECISE_LANGS: frozenset[str] = frozenset({"py", "sh"})

_APPENDIX_HEADER = "Definitions referenced in other chunks of this PR"


def symbol_injection_enabled(config_path: str | None = None) -> bool:
    """Whether cross-chunk symbol injection is enabled (default True).

    Config key: ``review.region_split.symbol_injection``.
    """
    return read_config_bool(
        "review.region_split.symbol_injection",
        _SYMBOL_INJECTION_ENABLED_DEFAULT,
        config_path,
    )


def _injection_budget_bytes(config_path: str | None = None) -> int:
    """Resolved appendix byte budget (G-2; default 8000).

    Values <= 0 from config (which would disable the appendix entirely, or
    invert the truncation math) fall back to the default.
    """
    value = read_config_int(
        "review.region_split.symbol_injection_budget",
        _SYMBOL_INJECTION_BUDGET_DEFAULT,
        config_path,
    )
    return value if value > 0 else _SYMBOL_INJECTION_BUDGET_DEFAULT


# ---------------------------------------------------------------------------
# Diff parsing — recover per-file ADDED-side ("+") content from a unified diff
# ---------------------------------------------------------------------------


def _lang_of(path: str) -> str:
    """Return the precise-language tag for a path, or "" when low-confidence.

    Mirrors ``check-dangling-references.sh::_lang_of`` BY DESIGN (G-3 copy, not
    import): only ``.py`` and ``.sh`` are precise; everything else is "" so
    G-1's confidence floor drops it.
    """
    if path.endswith(".py"):
        return "py"
    if path.endswith(".sh"):
        return "sh"
    return ""


def _added_content_by_file(diff_text: str) -> dict[str, list[str]]:
    """Map each touched file → its NEW-side (post-image) content lines.

    Reconstructs the post-image from a unified diff by keeping context lines
    (leading space) and added lines (leading ``+``), dropping removed lines
    (leading ``-``) and all hunk/diff headers. This is the body the reviewer
    actually sees for that file in its chunk, so symbols are extracted from the
    same text the reviewer reads.

    A single file may appear under multiple ``diff --git`` sections; entries
    accumulate in first-seen order.
    """
    result: dict[str, list[str]] = defaultdict(list)
    current: str | None = None

    for line in diff_text.splitlines():
        m = re.match(r"^diff --git a/(\S+) b/\S+", line)
        if m:
            current = m.group(1)
            continue
        # +++ b/PATH refines the current file (handles pure-add / rename cases).
        m = re.match(r"^\+\+\+ b/(\S+)", line)
        if m:
            path = m.group(1)
            if path != "/dev/null":
                current = path
            continue
        if line.startswith("--- ") or line.startswith("@@"):
            continue
        if current is None:
            continue
        if line.startswith("+"):
            result[current].append(line[1:])
        elif line.startswith("-"):
            continue  # removed (old-side) — not in the post-image
        elif line.startswith(" "):
            result[current].append(line[1:])
        # any other line (e.g. "\\ No newline at end of file") is ignored
    return dict(result)


# ---------------------------------------------------------------------------
# Symbol-definition extraction (G-1 precise languages only; G-3 own regexes)
# ---------------------------------------------------------------------------


class SymbolDef(NamedTuple):
    """A single extracted definition.

    name: the defined identifier.
    file: the path it was defined in.
    text: the verbatim definition block (signature + indented body for .py;
          the function block for .sh) used as the injected snippet.
    """

    name: str
    file: str
    text: str


# G-3 cross-reference: these two patterns are copied from
# check-dangling-references.sh::_defs_for (the `py` and `sh` cases). They are
# COPIED, not imported, so #2 (precision) and W6 (recall) can diverge. Keep the
# anchors strict here — a loose def regex is a precision hazard for #2.
#
#   .py — `def NAME` / `class NAME` at the start of a (possibly indented) line.
_PY_DEF_RE = re.compile(r"^([ \t]*)(?:async[ \t]+)?(def|class)[ \t]+([A-Za-z_][A-Za-z0-9_]*)")
#   .sh — `name() {` or `function name`. (`[A-Za-z0-9_-]` matches dashes, as
#   shell function names may contain them — same char class as the W6 script.)
_SH_DEF_RE = re.compile(
    r"^[ \t]*(?:function[ \t]+)?([A-Za-z_][A-Za-z0-9_-]*)[ \t]*\(\)[ \t]*\{?"
)
_SH_DEF_FUNCTION_KW_RE = re.compile(
    r"^[ \t]*function[ \t]+([A-Za-z_][A-Za-z0-9_-]*)[ \t]*(?:\(\))?[ \t]*\{?"
)

# Identifier token used for the REFERENCE scan.
_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _extract_py_defs(file: str, lines: list[str]) -> list[SymbolDef]:
    """Extract top-of-line ``def``/``class`` definitions from Python content.

    The captured ``text`` is the signature line plus the contiguous block of
    more-indented (body) lines — enough for a reviewer to confirm arity and
    shape. Definitions are emitted in source order.
    """
    defs: list[SymbolDef] = []
    n = len(lines)
    i = 0
    while i < n:
        m = _PY_DEF_RE.match(lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1).expandtabs())
        name = m.group(3)
        block = [lines[i]]
        j = i + 1
        while j < n:
            nxt = lines[j]
            if nxt.strip() == "":
                block.append(nxt)
                j += 1
                continue
            nxt_indent = len(nxt) - len(nxt.lstrip(" \t"))
            # expandtabs for a stable indent comparison
            nxt_indent = len(nxt[:nxt_indent].expandtabs())
            if nxt_indent > indent:
                block.append(nxt)
                j += 1
            else:
                break
        # Trim trailing blank lines from the captured block.
        while block and block[-1].strip() == "":
            block.pop()
        defs.append(SymbolDef(name=name, file=file, text="\n".join(block)))
        i = j
    return defs


def _extract_sh_defs(file: str, lines: list[str]) -> list[SymbolDef]:
    """Extract shell function definitions (``name() {`` / ``function name``).

    The captured ``text`` is the signature line plus the lines up to (and
    including) the first line that is exactly ``}`` at column 0 — a best-effort
    function body. When no closing brace is found, only the signature line is
    captured (still useful: it confirms the function EXISTS).
    """
    defs: list[SymbolDef] = []
    n = len(lines)
    i = 0
    while i < n:
        line = lines[i]
        m = _SH_DEF_RE.match(line)
        if m:
            name = m.group(1)
        else:
            m2 = _SH_DEF_FUNCTION_KW_RE.match(line)
            if not m2:
                i += 1
                continue
            name = m2.group(1)
        block = [line]
        j = i + 1
        closed = False
        while j < n:
            block.append(lines[j])
            if lines[j].rstrip() == "}":
                closed = True
                j += 1
                break
            j += 1
        if not closed:
            block = [line]  # signature only — body undelimited
            j = i + 1
        defs.append(SymbolDef(name=name, file=file, text="\n".join(block)))
        i = j
    return defs


def _extract_defs_for_chunk(added_by_file: dict[str, list[str]]) -> list[SymbolDef]:
    """Extract all PRECISE-language definitions from one chunk's added content.

    Low-confidence files (G-1) contribute no definitions.
    """
    out: list[SymbolDef] = []
    for file, lines in added_by_file.items():
        lang = _lang_of(file)
        if lang == "py":
            out.extend(_extract_py_defs(file, lines))
        elif lang == "sh":
            out.extend(_extract_sh_defs(file, lines))
        # else: low-confidence — skip (G-1)
    return out


def _referenced_identifiers(added_by_file: dict[str, list[str]]) -> set[str]:
    """Collect identifiers REFERENCED across a chunk's precise-language files.

    Only precise-language files are scanned (G-1) so we never resolve a
    reference we couldn't reliably attribute. Returns the raw identifier set;
    the caller subtracts the chunk's own definitions to get
    references-but-not-defined.
    """
    refs: set[str] = set()
    for file, lines in added_by_file.items():
        if _lang_of(file) == "":
            continue
        for line in lines:
            for tok in _IDENT_RE.findall(line):
                refs.add(tok)
    return refs


# ---------------------------------------------------------------------------
# Appendix assembly (G-1 uniqueness + G-2 budget)
# ---------------------------------------------------------------------------


def _render_snippet(sym: SymbolDef) -> str:
    """Render one definition as a fenced, attributed snippet."""
    return f"### `{sym.name}` (defined in `{sym.file}`)\n```\n{sym.text}\n```"


def build_appendix_for_chunk(
    chunk_index: int,
    specs: list[dict],
    *,
    budget_bytes: int,
) -> str | None:
    """Build the cross-chunk definitions appendix for ``specs[chunk_index]``.

    For the target chunk:
      1. Extract its references-but-not-defined identifiers (precise langs only).
      2. For each such identifier, collect candidate definitions from the OTHER
         (sibling) chunks.
      3. G-1: inject ONLY when there is exactly ONE candidate definition across
         all siblings AND its text is unique. >=2 distinct candidate defs (by
         name) → ambiguous → inject nothing for that symbol.
      4. G-2: append rendered snippets until the byte budget is reached; drop
         whole snippets that would overflow (never truncate mid-definition).

    Returns the appendix string (including the header), or ``None`` when there
    is nothing safe to inject.
    """
    target = specs[chunk_index]
    target_added = _added_content_by_file(target.get("diff", ""))
    target_defs = _extract_defs_for_chunk(target_added)
    target_defined_names = {d.name for d in target_defs}
    target_refs = _referenced_identifiers(target_added)
    needed = target_refs - target_defined_names
    if not needed:
        return None

    # Build sibling definition index: name -> list[SymbolDef] across OTHER chunks.
    sibling_defs: dict[str, list[SymbolDef]] = defaultdict(list)
    for idx, spec in enumerate(specs):
        if idx == chunk_index:
            continue
        sib_added = _added_content_by_file(spec.get("diff", ""))
        for d in _extract_defs_for_chunk(sib_added):
            sibling_defs[d.name].append(d)

    # G-1: select unambiguous, unique definitions for needed-but-not-defined
    # identifiers. Deterministic order: by symbol name.
    selected: list[SymbolDef] = []
    for name in sorted(needed):
        candidates = sibling_defs.get(name)
        if not candidates:
            continue
        # Distinct definition texts — if a symbol is defined identically in two
        # siblings that is still ambiguous about WHICH chunk owns it, but the
        # injected text would be the same; treat >=2 DISTINCT candidate defs as
        # ambiguous (inject nothing). Multiple identical-text candidates are also
        # ambiguous (>=2 defining sites) per the proposal's "defined in 2 sibling
        # chunks" example — so any count != 1 is dropped.
        if len(candidates) != 1:
            continue  # ambiguous: >=2 candidate defs → inject NOTHING (G-1)
        selected.append(candidates[0])

    if not selected:
        return None

    # G-2: bounded appendix with truncate-toward-OMISSION. Accumulate whole
    # snippets; once the next snippet would exceed the budget, stop (drop it and
    # all remaining — never split a definition). The header counts toward the
    # budget so the TOTAL appendix is bounded.
    header = (
        f"## {_APPENDIX_HEADER}\n\n"
        "The following symbols are referenced in this chunk and DEFINED in other "
        "chunks of the same PR (not visible in your diff). They are provided "
        "READ-ONLY for context — do NOT review them; do NOT treat them as missing "
        "or untested.\n"
    )
    parts: list[str] = [header]
    used = len(header.encode("utf-8"))
    omitted = 0
    for sym in selected:
        snippet = "\n" + _render_snippet(sym) + "\n"
        snippet_bytes = len(snippet.encode("utf-8"))
        if used + snippet_bytes > budget_bytes:
            omitted += 1
            continue
        parts.append(snippet)
        used += snippet_bytes

    if len(parts) == 1:
        # Even the first snippet did not fit under budget — nothing injected.
        return None
    if omitted:
        note = (
            f"\n_({omitted} further cross-chunk definition(s) omitted to stay "
            "within the context budget.)_\n"
        )
        if used + len(note.encode("utf-8")) <= budget_bytes:
            parts.append(note)
    return "".join(parts)


def annotate_specs_with_symbol_injection(
    specs: list[dict],
    *,
    config_path: str | None = None,
) -> list[dict]:
    """Attach a cross-chunk symbol-injection appendix to each spec, in place.

    For each spec, sets ``spec["symbol_injection_context"]`` to the appendix
    string (or leaves it unset / None when nothing safe to inject). The diff
    under review (``spec["diff"]``) is NEVER mutated — the appendix is read-only
    reviewer context the dispatch layer carries via ``review_context``.

    Off-by-default-safe: when the feature is disabled by config, specs are
    returned unchanged. Returns the same list for caller convenience.
    """
    if not symbol_injection_enabled(config_path):
        return specs
    budget = _injection_budget_bytes(config_path)
    for idx in range(len(specs)):
        appendix = build_appendix_for_chunk(idx, specs, budget_bytes=budget)
        if appendix:
            specs[idx]["symbol_injection_context"] = appendix
    return specs
