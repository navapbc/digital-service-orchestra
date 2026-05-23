"""Structural test: every Jira mutation call in applier.py is preceded by snapshot_head() call.

This is a fitness-function / AST-scan test — it parses applier.py with stdlib `ast`
and asserts the drift-check invariant without executing any code.

Invariant
---------
In the `apply()` function body (the main mutation dispatcher), the `snapshot_head`
call must appear before any dispatch to mutation helpers (`create_one`, `update_one`,
`delete_one`) and before any direct Jira mutation calls (`create_issue`, `update_issue`,
`transition_issue`).

In the helper functions (`create_one`, `update_one`, `delete_one`) the direct Jira
mutation calls are allowed without a local `snapshot_head` — they delegate drift
detection to the caller (`apply()`).  The test verifies this by checking the top-level
`apply()` entry point rather than each individual helper.
"""
from __future__ import annotations

import ast
import textwrap
from pathlib import Path

APPLIER_PATH = Path(__file__).parents[1] / "applier.py"

# Names that represent Jira mutation dispatch at the apply() level
MUTATION_DISPATCH_CALLS = {"create_one", "update_one", "delete_one"}

# Names that represent direct Jira REST mutations (used in helper functions)
JIRA_MUTATION_CALLS = {"create_issue", "update_issue", "transition_issue"}

# The drift-check sentinel
HEAD_CHECK_ATTR = "snapshot_head"


# ---------------------------------------------------------------------------
# AST helpers
# ---------------------------------------------------------------------------

def _collect_call_names(stmts: list[ast.stmt]) -> list[str]:
    """Walk stmts in linear order, returning a list of call attribute/name strings.

    Each element is either:
    - A bare function name (``ast.Name.id``) for plain calls, or
    - The attribute portion (``ast.Attribute.attr``) for attribute calls.

    Order reflects the order in which call nodes appear in a linear traversal
    of the statement list (depth-first per statement, statements in order).
    """
    names: list[str] = []
    for stmt in stmts:
        for node in ast.walk(stmt):
            if isinstance(node, ast.Call):
                fn = node.func
                if isinstance(fn, ast.Name):
                    names.append(fn.id)
                elif isinstance(fn, ast.Attribute):
                    names.append(fn.attr)
    return names


def _get_function_bodies(source: str) -> dict[str, list[ast.stmt]]:
    """Return {function_name: [statements]} for all functions in source."""
    tree = ast.parse(source)
    functions: dict[str, list[ast.stmt]] = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            functions[node.name] = node.body
    return functions


def _head_check_precedes_mutations(
    stmts: list[ast.stmt],
    mutation_names: set[str],
    head_check_attr: str = HEAD_CHECK_ATTR,
) -> tuple[bool, str]:
    """Check that head_check_attr appears before any call in mutation_names.

    Returns (ok, offender) where ok=True means invariant satisfied (or no
    mutation calls present), and offender names the first violating call when
    ok=False.
    """
    call_sequence = _collect_call_names(stmts)
    head_seen = False
    for name in call_sequence:
        if name == head_check_attr:
            head_seen = True
        if name in mutation_names:
            if not head_seen:
                return False, name
    return True, ""


# ---------------------------------------------------------------------------
# Tests against the real applier.py
# ---------------------------------------------------------------------------

def test_applier_py_exists() -> None:
    """applier.py must exist at the expected path (sanity guard)."""
    assert APPLIER_PATH.exists(), f"applier.py not found at {APPLIER_PATH}"


def test_apply_function_has_head_check_before_mutation_dispatch() -> None:
    """apply() in applier.py: snapshot_head() must appear before create_one/update_one/delete_one."""
    source = APPLIER_PATH.read_text()
    funcs = _get_function_bodies(source)

    assert "apply" in funcs, "apply() function not found in applier.py"

    ok, offender = _head_check_precedes_mutations(funcs["apply"], MUTATION_DISPATCH_CALLS)
    assert ok, (
        f"Drift-check invariant violated in apply(): "
        f"{offender!r} called before snapshot_head(). "
        f"Every mutation dispatch must be preceded by a snapshot_head() re-check."
    )


def test_apply_function_calls_snapshot_head() -> None:
    """apply() must reference snapshot_head at all (not just have it before mutations)."""
    source = APPLIER_PATH.read_text()
    funcs = _get_function_bodies(source)

    assert "apply" in funcs, "apply() function not found in applier.py"

    call_names = _collect_call_names(funcs["apply"])
    assert HEAD_CHECK_ATTR in call_names, (
        f"apply() does not call snapshot_head() at all — drift detection is missing entirely."
    )


# ---------------------------------------------------------------------------
# Synthetic fixture tests (verify the detector works correctly)
# ---------------------------------------------------------------------------

def test_synthetic_fixture_without_drift_check_fails() -> None:
    """Detector correctly identifies a function calling create_one without snapshot_head."""
    synthetic = textwrap.dedent("""\
    def apply_without_check(mutations, client):
        for m in mutations:
            create_one(m, client)  # no snapshot_head() before this!
    """)
    funcs = _get_function_bodies(synthetic)
    body = funcs["apply_without_check"]
    ok, offender = _head_check_precedes_mutations(body, MUTATION_DISPATCH_CALLS)
    assert not ok, (
        "Detector should flag apply_without_check as violating the drift-check invariant, "
        "but reported it as compliant."
    )
    assert offender == "create_one"


def test_synthetic_fixture_with_drift_check_passes() -> None:
    """Detector correctly accepts a function that calls snapshot_head before create_one."""
    synthetic = textwrap.dedent("""\
    def apply_with_check(mutations, concurrency, repo_root):
        head_pin = concurrency.snapshot_head(repo_root)
        for m in mutations:
            current = concurrency.snapshot_head(repo_root)
            create_one(m, client)
    """)
    funcs = _get_function_bodies(synthetic)
    body = funcs["apply_with_check"]
    ok, offender = _head_check_precedes_mutations(body, MUTATION_DISPATCH_CALLS)
    assert ok, (
        f"Detector incorrectly flagged apply_with_check (offender={offender!r}); "
        f"snapshot_head() was present before create_one()."
    )


def test_synthetic_fixture_direct_jira_call_without_head_check_fails() -> None:
    """Detector also flags direct Jira mutation calls (create_issue) without snapshot_head."""
    synthetic = textwrap.dedent("""\
    def apply_direct(mutations, client):
        for m in mutations:
            client.create_issue(m)  # no snapshot_head() before this!
    """)
    funcs = _get_function_bodies(synthetic)
    body = funcs["apply_direct"]
    ok, offender = _head_check_precedes_mutations(body, JIRA_MUTATION_CALLS)
    assert not ok, (
        "Detector should flag apply_direct as violating the drift-check invariant, "
        "but reported it as compliant."
    )
    assert offender == "create_issue"
