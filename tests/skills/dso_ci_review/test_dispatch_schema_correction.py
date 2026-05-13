"""Tests for dso_ci_review.dispatch.dispatch_schema_correction().

Behavioral contracts under test:
1. Correction dispatch returns schema-valid JSON with same finding count
   AND frozen fields preserved → CI proceeds with corrected findings.
2. Correction returns valid JSON but different finding count → append
   synthetic schema_error, treat as failed.
3. Correction returns valid JSON but one frozen field changed → append
   synthetic schema_error.
4. All retries exhausted → appends {"type": "parse_error", "severity":
   "critical", ...} synthetic finding.
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
  {"type": "parse_error", "severity": "critical", "category": "schema_error",
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
    assert error.get("severity") == "critical", (
        f"Synthetic error severity must be 'critical', got: {error.get('severity')!r}"
    )
    assert "file" in error, f"Synthetic error must include 'file' field: {error}"
    assert "cited_lines" in error, f"Synthetic error must include 'cited_lines' field: {error}"
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
    assert error.get("severity") == "critical", (
        f"Synthetic error severity must be 'critical', got: {error.get('severity')!r}"
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
    assert error.get("severity") == "critical", (
        f"Synthetic error severity must be 'critical': {error}"
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
    assert schema_errors[0].get("severity") == "critical"


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
    assert schema_errors[0].get("severity") == "critical"

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
    assert schema_errors2[0].get("severity") == "critical"


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


def test_cited_line_re_accepts_line_ranges() -> None:
    """_CITED_LINE_RE must accept line-range formats (file:N-M, file:N~M).

    LLMs commonly cite blocks of code using range notation. Rejecting ranges
    causes unnecessary schema correction cycles and triggered a fail-closed
    failure on CI cycle 8 (three findings with :83-112, :845~851, :898~906).
    Both dash-range and tilde-range separators must be accepted.
    """
    valid_entries = [
        "src/foo.py:42",                                           # single line
        "~src/foo.py:42",                                          # approx single line
        ".github/workflows/sprint-story-review.yml:83-112",       # dash range
        "plugins/dso/scripts/dso_ci_review/dispatch.py:845~851",  # tilde range
        "plugins/dso/scripts/dso_ci_review/dispatch.py:898~906",  # tilde range
        "src/foo.py:1-999",                                        # large range
    ]
    invalid_entries = [
        "src/bad_format_no_line_number",  # no colon+line
        "src/foo.py:",                    # missing line number
        "src/foo.py:0",                   # zero not allowed
        "src/foo.py:0-10",               # zero start not allowed
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
        "cited_lines": ["tests/skills/dso_ci_review/test_dispatch_schema_correction.py:1"],
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

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review_returns_same)
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
