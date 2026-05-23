#!/usr/bin/env python3
from __future__ import annotations
from dataclasses import dataclass


@dataclass
class StepResult:
    name: str
    ok: bool
    message: str
    details: str = ""


def run() -> StepResult:
    return StepResult(
        name="forward_compat_probe", ok=True, message="stub — not yet implemented"
    )
