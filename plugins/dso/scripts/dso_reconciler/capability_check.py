#!/usr/bin/env python3
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class StepResult:
    name: str
    ok: bool
    message: str
    details: dict = field(default_factory=dict)


def run(repo_root: Path | None = None) -> StepResult:
    """Check that identity-layer bootstrap attestation files exist."""
    if repo_root is None:
        repo_root = Path(__file__).parents[4]  # project root

    bootstrap_dir = repo_root / "bridge_state" / "bootstrap"

    if not bootstrap_dir.is_dir():
        return StepResult(
            name="capability_check",
            ok=False,
            message="identity-layer attestation absent — run cfd6 bootstrap first",
        )

    attested_files = list(bootstrap_dir.glob("*.attested.json"))
    if not attested_files:
        return StepResult(
            name="capability_check",
            ok=False,
            message="identity-layer attestation absent — run cfd6 bootstrap first",
        )

    # Validate at least one attestation file has required 'band' key
    for attest_file in attested_files:
        try:
            import json

            data = json.loads(attest_file.read_text())
            if isinstance(data, dict) and "band" in data:
                return StepResult(
                    name="capability_check",
                    ok=True,
                    message=f"attestation found: {attest_file.name}",
                )
        except Exception:
            continue

    return StepResult(
        name="capability_check",
        ok=False,
        message="identity-layer attestation absent — run cfd6 bootstrap first",
    )
