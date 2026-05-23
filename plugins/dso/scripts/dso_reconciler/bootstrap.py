#!/usr/bin/env python3
"""Bootstrap driver: orchestrates anomaly-remediation bands with health tracking."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def _load(name: str, filename: str):
    path = Path(__file__).parent / filename
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def run_bootstrap(
    pass_id: str,
    repo_root: Path | None = None,
    *,
    mode: str = "plan",
) -> dict:
    """Run the bootstrap remediation pass with health tracking.

    Captures baseline before any mutations, then loads each band module
    so health can be measured against a consistent snapshot. Despite the
    "bootstrap" name this is intentionally a STUB orchestrator: it does
    not invoke each band's plan, gate, or apply step end-to-end.

    F6 — production bootstrap requires per-band attestation gating
    between plan and apply (operator-in-the-loop signature on each band's
    manifest). That sequencing cannot be modelled as a single in-process
    function call: between plan and apply the operator must (a) review
    the manifest, (b) GPG-sign an attested.json with the manifest hash,
    and (c) commit it. The right interface for production is a documented
    runbook plus a stateful sequencer that resumes from the bootstrap
    state directory — see bug TBD for the sequencer design.

    Args:
        pass_id: Unique identifier for this bootstrap pass.
        repo_root: Repository root path. Defaults to four levels above this
            file (resolved at runtime via ``Path(__file__).parents[4]``).
        mode: ``"plan"`` (default, stub) or ``"apply"`` (raises
            NotImplementedError — operators must follow the manual
            attestation runbook described above).

    Returns:
        A dict with ``pass_id`` and ``bands`` keys summarising each band
        load result. The string ``"planned"`` indicates the band module
        was loaded; no mutation occurred.

    Raises:
        NotImplementedError: If ``mode="apply"`` is passed. The full
            apply-mode orchestrator is not yet implemented.
    """
    if mode == "apply":
        raise NotImplementedError(
            "bootstrap apply mode requires per-band operator attestation "
            "between plan and apply; not implemented in this stub. "
            "See bug TBD for the bootstrap apply sequencer. For now, "
            "run each band's CLI directly: "
            "`python -m dso_reconciler.<band>_band plan|gate|apply`."
        )
    if mode != "plan":
        raise ValueError(f"unknown bootstrap mode: {mode!r}")

    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    health = _load("bootstrap_health", "health.py")

    # Capture baseline BEFORE any band mutations
    health.capture_baseline(pass_id, repo_root=repo_root)

    # Load each band module so import-time errors surface here, not at
    # apply time. No plan/gate/apply step is executed in this stub.
    results = {}
    for band_name, filename in [
        ("orphan", "orphan_band.py"),
        ("stale", "stale_band.py"),
        ("duplicates", "duplicates_band.py"),
        ("open_count_skew", "open_count_skew_band.py"),
    ]:
        try:
            _load(f"band_{band_name}", filename)
            results[band_name] = "planned"
        except Exception as exc:  # noqa: BLE001
            results[band_name] = f"error: {exc}"

    return {"pass_id": pass_id, "bands": results}


if __name__ == "__main__":
    pass_id = sys.argv[1] if len(sys.argv) > 1 else "bootstrap-001"
    result = run_bootstrap(pass_id)
    print(result)
