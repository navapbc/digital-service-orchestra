"""Behavioral tests for ci-python-skills.yml CI workflow configuration.

These tests parse the workflow YAML and assert on observable configuration
semantics — specifically that pip dependency caching is configured and that
a lockfile is referenced to ensure reproducible installs.
"""

import pathlib

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci-python-skills.yml"


def _load_workflow() -> dict:
    """Parse the ci-python-skills.yml file and return the YAML document."""
    return yaml.safe_load(CI_WORKFLOW.read_text())


def _get_setup_python_step(workflow: dict) -> dict | None:
    """Return the actions/setup-python step from the workflow, or None."""
    for _job_name, job in workflow.get("jobs", {}).items():
        for step in job.get("steps", []):
            uses = step.get("uses", "")
            if uses.startswith("actions/setup-python"):
                return step
    return None


class TestCIPythonSkillsWorkflow:
    """Behavioral tests asserting the CI workflow has correct pip cache configuration."""

    def test_ci_python_skills_has_pip_cache(self) -> None:
        """The actions/setup-python step must include cache: 'pip'.

        RED: The step currently has no cache configuration. This test
        fails until 'cache: pip' is added to the setup-python step's
        'with' block.
        """
        workflow = _load_workflow()
        step = _get_setup_python_step(workflow)
        assert step is not None, (
            "Expected an actions/setup-python step in ci-python-skills.yml but none was found"
        )
        with_block = step.get("with", {})
        cache_value = with_block.get("cache")
        assert cache_value == "pip", (
            f"Expected actions/setup-python step to have 'cache: pip' but got {cache_value!r}. "
            "Add 'cache: pip' to the 'with' block of the setup-python step to enable "
            "GitHub Actions pip dependency caching."
        )

    def test_ci_python_skills_references_lockfile(self) -> None:
        """The workflow must reference a pip lockfile (requirements.lock or requirements*.txt).

        RED: The workflow currently uses a bare 'pip install pytest' without a
        lockfile reference. This test fails until a lockfile is referenced in
        the install step (e.g., via cache-dependency-path pointing to a
        requirements.lock or requirements*.txt file, or via pip install -r
        requirements.lock).
        """
        workflow_text = CI_WORKFLOW.read_text()

        # Look for a lockfile reference anywhere in the workflow — either as a
        # cache-dependency-path in the setup-python with block, or in a pip
        # install -r command targeting a lockfile.
        lockfile_patterns = [
            "requirements.lock",
            "requirements.txt",
            "requirements-dev.txt",
            "requirements-test.txt",
        ]
        found = any(pattern in workflow_text for pattern in lockfile_patterns)
        assert found, (
            "Expected ci-python-skills.yml to reference a pip lockfile "
            "(requirements.lock, requirements.txt, or similar) but none was found. "
            "Add a lockfile reference to the pip install step or as cache-dependency-path "
            "in the setup-python step to ensure reproducible dependency installs."
        )
