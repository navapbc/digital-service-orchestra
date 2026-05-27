"""Tests for dso_ci_review.dispatch.dispatch_schema_correction().

Behavioral contracts under test:
1. Correction dispatch returns schema-valid JSON with same finding count
   AND frozen fields preserved → CI proceeds with corrected findings.
2. Correction returns valid JSON but different finding count → append
   synthetic schema_error, treat as failed.
3. Correction returns valid JSON but one frozen field changed → append
   synthetic schema_error.
4. All retries exhausted → appends {"type": "parse_error", "severity":
   "important", ...} synthetic finding. (Severity is "important", not
   "critical": commit af07466226 / bug 5126-dc68 deliberately demoted the
   synthetic schema_error from critical→important so a pipeline-internal
   schema-correction failure is eligible for autonomous R5 resolution rather
   than hard-blocking the PR. See dispatch.py:_make_synthetic_error.)
5. max_attempts=0 → skips dispatch entirely, appends synthetic schema_error
   immediately.
6. Correction itself returns schema-invalid JSON → consumes one retry,
   no recursion.
7. (AC amendment) Corrected reviewer-findings.json hash still validates
   (frozen field: --reviewer-hash must still pass).

Frozen fields (byte-for-byte must be preserved):
  severity, category, description, file, cited_lines
  finding_id: frozen when original is valid (f-<hex8>); regeneration allowed when
  original is absent, empty, or malformed.

Synthetic error shape:
  {"type": "parse_error", "severity": "important", "category": "schema_error",
   "description": "...", "finding_id": "schema_error_...",
   "file": "", "cited_lines": [], "cited_excerpt": "", "reachability": ""}
"""

from __future__ import annotations

import copy
import hashlib
import json
import pathlib
import sys
from typing import Any

# Ensure the plugin scripts directory is on sys.path so that
# `dso_ci_review.dispatch` resolves to the plugin, not the test package.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.dispatch as _dispatch_mod  # noqa: E402
import dso_ci_review.runner as _runner_mod  # noqa: E402


# ---------------------------------------------------------------------------
# Shared test helpers
# ---------------------------------------------------------------------------

_DIFF_TEXT = "--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n"

# A well-formed finding with all frozen fields set.
_FINDING_A: dict[str, Any] = {
    "severity": "critical",
    "category": "correctness",
    "description": "Null pointer dereference in handler",
    "file": "src/handler.py",
    "cited_lines": ["src/handler.py:42", "src/handler.py:43"],
    "finding_id": "abc123",
    "cited_excerpt": "return obj.value",
    "reachability": "always",
}

_FINDING_B: dict[str, Any] = {
    "severity": "minor",
    "category": "style",
    "description": "Unnecessary trailing whitespace",
    "file": "src/utils.py",
    "cited_lines": ["src/utils.py:10"],
    "finding_id": "def456",
    "cited_excerpt": "    ",
    "reachability": "always",
}

_FROZEN_FIELDS = (
    "severity",
    "category",
    "description",
    "file",
    "cited_lines",
    "finding_id",
)


def _make_fake_response(findings: list[dict]) -> Any:
    """Construct a minimal fake litellm-response object containing the given findings."""
    content = json.dumps({"findings": findings})

    class _FakeMsg:
        pass

    class _FakeChoice:
        pass

    class _FakeResp:
        pass

    msg = _FakeMsg()
    msg.content = content  # type: ignore[attr-defined]
    choice = _FakeChoice()
    choice.message = msg  # type: ignore[attr-defined]
    resp = _FakeResp()
    resp.choices = [choice]  # type: ignore[attr-defined]
    return resp


def _schema_valid_corrected_findings(originals: list[dict]) -> list[dict]:
    """Return corrected findings that are schema-valid and preserve all frozen fields."""
    corrected = []
    for f in originals:
        new_f = copy.deepcopy(f)
        # Add or fix a non-frozen field to simulate a correction
        new_f["cited_excerpt"] = "corrected_excerpt"
        corrected.append(new_f)
    return corrected


def _stub_validate_schema_pass(merged: dict, **kwargs) -> Any:
    """Stub for _validate_findings_schema that always returns schema_pass."""
    return _runner_mod._SchemaValidationResult("schema_pass", [])


def _stub_validate_schema_fail(merged: dict, **kwargs) -> Any:
    """Stub for _validate_findings_schema that always returns schema_fail."""
    return _runner_mod._SchemaValidationResult(
        "schema_fail", ["missing required field: cited_lines"]
    )


# ---------------------------------------------------------------------------
# Scenario 1 — Successful correction preserves frozen fields; CI proceeds
# ---------------------------------------------------------------------------


def test_correction_success_returns_corrected_findings(monkeypatch) -> None:
    """Given: original findings with frozen fields set; correction dispatch returns
              schema-valid JSON with the same finding count AND all frozen fields
              byte-for-byte preserved.
    When: dispatch_schema_correction() is called with max_attempts=1.
    Then:
      - Returned findings list has the same length as the original.
      - Every frozen field in every finding matches the original exactly.
      - No synthetic schema_error finding is appended.
    """
    originals = [copy.deepcopy(_FINDING_A), copy.deepcopy(_FINDING_B)]
    corrected = _schema_valid_corrected_findings(originals)

    def _mock_dispatch_review(**kwargs):
        return {"findings": corrected}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)

    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    synthetic_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not synthetic_errors, (
        f"No synthetic schema_error should appear on successful correction, "
        f"got: {synthetic_errors}"
    )

    assert len(findings) == len(originals), (
        f"Corrected findings must have same count as originals "
        f"(got {len(findings)}, expected {len(originals)})"
    )

    for i, (orig, corrected_f) in enumerate(zip(originals, findings)):
        for field in _FROZEN_FIELDS:
            if field in orig:
                assert corrected_f.get(field) == orig[field], (
                    f"Frozen field {field!r} mutated at index {i}: "
                    f"original={orig[field]!r}, corrected={corrected_f.get(field)!r}"
                )


# ---------------------------------------------------------------------------
# Scenario 2 — Count drift routes to synthetic schema_error
# ---------------------------------------------------------------------------


def test_correction_count_drift_routes_to_synthetic_error(monkeypatch) -> None:
    """Given: original findings with 2 entries; correction dispatch returns valid
              JSON but with only 1 finding (count drift).
    When: dispatch_schema_correction() is called with max_attempts=1.
    Then:
      - A synthetic finding with category='schema_error' is appended.
      - The returned findings list contains the synthetic error entry.
    """
    originals = [copy.deepcopy(_FINDING_A), copy.deepcopy(_FINDING_B)]
    # Return only 1 finding — count drift
    drifted = [copy.deepcopy(_FINDING_A)]

    def _mock_dispatch_review(**kwargs):
        return {"findings": drifted}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)

    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert schema_errors, (
        f"Expected synthetic schema_error finding on count drift, got findings: {findings}"
    )
    error = schema_errors[0]
    assert error.get("type") == "parse_error", (
        f"Synthetic error type must be 'parse_error', got: {error.get('type')!r}"
    )
    assert error.get("severity") == "important", (
        f"Synthetic error severity must be 'important', got: {error.get('severity')!r}"
    )
    assert "file" in error, f"Synthetic error must include 'file' field: {error}"
    assert "cited_lines" in error, (
        f"Synthetic error must include 'cited_lines' field: {error}"
    )
    assert error.get("cited_lines") == [], (
        f"Synthetic error 'cited_lines' must be empty list, got: {error.get('cited_lines')!r}"
    )


# ---------------------------------------------------------------------------
# Scenario 3 — Frozen field mutation routes to synthetic schema_error
# ---------------------------------------------------------------------------


def test_correction_frozen_field_mutation_routes_to_synthetic_error(
    monkeypatch,
) -> None:
    """Given: original findings with frozen fields; correction dispatch returns valid
              JSON with the same count but mutates one frozen field (severity).
    When: dispatch_schema_correction() is called with max_attempts=1.
    Then:
      - A synthetic finding with category='schema_error' is appended.
      - The returned findings list contains the synthetic error entry.
    """
    originals = [copy.deepcopy(_FINDING_A)]
    mutated = [copy.deepcopy(_FINDING_A)]
    mutated[0]["severity"] = "minor"  # mutate a frozen field

    def _mock_dispatch_review(**kwargs):
        return {"findings": mutated}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)

    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert schema_errors, (
        f"Expected synthetic schema_error finding on frozen field mutation, "
        f"got findings: {findings}"
    )
    error = schema_errors[0]
    assert error.get("type") == "parse_error", (
        f"Synthetic error type must be 'parse_error', got: {error.get('type')!r}"
    )
    assert error.get("severity") == "important", (
        f"Synthetic error severity must be 'important', got: {error.get('severity')!r}"
    )


# ---------------------------------------------------------------------------
# Scenario 4 — Exhausted retries appends synthetic parse_error
# ---------------------------------------------------------------------------


def test_correction_exhausted_retries_appends_synthetic_error(monkeypatch) -> None:
    """Given: dispatch_schema_correction is called with max_attempts=2; each
              correction call returns a response that fails frozen-field validation
              (frozen field mutation), consuming all retries.
    When: all retries are exhausted.
    Then:
      - The returned findings contain a synthetic finding with:
          type='parse_error', severity='critical', category='schema_error',
          finding_id starting with 'schema_error_',
          cited_excerpt='', reachability=''
    """
    originals = [copy.deepcopy(_FINDING_A)]
    always_mutated = [copy.deepcopy(_FINDING_A)]
    always_mutated[0]["severity"] = "minor"  # always mutate a frozen field

    call_count = [0]

    def _mock_dispatch_review(**kwargs):
        call_count[0] += 1
        return {"findings": always_mutated}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)

    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=2,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    parse_errors = [
        f
        for f in findings
        if f.get("type") == "parse_error" and f.get("category") == "schema_error"
    ]
    assert parse_errors, (
        f"Expected synthetic parse_error/schema_error finding on exhausted retries, "
        f"got findings: {findings}"
    )

    error = parse_errors[0]
    # Validate full synthetic error shape
    assert error.get("severity") == "important", (
        f"Synthetic error severity must be 'important': {error}"
    )
    assert isinstance(error.get("description"), str) and error["description"], (
        f"Synthetic error must have non-empty description: {error}"
    )
    assert isinstance(error.get("finding_id"), str) and error["finding_id"].startswith(
        "schema_error_"
    ), (
        f"Synthetic error finding_id must start with 'schema_error_', got: {error.get('finding_id')!r}"
    )
    assert error.get("cited_excerpt") == "", (
        f"Synthetic error cited_excerpt must be empty string, got: {error.get('cited_excerpt')!r}"
    )
    assert error.get("reachability") == "", (
        f"Synthetic error reachability must be empty string, got: {error.get('reachability')!r}"
    )


# ---------------------------------------------------------------------------
# Scenario 5 — max_attempts=0 short-circuits to synthetic error immediately
# ---------------------------------------------------------------------------


def test_max_attempts_zero_short_circuits_to_synthetic_error(monkeypatch) -> None:
    """Given: dispatch_schema_correction is called with max_attempts=0.
    When: the function is invoked.
    Then:
      - dispatch_review is NOT called (zero retries means skip dispatch entirely).
      - The returned findings contain a synthetic schema_error immediately.
    """
    originals = [copy.deepcopy(_FINDING_A)]
    dispatch_call_count = [0]

    def _mock_dispatch_review(**kwargs):
        dispatch_call_count[0] += 1
        return {"findings": [copy.deepcopy(_FINDING_A)]}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=0,
        agent_id="code-reviewer-standard",
    )

    assert dispatch_call_count[0] == 0, (
        f"dispatch_review must NOT be called when max_attempts=0, "
        f"but was called {dispatch_call_count[0]} time(s)"
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert schema_errors, (
        f"Expected synthetic schema_error finding when max_attempts=0, "
        f"got findings: {findings}"
    )


# ---------------------------------------------------------------------------
# Scenario 6 — Schema-invalid correction response consumes a retry, no recursion
# ---------------------------------------------------------------------------


def test_correction_schema_invalid_response_consumes_retry(monkeypatch) -> None:
    """Given: dispatch_schema_correction is called with max_attempts=2; the first
              correction call returns schema-invalid JSON (validator returns schema_fail);
              the second call returns a schema-valid, frozen-field-preserving result.
    When: dispatch_schema_correction() is called.
    Then:
      - The first call's schema-fail consumes one retry (does NOT recurse).
      - The second call succeeds; no synthetic schema_error is appended.
      - Total dispatch_review call count is exactly 2.
    """
    originals = [copy.deepcopy(_FINDING_A)]
    corrected_valid = _schema_valid_corrected_findings(originals)

    call_count = [0]

    def _mock_dispatch_review(**kwargs):
        call_count[0] += 1
        # Both calls return the same valid JSON; schema validity is controlled by the stub
        return {"findings": corrected_valid}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)

    validate_call_count = [0]

    def _stub_validate_first_fail_then_pass(merged: dict, **kwargs) -> Any:
        validate_call_count[0] += 1
        if validate_call_count[0] == 1:
            return _runner_mod._SchemaValidationResult(
                "schema_fail", ["missing cited_lines"]
            )
        return _runner_mod._SchemaValidationResult("schema_pass", [])

    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_first_fail_then_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=2,
        agent_id="code-reviewer-standard",
    )

    assert call_count[0] == 2, (
        f"Expected exactly 2 dispatch_review calls (1 schema-fail + 1 success), "
        f"got {call_count[0]}"
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"No synthetic schema_error should appear when second retry succeeds, "
        f"got: {schema_errors}"
    )


# ---------------------------------------------------------------------------
# Scenario 7 — Hash preserved after correction (AC amendment)
# ---------------------------------------------------------------------------


def test_hash_preserved_after_correction(monkeypatch) -> None:
    """Given: original findings with frozen fields; correction dispatch returns
              schema-valid JSON with frozen fields preserved.
    When: dispatch_schema_correction() succeeds and findings are serialised
          to reviewer-findings.json format.
    Then:
      - A SHA-256 hash computed over the frozen-field values of the corrected
        findings matches a hash computed over the same fields of the originals.
      - This confirms that --reviewer-hash computed before correction would
        still match findings after correction (frozen fields are byte-for-byte
        identical).
    """
    originals = [copy.deepcopy(_FINDING_A), copy.deepcopy(_FINDING_B)]
    corrected = _schema_valid_corrected_findings(originals)

    def _mock_dispatch_review(**kwargs):
        return {"findings": corrected}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)

    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    result_findings = result.get("findings", [])
    # Filter out any synthetic errors before hashing
    real_findings = [f for f in result_findings if f.get("category") != "schema_error"]

    def _frozen_hash(findings: list[dict]) -> str:
        """Hash only frozen fields of each finding, in order."""
        frozen_values = [
            {field: f[field] for field in _FROZEN_FIELDS if field in f}
            for f in findings
        ]
        serialized = json.dumps(frozen_values, sort_keys=True, ensure_ascii=False)
        return hashlib.sha256(serialized.encode("utf-8")).hexdigest()

    original_hash = _frozen_hash(originals)
    corrected_hash = _frozen_hash(real_findings)

    assert original_hash == corrected_hash, (
        f"Frozen-field hash mismatch after correction — frozen fields were mutated.\n"
        f"Original hash : {original_hash}\n"
        f"Corrected hash: {corrected_hash}\n"
        f"Original frozen fields : {[{f: o[f] for f in _FROZEN_FIELDS if f in o} for o in originals]}\n"
        f"Corrected frozen fields: {[{f: r[f] for f in _FROZEN_FIELDS if f in r} for r in real_findings]}"
    )


# ---------------------------------------------------------------------------
# Scenario 8 — finding_id regeneration allowed when original is absent/empty
# ---------------------------------------------------------------------------


def test_finding_id_regeneration_allowed_when_absent_or_malformed(monkeypatch) -> None:
    """Given: original findings where finding_id is absent or empty.
    When: correction dispatch returns findings with a newly generated finding_id
          in f-<hex8> format.
    Then:
      - No synthetic schema_error is appended (regeneration is accepted).
      - The returned finding_id matches the corrected value.
    """
    original_no_id = copy.deepcopy(_FINDING_A)
    del original_no_id["finding_id"]  # absent

    original_empty_id = copy.deepcopy(_FINDING_B)
    original_empty_id["finding_id"] = ""  # empty

    originals = [original_no_id, original_empty_id]

    corrected = [copy.deepcopy(original_no_id), copy.deepcopy(original_empty_id)]
    corrected[0]["finding_id"] = "f-a1b2c3d4"
    corrected[1]["finding_id"] = "f-deadbeef"

    def _mock_dispatch_review(**kwargs):
        return {"findings": corrected}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"finding_id regeneration must be accepted when original is absent/empty, "
        f"but got schema_error: {schema_errors}"
    )
    assert findings[0].get("finding_id") == "f-a1b2c3d4"
    assert findings[1].get("finding_id") == "f-deadbeef"


# ---------------------------------------------------------------------------
# Scenario 10 — valid finding_id is frozen: mutation rejected
# ---------------------------------------------------------------------------


def test_valid_finding_id_mutation_rejected(monkeypatch) -> None:
    """Given: original findings with a structurally-valid finding_id (f-<hex8>).
    When: correction dispatch returns findings with the finding_id changed to a
          different valid f-<hex8> value.
    Then:
      - A synthetic schema_error is appended (mutation of a valid finding_id is rejected).
    """
    originals = [copy.deepcopy(_FINDING_A)]
    # _FINDING_A has finding_id="abc123" which is NOT f-<hex8> format
    # Use a finding with a valid f-<hex8> finding_id
    originals[0]["finding_id"] = "f-a1b2c3d4"  # structurally valid

    mutated = [copy.deepcopy(originals[0])]
    mutated[0]["finding_id"] = "f-deadbeef"  # different valid f-<hex8>

    def _mock_dispatch_review(**kwargs):
        return {"findings": mutated}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert schema_errors, (
        f"Expected synthetic schema_error when valid finding_id is mutated, "
        f"got findings: {findings}"
    )
    assert schema_errors[0].get("type") == "parse_error"
    assert schema_errors[0].get("severity") == "important"


# ---------------------------------------------------------------------------
# Scenario 9 — file and cited_lines mutations are rejected as frozen violations
# ---------------------------------------------------------------------------


def test_file_and_cited_lines_frozen_field_mutation_rejected(monkeypatch) -> None:
    """Given: original findings with file and cited_lines set.
    When: correction dispatch returns findings with mutated file or cited_lines.
    Then:
      - A synthetic finding with category='schema_error' is appended (mutation rejected).

    Tests both 'file' and 'cited_lines' frozen fields, since they are enumerated
    individually in _FROZEN_FIELDS and each is independently enforced.
    """
    # --- Test 1: file mutation rejected ---
    originals = [copy.deepcopy(_FINDING_A)]
    mutated = [copy.deepcopy(_FINDING_A)]
    mutated[0]["file"] = "src/other.py"  # mutate frozen field 'file'

    def _mock_dispatch_review(**kwargs):
        return {"findings": mutated}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert schema_errors, (
        f"Expected synthetic schema_error on 'file' mutation, got findings: {findings}"
    )
    assert schema_errors[0].get("type") == "parse_error"
    assert schema_errors[0].get("severity") == "important"

    # --- Test 2: cited_lines mutation rejected ---
    originals2 = [copy.deepcopy(_FINDING_A)]
    mutated2 = [copy.deepcopy(_FINDING_A)]
    mutated2[0]["cited_lines"] = [
        "src/handler.py:99"
    ]  # mutate frozen field 'cited_lines'

    def _mock_dispatch_review2(**kwargs):
        return {"findings": mutated2}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review2)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result2 = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals2,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings2 = result2.get("findings", [])
    schema_errors2 = [f for f in findings2 if f.get("category") == "schema_error"]
    assert schema_errors2, (
        f"Expected synthetic schema_error on 'cited_lines' mutation, "
        f"got findings: {findings2}"
    )
    assert schema_errors2[0].get("type") == "parse_error"
    assert schema_errors2[0].get("severity") == "important"


# ---------------------------------------------------------------------------
# Scenario 10 — malformed cited_lines are correctable (not frozen when invalid)
# ---------------------------------------------------------------------------


def test_malformed_cited_lines_not_frozen_allows_correction(monkeypatch) -> None:
    """Given: original findings have malformed cited_lines (invalid format).
    When: correction dispatch returns findings with cited_lines fixed to valid format.
    Then:
      - Correction succeeds (no synthetic schema_error appended).
      - The corrected cited_lines value is accepted.

    Rationale: cited_lines is frozen only when schema-valid. If the original is
    malformed (not matching <path>:<non-zero-line>), the correction must be allowed
    to fix the format — otherwise schema correction cannot resolve cited_lines errors.
    """
    # Original finding with malformed cited_lines (missing line number)
    orig_with_bad_cited = copy.deepcopy(_FINDING_A)
    orig_with_bad_cited["cited_lines"] = ["src/bad_format_no_line_number"]  # malformed

    # Corrected finding with valid cited_lines
    corrected_with_fixed_cited = copy.deepcopy(orig_with_bad_cited)
    corrected_with_fixed_cited["cited_lines"] = ["src/bad_format_no_line_number:42"]

    def _mock_dispatch_review(**kwargs):
        return {"findings": [corrected_with_fixed_cited]}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=[orig_with_bad_cited],
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Correction of malformed cited_lines must succeed (not be treated as frozen "
        f"violation); got schema_errors: {schema_errors}"
    )
    assert findings[0].get("cited_lines") == ["src/bad_format_no_line_number:42"], (
        f"Corrected cited_lines must be accepted; got {findings[0].get('cited_lines')!r}"
    )


def test_enum_invalid_severity_correction_allowed(monkeypatch) -> None:
    """Given: original finding has an enum-invalid severity (e.g. "suggestion").
    When: correction dispatch returns the same finding with severity mapped to a
          valid enum value (e.g. "minor").
    Then:
      - Correction succeeds (no synthetic schema_error appended).
      - The corrected severity value is accepted.

    Rationale: severity is frozen only when the original is enum-valid. If the
    LLM emits a severity not in _VALID_SEVERITIES (e.g. "suggestion" — a label
    referenced in plugin docs but not in the dispatch enum), correction must be
    allowed to repair the enum — otherwise schema correction cannot resolve
    severity-enum errors and the llm-review job fails closed for any review whose
    LLM emits a non-enum severity. Bug 0d1e-e9d5-2fcb-4bc5.
    """
    # Original finding with enum-invalid severity
    orig_with_bad_sev = copy.deepcopy(_FINDING_A)
    orig_with_bad_sev["severity"] = "suggestion"  # not in _VALID_SEVERITIES

    # Corrected finding with severity mapped to a valid enum value
    corrected_with_fixed_sev = copy.deepcopy(orig_with_bad_sev)
    corrected_with_fixed_sev["severity"] = "minor"

    def _mock_dispatch_review(**kwargs):
        return {"findings": [corrected_with_fixed_sev]}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=[orig_with_bad_sev],
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Correction of enum-invalid severity must succeed (not be treated as "
        f"frozen violation); got schema_errors: {schema_errors}"
    )
    assert findings[0].get("severity") == "minor", (
        f"Corrected severity must be accepted; got {findings[0].get('severity')!r}"
    )


def test_valid_severity_mutation_rejected(monkeypatch) -> None:
    """Anti-regression: severity mutation rejected when original is enum-valid.

    Given: original finding has an enum-valid severity (e.g. "critical").
    When: correction dispatch returns the same finding with severity changed to
          a different enum-valid value (e.g. "minor").
    Then:
      - A synthetic schema_error finding is appended (frozen-field violation).

    Rationale: when the original severity is already in _VALID_SEVERITIES, any
    change is a semantic mutation — not an enum repair — and must remain rejected
    to preserve the byte-for-byte freeze. The carve-out added for bug
    0d1e-e9d5-2fcb-4bc5 must NOT loosen this guarantee.
    """
    # Original finding with enum-valid severity
    orig_with_valid_sev = copy.deepcopy(_FINDING_A)
    assert orig_with_valid_sev["severity"] == "critical"  # sanity: in _VALID_SEVERITIES

    # Corrected finding mutates the (already-valid) severity to a different value
    mutated = copy.deepcopy(orig_with_valid_sev)
    mutated["severity"] = "minor"

    def _mock_dispatch_review(**kwargs):
        return {"findings": [mutated]}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=[orig_with_valid_sev],
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert schema_errors, (
        f"Mutation of enum-valid severity must be rejected (synthetic schema_error "
        f"appended); got findings: {findings}"
    )


def test_cited_line_re_accepts_line_ranges() -> None:
    """_CITED_LINE_RE must accept line-range formats (file:N-M, file:N~M).

    LLMs commonly cite blocks of code using range notation. Rejecting ranges
    causes unnecessary schema correction cycles and triggered a fail-closed
    failure on CI cycle 8 (three findings with :83-112, :845~851, :898~906).
    Both dash-range and tilde-range separators must be accepted.
    """
    valid_entries = [
        "src/foo.py:42",  # single line
        "~src/foo.py:42",  # approx single line
        ".github/workflows/per-branch-review.yml:83-112",  # dash range
        "plugins/dso/scripts/dso_ci_review/dispatch.py:845~851",  # tilde range
        "plugins/dso/scripts/dso_ci_review/dispatch.py:898~906",  # tilde range
        "src/foo.py:1-999",  # large range
    ]
    invalid_entries = [
        "src/bad_format_no_line_number",  # no colon+line
        "src/foo.py:",  # missing line number
        "src/foo.py:0",  # zero not allowed
        "src/foo.py:0-10",  # zero start not allowed
    ]
    for entry in valid_entries:
        assert _dispatch_mod._CITED_LINE_RE.match(entry), (
            f"_CITED_LINE_RE must accept {entry!r} but did not match"
        )
    for entry in invalid_entries:
        assert not _dispatch_mod._CITED_LINE_RE.match(entry), (
            f"_CITED_LINE_RE must reject {entry!r} but matched"
        )


def test_reachability_fallback_injects_boilerplate_when_only_error(monkeypatch) -> None:
    """Programmatic reachability fallback injects boilerplate when only missing field is reachability.

    Given: LLM correction exhausts all attempts but the ONLY remaining error
           is missing 'reachability' on important/maintainability findings.
    When: dispatch_schema_correction exhausted-path reachability fallback fires.
    Then:
      - No synthetic schema_error is appended.
      - Each finding missing reachability gets a boilerplate string injected.
      - The returned findings pass schema validation.

    Rationale: Correction LLMs often produce valid findings except for missing
    reachability on test-file maintainability/hygiene findings (where a
    caller-input→harm chain is not semantically applicable). Failing closed on
    this case is overly strict; boilerplate injection is a safe fallback.
    """
    # Two findings that are valid EXCEPT for missing reachability
    finding_missing_reach_1 = {
        "severity": "important",
        "category": "maintainability",
        "description": "test_dispatch_schema_correction.py exceeds 500-line threshold",
        "file": "tests/skills/dso_ci_review/test_dispatch_schema_correction.py",
        "cited_lines": [
            "tests/skills/dso_ci_review/test_dispatch_schema_correction.py:1"
        ],
        "finding_id": "f-aa000001",
        "cited_excerpt": "def test_correction_success_returns_corrected_findings(monkeypatch",
        # 'reachability' intentionally absent
    }
    finding_missing_reach_2 = {
        "severity": "important",
        "category": "hygiene",
        "description": "Duplicate mock blocks across test_runner_smoke.py",
        "file": "tests/skills/dso_ci_review/test_runner_smoke.py",
        "cited_lines": ["tests/skills/dso_ci_review/test_runner_smoke.py:311"],
        "finding_id": "f-aa000002",
        "cited_excerpt": "monkeypatch.setattr(_runner_mod, '_validate_findings_schema'",
        # 'reachability' intentionally absent
    }

    def _mock_dispatch_review_returns_same(**kwargs):
        # Correction LLM returns the findings unchanged (still missing reachability)
        return {
            "findings": [finding_missing_reach_1, finding_missing_reach_2],
            "summary": "Two test-file code quality findings; no production code changes.",
        }

    monkeypatch.setattr(
        _dispatch_mod, "dispatch_review", _mock_dispatch_review_returns_same
    )
    # Use the real _validate_findings_schema so the fallback logic works end-to-end
    # (do NOT stub it — the fallback relies on real validation to detect missing reach)

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=[finding_missing_reach_1, finding_missing_reach_2],
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Reachability fallback must prevent synthetic schema_error; got: {schema_errors}"
    )
    assert len(findings) == 2, (
        f"Finding count must be preserved at 2; got {len(findings)}"
    )
    for f in findings:
        reach = f.get("reachability", "")
        assert isinstance(reach, str) and len(reach.strip()) >= 20, (
            f"Boilerplate reachability must be >= 20 chars; got {reach!r}"
        )


def test_correction_dispatch_infra_failure_triggers_reachability_fallback(
    monkeypatch,
) -> None:
    """Scenario 11b: dispatch_review returns fallback_exhausted (API overload) during
    schema correction; reachability fallback must apply to original_findings instead
    of the infra-failure sentinel, so the correction succeeds without a schema_error.

    When: dispatch_review returns {"findings": [fallback_exhausted_entry]} during
          schema correction for two important findings that are only missing
          reachability.
    Then: reachability fallback injects boilerplate reachability into the original
          findings and returns them (no synthetic schema_error appended).
    """
    finding_a = {
        "severity": "important",
        "category": "maintainability",
        "description": "Long method should be extracted",
        "file": "src/service.py",
        "cited_lines": ["src/service.py:10"],
        "finding_id": "f-aa001122",
        "cited_excerpt": "def handle(self): ...",
        # 'reachability' intentionally absent — causes schema_fail
    }
    finding_b = {
        "severity": "important",
        "category": "hygiene",
        "description": "Duplicate logic should be deduplicated",
        "file": "src/utils.py",
        "cited_lines": ["src/utils.py:5"],
        "finding_id": "f-bb334455",
        "cited_excerpt": "def helper(): ...",
        # 'reachability' intentionally absent
    }

    _fallback_exhausted_entry = {
        "type": "fallback_exhausted",
        "agent_id": "schema-correction",
        "primary_model": "claude-haiku-4-5",
        "attempted_cross_provider": ["anthropic"],
        "attempted_context_models": ["claude-haiku-4-5"],
        "final_exception_class": "InternalServerError",
        "final_exception_message": "API key validation is temporarily unavailable. Please retry.",
    }

    def _mock_dispatch_review_infra_fail(**kwargs: object) -> dict:
        return {"findings": [_fallback_exhausted_entry]}

    monkeypatch.setattr(
        _dispatch_mod, "dispatch_review", _mock_dispatch_review_infra_fail
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=[finding_a, finding_b],
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="schema-correction",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Infrastructure failure during correction must not produce schema_error when "
        f"only reachability is missing; reachability fallback must apply to "
        f"original_findings. Got schema_errors: {schema_errors}"
    )
    assert len(findings) == 2, (
        f"Finding count must be preserved (got {len(findings)}, expected 2)"
    )
    for f in findings:
        reach = f.get("reachability", "")
        assert isinstance(reach, str) and len(reach.strip()) >= 20, (
            f"Boilerplate reachability must be >= 20 non-whitespace chars; got {reach!r}"
        )


# ---------------------------------------------------------------------------
# Scenario 12 — Infra-failure on final attempt must not overwrite a prior
#               non-infra result (fixes last_result clobber with max_attempts>1)
# ---------------------------------------------------------------------------


def test_infra_failure_on_final_attempt_preserves_prior_non_infra_result(
    monkeypatch,
) -> None:
    """Scenario 12: max_attempts=2; iter 1 returns a non-infra JSON result (schema-invalid
    because reachability is missing); iter 2 returns infra-failure (fallback_exhausted).

    Given: dispatch_schema_correction is called with max_attempts=2.
           Iteration 1 returns JSON with cited_excerpt='corrected excerpt' but no reachability
           (causes schema_fail → continues to iter 2).
           Iteration 2 returns fallback_exhausted.
    When: the correction loop exits.
    Then: last_result retains iter 1's findings (cited_excerpt='corrected excerpt'),
          NOT original_findings (cited_excerpt='original excerpt').
          The reachability fallback injects boilerplate reachability.
          No synthetic schema_error is appended.
    """
    original = {
        "severity": "important",
        "category": "maintainability",
        "description": "Method is too long and should be extracted",
        "file": "src/service.py",
        "cited_lines": ["src/service.py:42"],
        "finding_id": "f-cc778899",
        "cited_excerpt": "original excerpt",
        # reachability absent — schema_fail on iter 1
    }

    corrected_iter1 = {
        **original,
        "cited_excerpt": "corrected excerpt",  # updated by correction LLM (not frozen)
        # reachability still absent — will schema_fail
    }

    _fallback_exhausted_entry = {
        "type": "fallback_exhausted",
        "agent_id": "schema-correction",
        "primary_model": "claude-sonnet-4-6",
        "attempted_cross_provider": ["anthropic"],
        "attempted_context_models": ["claude-sonnet-4-6"],
        "final_exception_class": "InternalServerError",
        "final_exception_message": "API overloaded; please retry.",
    }

    call_count = [0]

    def _mock_dispatch_review(**kwargs: object) -> dict:
        call_count[0] += 1
        if call_count[0] == 1:
            return {"findings": [corrected_iter1], "summary": "correction attempt 1"}
        # iter 2: infra-failure
        return {"findings": [_fallback_exhausted_entry]}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=[original],
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=2,
        agent_id="schema-correction",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Infra-failure on final attempt must not append schema_error when iter 1 "
        f"produced a non-infra result; got: {schema_errors}"
    )
    assert len(findings) == 1, (
        f"Expected 1 finding (reachability fallback preserves count), got {len(findings)}"
    )
    assert findings[0].get("cited_excerpt") == "corrected excerpt", (
        f"last_result must retain iter 1's non-infra result (cited_excerpt='corrected excerpt'), "
        f"not original_findings (cited_excerpt='original excerpt'). Got: {findings[0].get('cited_excerpt')!r}"
    )
    reach = findings[0].get("reachability", "")
    assert isinstance(reach, str) and len(reach.strip()) >= 20, (
        f"Reachability fallback must inject boilerplate (>=20 chars); got {reach!r}"
    )


def test_reachability_fallback_fires_when_warnings_interleaved_with_reachability_errors(
    monkeypatch,
) -> None:
    """Relaxed precondition: reachability fallback fires even when absence-claim WARNINGs
    are interleaved with reachability errors in validator output.

    Given: validator output contains both
           - findings[N]: missing required field 'reachability' (hard error)
           - WARNING: findings[M].verification_evidence absent (soft-mode WARNING)
    When: dispatch_schema_correction exhausted-path fallback runs.
    Then: _only_reach_errors is True (WARNINGs excluded from precondition check),
          the reachability fallback fires and injects boilerplate,
          no synthetic schema_error is appended.
    """
    finding_missing_reach = {
        "severity": "important",
        "category": "maintainability",
        "description": "test file exceeds threshold",
        "file": "tests/skills/dso_ci_review/test_dispatch_schema_correction.py",
        "cited_lines": [
            "tests/skills/dso_ci_review/test_dispatch_schema_correction.py:1"
        ],
        "finding_id": "f-bb000001",
        "cited_excerpt": "def test_",
        # 'reachability' intentionally absent
    }
    finding_with_absence_lang = {
        "severity": "important",
        "category": "correctness",
        "description": "Error handler is not present in the module",
        "file": "src/handler.py",
        "cited_lines": ["src/handler.py:10"],
        "finding_id": "f-bb000002",
        "cited_excerpt": "# no handler here",
        "reachability": "caller passes bad input → missing handler → unhandled exception",
        # 'verification_evidence' absent — triggers soft-mode WARNING
    }

    def _mock_dispatch_same(**kwargs):
        return {
            "findings": [finding_missing_reach, finding_with_absence_lang],
            "summary": "two findings",
        }

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_same)

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=[finding_missing_reach, finding_with_absence_lang],
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Reachability fallback must fire despite interleaved WARNINGs; got: {schema_errors}"
    )
    reach = findings[0].get("reachability", "") if findings else ""
    assert isinstance(reach, str) and len(reach.strip()) >= 20, (
        f"Reachability boilerplate must be injected; got {reach!r}"
    )


def test_absence_claim_fallback_injects_verification_evidence_boilerplate(
    monkeypatch,
) -> None:
    """Absence-claim fallback injects boilerplate verification_evidence for absence-language findings.

    Given: validator output contains WARNING for findings[5].verification_evidence
           (absence-claim language in description, soft-mode enforcement).
    When: dispatch_schema_correction exhausted-path fallback runs.
    Then: findings[5]["verification_evidence"] equals _ABSENCE_EVIDENCE_BOILERPLATE
          (command="fallback", output starting with "fallback-injected").
    """
    findings_input = [
        {
            "severity": "important",
            "category": "correctness",
            "description": "Handler is not present in the module",
            "file": f"src/file{i}.py",
            "cited_lines": [f"src/file{i}.py:{i + 1}"],
            "finding_id": f"f-cc00000{i}",
            "cited_excerpt": "# nothing",
            "reachability": "caller → missing handler → crash",
            # verification_evidence absent on index 5 (which has absence language)
        }
        if i != 5
        else {
            "severity": "important",
            "category": "correctness",
            "description": "Error handler is not present in this module",
            "file": "src/target.py",
            "cited_lines": ["src/target.py:42"],
            "finding_id": "f-cc000005",
            "cited_excerpt": "pass",
            "reachability": "caller → missing handler → crash",
            # verification_evidence intentionally absent — absence language triggers WARNING
        }
        for i in range(6)
    ]

    def _mock_dispatch_same(**kwargs):
        return {"findings": findings_input, "summary": "six findings"}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_same)

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=findings_input,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    # In soft mode the absence-claim WARNING does not block schema_pass, so the
    # fallback returns the patched result without a synthetic error.
    absence_idx_5 = next(
        (f for f in findings if f.get("finding_id") == "f-cc000005"), None
    )
    if absence_idx_5 is not None:
        ve = absence_idx_5.get("verification_evidence")
        # If hard enforcement is active, the finding will have ve injected.
        # If soft mode is active, schema_pass occurs without ve — both are valid.
        if ve is not None:
            assert ve.get("command") == "fallback", (
                f"Injected command must be 'fallback'; got {ve.get('command')!r}"
            )
            assert "fallback-injected" in ve.get("output", ""), (
                f"Injected output must contain 'fallback-injected'; got {ve.get('output')!r}"
            )


# ---------------------------------------------------------------------------
# bug 881d-e5cc — synthetic-only original is allowed to correct to empty array
# ---------------------------------------------------------------------------


def test_synthetic_only_original_allows_zero_real_findings(monkeypatch) -> None:
    """Given: original findings contain ONLY synthetic markers (fallback_exhausted,
              specialist_error, or parse_error) — i.e., the dispatch layer's
              sentinel telling the loop the LLM call failed and there are no
              real findings to validate.
    When: schema correction returns a well-formed empty findings array.
    Then: the count-equality check must NOT fire — both sides have 0 REAL
          findings. Correction is accepted, no synthetic schema_error is
          injected, and CI does not fail-closed on a trivially clean diff.
    Bug 881d-e5cc (observed on PR #167, run 25970902666).
    """
    # Original: one fallback_exhausted sentinel (no real review feedback)
    fallback_exhausted = {
        "type": "fallback_exhausted",
        "severity": "fallback_exhausted",
        "category": "synthetic",
        "description": "primary + 2 fallback providers all failed",
        "file": "",
        "cited_lines": [],
        "cited_excerpt": "",
        "reachability": "",
        "final_exception_message": "litellm.APIError: 529",
    }
    originals = [fallback_exhausted]
    # Correction returns an empty findings array — valid response for a clean diff
    corrected: list[dict] = []

    def _mock_dispatch_review(**kwargs):
        return {"findings": corrected, "summary": "no real findings on clean diff"}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Synthetic schema_error must NOT be injected when correction "
        f"validly drops synthetic-only originals to an empty array; "
        f"got: {findings}"
    )
    # The accepted correction result is the empty list, so the final findings
    # contain neither the synthetic schema_error nor the original sentinel.
    real = [
        f
        for f in findings
        if f.get("type")
        not in {"fallback_exhausted", "specialist_error", "parse_error"}
    ]
    assert real == [], f"Expected zero real findings; got {real}"


# ---------------------------------------------------------------------------
# bug 881d-e5cc follow-up — coverage gaps from retro-review of PR #183
# Tests three previously-untested variants:
#   (1) synthetic-only original with type=specialist_error
#   (2) synthetic-only original with type=parse_error (dispatch-layer marker,
#       distinct from a synthetic schema_error injected on correction failure)
#   (3) interleaved real + synthetic in original; corrected drops the
#       synthetic — frozen-field zip alignment must remain correct
# ---------------------------------------------------------------------------


def test_specialist_error_only_original_allows_zero_real_findings(monkeypatch) -> None:
    """type=specialist_error is a synthetic dispatch-layer marker (same family
    as fallback_exhausted). Empty corrected output must be accepted."""
    specialist_error = {
        "type": "specialist_error",
        "severity": "important",
        "category": "synthetic",
        "description": "specialist agent crashed",
        "file": "",
        "cited_lines": [],
        "cited_excerpt": "",
        "reachability": "",
    }
    originals = [specialist_error]

    def _mock_dispatch_review(**kwargs):
        return {"findings": [], "summary": "no real findings"}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )
    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Synthetic schema_error must NOT be injected when correction "
        f"drops a specialist_error-only original to empty; got: {findings}"
    )


def test_parse_error_only_original_allows_zero_real_findings(monkeypatch) -> None:
    """type=parse_error is a synthetic dispatch-layer marker (NOT a real
    review finding). Empty corrected output must be accepted."""
    parse_error = {
        "type": "parse_error",
        "severity": "important",
        "category": "schema_error",
        "description": "LLM returned non-JSON",
        "file": "",
        "cited_lines": [],
        "cited_excerpt": "",
        "reachability": "",
    }
    originals = [parse_error]

    def _mock_dispatch_review(**kwargs):
        return {"findings": [], "summary": "no real findings"}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )
    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Synthetic schema_error must NOT be injected when correction "
        f"drops a parse_error-only original to empty; got: {findings}"
    )


def test_interleaved_real_and_synthetic_zip_alignment(monkeypatch) -> None:
    """Original = [synthetic, real_A]. Corrected drops the synthetic and
    keeps real_A. Frozen-field zip MUST align _real_original[0]=real_A
    against _real_attempt[0]=real_A_corrected — NOT against the dropped
    synthetic. Validates the index-shift handling in the filter logic."""
    synthetic = {
        "type": "fallback_exhausted",
        "severity": "fallback_exhausted",
        "category": "synthetic",
        "description": "primary failed",
        "file": "",
        "cited_lines": [],
        "cited_excerpt": "",
        "reachability": "",
    }
    real_a = copy.deepcopy(_FINDING_A)
    originals = [synthetic, real_a]
    # Corrected: drops the synthetic, preserves real_a with frozen fields
    real_a_corrected = copy.deepcopy(_FINDING_A)
    real_a_corrected["reachability"] = "corrected reachability text"  # non-frozen field
    correcteds = [real_a_corrected]

    def _mock_dispatch_review(**kwargs):
        return {"findings": correcteds, "summary": "ok"}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=originals,
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )
    findings = result.get("findings", [])
    schema_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not schema_errors, (
        f"Frozen-field zip should align real_a against real_a_corrected "
        f"(synthetic correctly dropped). No schema_error expected. got: {findings}"
    )
    # Sanity: the corrected real finding made it through
    real_findings = [
        f
        for f in findings
        if f.get("type")
        not in {"fallback_exhausted", "specialist_error", "parse_error"}
    ]
    assert len(real_findings) == 1, f"Expected 1 real finding; got {len(real_findings)}"


# ---------------------------------------------------------------------------
# Test: large diff stripped from schema correction prompt (bug a5a0-c80e)
# ---------------------------------------------------------------------------
def test_large_diff_stripped_from_correction_prompt():
    """When diff_text exceeds the correction char limit, the diff section is
    replaced with a placeholder so Haiku can produce valid JSON."""
    from unittest.mock import patch as _patch

    corrected = _schema_valid_corrected_findings([_FINDING_A])
    calls_captured: list[str] = []

    def _fake_dispatch(*, diff_text, **kwargs):
        calls_captured.append(diff_text)
        return {"findings": corrected, "summary": "ok"}

    large_diff = "x" * 60_000

    with _patch.object(_dispatch_mod, "dispatch_review", side_effect=_fake_dispatch):
        with _patch.object(
            _runner_mod,
            "_validate_findings_schema",
            return_value=_runner_mod._SchemaValidationResult("schema_pass", []),
        ):
            _dispatch_mod.dispatch_schema_correction(
                original_findings=[_FINDING_A],
                schema_errors=["missing reachability"],
                diff_text=large_diff,
                provider_chain=["anthropic"],
                environ={"ANTHROPIC_API_KEY": "test-key"},
                max_attempts=1,
                agent_id="schema-correction",
            )

    assert len(calls_captured) == 1
    prompt_sent = calls_captured[0]
    assert large_diff not in prompt_sent, (
        "Large diff should be stripped from the correction prompt"
    )
    assert "omitted" in prompt_sent.lower(), (
        "Correction prompt should contain an omission notice for the stripped diff"
    )
