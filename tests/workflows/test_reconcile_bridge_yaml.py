"""Structural tests for .github/workflows/reconcile-bridge.yml.

Asserts the cron schedule, single-flight concurrency, timeout, and the step
invoking the dso_reconciler module — without executing the workflow.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "reconcile-bridge.yml"


@pytest.fixture
def workflow() -> dict:
    """Parse and return the reconcile-bridge workflow YAML."""
    assert WORKFLOW_PATH.exists(), f"Workflow file not found: {WORKFLOW_PATH}"
    with open(WORKFLOW_PATH) as f:
        return yaml.safe_load(f)


class TestWorkflowParseable:
    """The workflow file exists and parses as valid YAML."""

    def test_file_exists(self) -> None:
        assert WORKFLOW_PATH.exists(), f"Missing: {WORKFLOW_PATH}"

    def test_yaml_parseable(self, workflow: dict) -> None:
        assert isinstance(workflow, dict), "Workflow YAML should parse to a dict"


class TestCronSchedule:
    """The workflow triggers on a */20 cron schedule."""

    def test_has_schedule_trigger(self, workflow: dict) -> None:
        on_block = workflow.get("on") or workflow.get(True)  # 'on' is a YAML bool alias
        assert on_block is not None, "Workflow must have an 'on:' trigger block"
        assert "schedule" in on_block, "Workflow must have a 'schedule:' trigger"

    def test_cron_expression(self, workflow: dict) -> None:
        on_block = workflow.get("on") or workflow.get(True)
        schedule = on_block["schedule"]
        cron_expressions = [entry["cron"] for entry in schedule if "cron" in entry]
        assert "*/20 * * * *" in cron_expressions, (
            f"Expected cron '*/20 * * * *', got: {cron_expressions}"
        )

    def test_has_workflow_dispatch(self, workflow: dict) -> None:
        on_block = workflow.get("on") or workflow.get(True)
        assert "workflow_dispatch" in on_block, (
            "Workflow must support manual trigger via workflow_dispatch"
        )


class TestConcurrency:
    """The workflow uses single-flight concurrency on the reconcile-bridge group."""

    def test_concurrency_block_exists(self, workflow: dict) -> None:
        assert "concurrency" in workflow, (
            "Workflow must have a top-level 'concurrency:' block"
        )

    def test_concurrency_group(self, workflow: dict) -> None:
        group = workflow["concurrency"].get("group")
        assert group == "reconcile-bridge", (
            f"Expected concurrency.group='reconcile-bridge', got: {group!r}"
        )

    def test_cancel_in_progress_false(self, workflow: dict) -> None:
        cancel = workflow["concurrency"].get("cancel-in-progress")
        assert cancel is False, (
            f"Expected concurrency.cancel-in-progress=false, got: {cancel!r}"
        )


class TestJobConfiguration:
    """The single reconcile job has the correct timeout and steps."""

    def _get_job(self, workflow: dict) -> dict:
        jobs = workflow.get("jobs", {})
        assert len(jobs) == 1, f"Expected exactly 1 job, found: {list(jobs.keys())}"
        return next(iter(jobs.values()))

    def test_timeout_minutes(self, workflow: dict) -> None:
        job = self._get_job(workflow)
        timeout = job.get("timeout-minutes")
        assert timeout == 15, f"Expected timeout-minutes=15, got: {timeout!r}"

    def test_step_invokes_dso_reconciler(self, workflow: dict) -> None:
        job = self._get_job(workflow)
        steps = job.get("steps", [])
        run_commands = [step.get("run", "") for step in steps if isinstance(step, dict)]
        matching = [cmd for cmd in run_commands if "python -m dso_reconciler" in cmd]
        assert matching, (
            "No step found invoking 'python -m dso_reconciler'. "
            f"Run commands found: {run_commands}"
        )

    def test_has_checkout_step(self, workflow: dict) -> None:
        job = self._get_job(workflow)
        steps = job.get("steps", [])
        uses_values = [step.get("uses", "") for step in steps if isinstance(step, dict)]
        checkout_steps = [u for u in uses_values if u.startswith("actions/checkout")]
        assert checkout_steps, "No actions/checkout step found"

    def test_has_setup_python_step(self, workflow: dict) -> None:
        job = self._get_job(workflow)
        steps = job.get("steps", [])
        uses_values = [step.get("uses", "") for step in steps if isinstance(step, dict)]
        setup_steps = [u for u in uses_values if u.startswith("actions/setup-python")]
        assert setup_steps, "No actions/setup-python step found"
