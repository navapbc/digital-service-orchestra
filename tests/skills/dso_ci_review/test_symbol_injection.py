"""Behavioral tests for component #2 — deterministic cross-chunk symbol injection.

M-1 measurement: a cross-chunk hallucinated-reference is 55% of chunked-review
false positives — the reviewer flags a symbol/test as "not visible in diff" /
"HAS NO TEST COVERAGE" when it provably exists in ANOTHER chunk it can't see.
Component #2 injects, into chunk C's reviewer context, the DEFINITIONS of
symbols C references but does not define, located in C's SIBLING chunks.

These tests assert OBSERVABLE behavior of the assembled appendix — given two
chunks where chunk B references a symbol defined in chunk A, the context built
for chunk B contains chunk A's definition; given ambiguity, it does not; given
overflow, it is bounded. No source-grepping / change-detector assertions.

Guards under test (proposal G-1/G-2/G-3):
  G-1 uniqueness + extractor-confidence: an ambiguous symbol (defined in 2
      sibling chunks) injects nothing; a unique symbol injects its one
      definition; a low-confidence language injects nothing.
  G-2 bounded appendix: with many cross-chunk symbols the appendix is capped
      and drops whole definitions rather than overflowing or splitting one.
  G-3 no cross-consumer coupling: the extractor is pure-Python (this module
      imports no shell consumer); covered structurally by G-1/G-2 behavior plus
      test_symbol_injection_no_shell_coupling.
"""

from __future__ import annotations

import pathlib
import sys

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review import symbol_injection as si  # noqa: E402


# ---------------------------------------------------------------------------
# Diff builders — produce per-file unified-diff sections for a chunk
# ---------------------------------------------------------------------------


def _file_diff(path: str, added_lines: list[str]) -> str:
    """Build a single-file unified diff section adding ``added_lines``."""
    out = [
        f"diff --git a/{path} b/{path}",
        "--- a/" + path,
        "+++ b/" + path,
        f"@@ -0,0 +1,{len(added_lines)} @@",
    ]
    out.extend("+" + ln for ln in added_lines)
    return "\n".join(out)


def _spec(cluster_dir: str, path: str, added_lines: list[str]) -> dict:
    return {
        "cluster_dir": cluster_dir,
        "files": [path],
        "diff": _file_diff(path, added_lines),
        "oversized_single_file": False,
    }


# ---------------------------------------------------------------------------
# Core behavior — a unique sibling definition is injected into the referencing
# chunk's context
# ---------------------------------------------------------------------------


def test_unique_sibling_definition_is_injected_into_referencing_chunk() -> None:
    """Given: chunk A defines ``helper_alpha`` and chunk B references it (but does
             not define it).
    When:  the appendix for chunk B is built.
    Then:  it contains chunk A's definition text for ``helper_alpha`` — so the
           reviewer of B no longer hallucinates a missing reference.
    """
    chunk_a = _spec(
        "src/a",
        "src/a/mod.py",
        ["def helper_alpha(x, y):", "    return x + y"],
    )
    chunk_b = _spec(
        "src/b",
        "src/b/caller.py",
        ["def run():", "    return helper_alpha(1, 2)"],
    )
    specs = [chunk_a, chunk_b]

    appendix = si.build_appendix_for_chunk(1, specs, budget_bytes=100_000)

    assert appendix is not None, "chunk B references a sibling-defined symbol"
    assert "helper_alpha" in appendix
    assert "def helper_alpha(x, y):" in appendix, (
        "the sibling's actual definition text must be injected so the reviewer "
        "can confirm the symbol exists and its arity"
    )
    assert "src/a/mod.py" in appendix, "the definition must be attributed to its file"


def test_no_appendix_when_chunk_references_nothing_cross_chunk() -> None:
    """Given: a chunk whose references are all locally defined.
    When:  its appendix is built.
    Then:  None — nothing to inject (additive, no spurious context).
    """
    chunk_a = _spec(
        "src/a",
        "src/a/mod.py",
        ["def helper_alpha(x, y):", "    return x + y"],
    )
    chunk_b = _spec(
        "src/b",
        "src/b/self.py",
        ["def local(z):", "    return z * 2", "", "def use():", "    return local(3)"],
    )
    specs = [chunk_a, chunk_b]

    # chunk B references only `local` (defined in B) — nothing cross-chunk.
    appendix = si.build_appendix_for_chunk(1, specs, budget_bytes=100_000)
    assert appendix is None


# ---------------------------------------------------------------------------
# G-1 — uniqueness + extractor confidence
# ---------------------------------------------------------------------------


def test_g1_ambiguous_symbol_defined_in_two_siblings_injects_nothing() -> None:
    """Given: ``shared_fn`` is defined in TWO sibling chunks (A and C), and chunk
             B references it.
    When:  the appendix for chunk B is built.
    Then:  ``shared_fn`` is NOT injected (>=2 candidate defs → ambiguous → inject
           nothing). A wrong injected definition could make the reviewer DISMISS
           a real arity-mismatch finding — so ambiguity must inject nothing.
    """
    chunk_a = _spec(
        "src/a",
        "src/a/one.py",
        ["def shared_fn(a):", "    return a"],
    )
    chunk_c = _spec(
        "src/c",
        "src/c/two.py",
        ["def shared_fn(a, b):", "    return a + b"],
    )
    chunk_b = _spec(
        "src/b",
        "src/b/caller.py",
        ["def run():", "    return shared_fn(1)"],
    )
    specs = [chunk_a, chunk_b, chunk_c]

    appendix = si.build_appendix_for_chunk(1, specs, budget_bytes=100_000)
    assert appendix is None or "shared_fn" not in appendix, (
        "an ambiguous symbol (defined in 2 sibling chunks) must inject NOTHING"
    )


def test_g1_unique_symbol_injected_when_ambiguous_sibling_also_present() -> None:
    """Same scene as the ambiguity test, but chunk B ALSO references a uniquely
    defined ``unique_fn`` (defined only in chunk A).

    Then: the unique symbol IS injected even though a sibling ambiguity exists
          for a DIFFERENT symbol — G-1 is per-symbol, not all-or-nothing.
    """
    chunk_a = _spec(
        "src/a",
        "src/a/one.py",
        [
            "def shared_fn(a):",
            "    return a",
            "",
            "def unique_fn(p):",
            "    return p - 1",
        ],
    )
    chunk_c = _spec(
        "src/c",
        "src/c/two.py",
        ["def shared_fn(a, b):", "    return a + b"],
    )
    chunk_b = _spec(
        "src/b",
        "src/b/caller.py",
        ["def run():", "    return shared_fn(1) + unique_fn(2)"],
    )
    specs = [chunk_a, chunk_b, chunk_c]

    appendix = si.build_appendix_for_chunk(1, specs, budget_bytes=100_000)
    assert appendix is not None
    assert "unique_fn" in appendix, "the uniquely-defined symbol must be injected"
    assert "shared_fn" not in appendix, (
        "the ambiguous symbol must still be omitted (per-symbol G-1)"
    )


def test_g1_low_confidence_language_injects_nothing() -> None:
    """Given: a symbol referenced in chunk B is 'defined' in a sibling chunk's
             low-confidence-language file (e.g. .rb), which the extractor does
             not parse precisely.
    When:  the appendix for chunk B is built.
    Then:  nothing is injected for it — the extractor only treats .py/.sh as
           high-confidence (G-1 confidence floor).
    """
    chunk_a = _spec(
        "src/a",
        "src/a/thing.rb",
        ["def ruby_helper(x)", "  x * 2", "end"],
    )
    chunk_b = _spec(
        "src/b",
        "src/b/caller.py",
        ["def run():", "    return ruby_helper(3)"],
    )
    specs = [chunk_a, chunk_b]

    appendix = si.build_appendix_for_chunk(1, specs, budget_bytes=100_000)
    assert appendix is None or "ruby_helper" not in appendix, (
        "a definition in a low-confidence language must not be injected"
    )


def test_shell_function_definition_is_injected() -> None:
    """The extractor handles .sh function defs precisely: a shell function
    defined in a sibling chunk and referenced in another is injected.
    """
    chunk_a = _spec(
        "scripts",
        "scripts/lib.sh",
        ["my_shell_helper() {", '    echo "hi"', "}"],
    )
    chunk_b = _spec(
        "bin",
        "bin/run.sh",
        ["main() {", "    my_shell_helper", "}"],
    )
    specs = [chunk_a, chunk_b]

    appendix = si.build_appendix_for_chunk(1, specs, budget_bytes=100_000)
    assert appendix is not None
    assert "my_shell_helper" in appendix
    assert "scripts/lib.sh" in appendix


# ---------------------------------------------------------------------------
# G-2 — bounded appendix (truncate toward omission, never mid-definition)
# ---------------------------------------------------------------------------


def test_g2_appendix_bounded_and_drops_extras_under_tight_budget() -> None:
    """Given: chunk B references MANY symbols, each uniquely defined in a sibling
             chunk, and a tight byte budget.
    When:  the appendix for chunk B is built.
    Then:  the appendix is <= the budget AND it drops whole definitions rather
           than overflowing — so #2 can never push a chunk over the context
           limit.
    """
    n = 50
    # Each sibling defines one helper with a sizeable body.
    sibling_specs = []
    body = ["    pass  # padding line to make each definition large" for _ in range(8)]
    for i in range(n):
        sibling_specs.append(
            _spec(
                f"src/s{i}",
                f"src/s{i}/m.py",
                [f"def helper_{i}(a):", *body],
            )
        )
    caller_lines = ["def run():"]
    caller_lines += [f"    helper_{i}(0)" for i in range(n)]
    chunk_b = _spec("src/caller", "src/caller/c.py", caller_lines)

    specs = [chunk_b, *sibling_specs]
    budget = 1500
    appendix = si.build_appendix_for_chunk(0, specs, budget_bytes=budget)

    assert appendix is not None, "at least some definitions should fit"
    assert len(appendix.encode("utf-8")) <= budget, (
        f"appendix must stay within the {budget}-byte budget; "
        f"got {len(appendix.encode('utf-8'))}"
    )
    # Truncate-toward-omission: at least one whole helper must have been dropped
    # (n definitions cannot all fit in 1500 bytes).
    present = sum(1 for i in range(n) if f"helper_{i}(a):" in appendix)
    assert present < n, "tight budget must drop some whole definitions"
    assert present >= 1, "but at least one whole definition should be present"


def test_g2_no_definition_is_truncated_mid_block() -> None:
    """Every definition that appears in the appendix appears in FULL (its body is
    not cut off) — truncation drops whole snippets, never splits one.
    """
    # Two sibling defs of known full text; a budget that fits exactly one + header.
    chunk_a = _spec(
        "src/a",
        "src/a/m.py",
        ["def alpha(x):", "    return x", "    # end alpha marker"],
    )
    chunk_c = _spec(
        "src/c",
        "src/c/n.py",
        ["def beta(y):", "    return y", "    # end beta marker"],
    )
    chunk_b = _spec(
        "src/b",
        "src/b/c.py",
        ["def run():", "    return alpha(1) + beta(2)"],
    )
    specs = [chunk_a, chunk_b, chunk_c]

    # Pick a budget that admits only one of the two definitions.
    full = si.build_appendix_for_chunk(1, specs, budget_bytes=100_000)
    assert full is not None
    one_def_budget = len(si._render_snippet(
        si.SymbolDef("alpha", "src/a/m.py", "def alpha(x):\n    return x\n    # end alpha marker")
    ).encode("utf-8")) + 400

    appendix = si.build_appendix_for_chunk(1, specs, budget_bytes=one_def_budget)
    assert appendix is not None
    # Whichever definition appears, its end-marker comment must appear too
    # (i.e. the block was not cut off mid-body).
    if "def alpha(x):" in appendix:
        assert "# end alpha marker" in appendix, "alpha must appear in full"
    if "def beta(y):" in appendix:
        assert "# end beta marker" in appendix, "beta must appear in full"


# ---------------------------------------------------------------------------
# G-3 — no cross-consumer coupling (own extractor; no shell-out)
# ---------------------------------------------------------------------------


def test_symbol_injection_no_shell_coupling(monkeypatch) -> None:
    """The injector must NOT shell out (e.g. to check-dangling-references.sh).

    We poison subprocess execution: if the injector tried to run any external
    process, the call would raise. Building an appendix must succeed regardless,
    proving the extraction is in-process pure-Python (G-3).
    """
    import subprocess

    def _boom(*args, **kwargs):  # noqa: ANN002, ANN003
        raise AssertionError("symbol_injection must not shell out (G-3)")

    monkeypatch.setattr(subprocess, "run", _boom)
    monkeypatch.setattr(subprocess, "Popen", _boom)
    monkeypatch.setattr(subprocess, "check_output", _boom)

    chunk_a = _spec("src/a", "src/a/m.py", ["def f(x):", "    return x"])
    chunk_b = _spec("src/b", "src/b/c.py", ["def g():", "    return f(1)"])
    appendix = si.build_appendix_for_chunk(1, [chunk_a, chunk_b], budget_bytes=100_000)
    assert appendix is not None and "def f(x):" in appendix


# ---------------------------------------------------------------------------
# Additivity / config gate
# ---------------------------------------------------------------------------


def test_annotate_specs_is_additive_does_not_mutate_diff() -> None:
    """``annotate_specs_with_symbol_injection`` only sets a new key; it must NOT
    alter spec['diff'] or spec['files'] (preserving OVER_BOUND/budget math).
    """
    chunk_a = _spec("src/a", "src/a/m.py", ["def f(x):", "    return x"])
    chunk_b = _spec("src/b", "src/b/c.py", ["def g():", "    return f(1)"])
    specs = [chunk_a, chunk_b]
    orig_diffs = [s["diff"] for s in specs]
    orig_files = [list(s["files"]) for s in specs]

    si.annotate_specs_with_symbol_injection(specs)

    assert [s["diff"] for s in specs] == orig_diffs, "diff must be untouched"
    assert [s["files"] for s in specs] == orig_files, "files must be untouched"
    # chunk B got an injection context (references f defined in A).
    assert specs[1].get("symbol_injection_context"), (
        "chunk B should be annotated with the cross-chunk appendix"
    )


def test_disabled_by_config_injects_nothing(tmp_path, monkeypatch) -> None:
    """When review.region_split.symbol_injection=false, no spec is annotated."""
    from dso_ci_review import _config as cfg_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.region_split.symbol_injection=false\n")
    monkeypatch.setattr(cfg_mod, "default_config_path", lambda: str(config_file))

    chunk_a = _spec("src/a", "src/a/m.py", ["def f(x):", "    return x"])
    chunk_b = _spec("src/b", "src/b/c.py", ["def g():", "    return f(1)"])
    specs = [chunk_a, chunk_b]

    si.annotate_specs_with_symbol_injection(specs)
    assert all("symbol_injection_context" not in s for s in specs), (
        "feature disabled by config must annotate nothing"
    )


def test_enabled_by_default() -> None:
    """The feature is on by default (off-by-default-safe means SAFE-additive,
    not disabled): with no config, enabled() returns True.
    """
    # Use a nonexistent config path so the default is exercised.
    assert si.symbol_injection_enabled(config_path="/nonexistent/dso-config.conf") is True
