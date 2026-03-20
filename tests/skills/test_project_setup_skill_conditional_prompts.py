"""Tests for conditional prompt sections in the project-setup SKILL.md.

TDD spec for task w21-b9ll (RED task):
- plugins/dso/skills/project-setup/SKILL.md Step 3 must contain:
  1. Conditional database key prompting section gated on db_present detection output
  2. Reference to db_present (or db_detected / docker_db_detected) as the gating condition
  3. Conditional infrastructure key prompts section
  4. Guidance text explaining infrastructure.required_tools and CLI tool checks at session start
  5. Port inference instructions from docker-compose/env with variable substitution default extraction
  6. Conditional staging.url prompt gated on staging config detection
  7. Python version auto-detection from pyproject.toml, .python-version, or python3 binary

All tests are expected to FAIL until the implementation tasks (w21-gdon, w21-dkes,
w21-t1tt) add the conditional sections to SKILL.md.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "project-setup" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


# ── Test 1: Database conditional section ─────────────────────────────────────


def test_skill_has_database_conditional_section() -> None:
    """SKILL.md Step 3 must contain a conditional database key prompting section.

    The section should be gated on database detection output — prompting for
    database.ensure_cmd, database.status_cmd, infrastructure.db_container,
    and infrastructure.db_port only when the project has a database service.
    This is a RED test — the section does not exist in SKILL.md yet.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "database keys",
            "database key prompts",
            "### Database",
            "### Database keys",
            "conditional database",
            "database prompts",
            "database.ensure_cmd",
            "database.status_cmd",
        )
    ), (
        "Expected SKILL.md to contain a conditional database key prompting section "
        "(e.g., '### Database keys', 'database.ensure_cmd', or 'database prompts') "
        "in Step 3. This section should be gated on DB detection results. "
        "This is a RED test — SKILL.md does not yet contain this section."
    )


# ── Test 2: DB section conditioned on detection output field ─────────────────


def test_database_section_conditioned_on_db_detection() -> None:
    """SKILL.md must reference the db_present (or equivalent) detection output field.

    The conditional database prompting section must reference the detection output
    field used to gate prompting — either db_present (from project-detect.sh schema),
    db_detected, or docker_db_detected. This ensures the wizard only asks database
    questions when the project actually has a database service.
    This is a RED test — SKILL.md does not yet reference any detection gating field.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "db_present",
            "db_detected",
            "docker_db_detected",
            "DETECT_DB",
            "database detected",
            "database service detected",
        )
    ), (
        "Expected SKILL.md to reference a detection output field such as 'db_present', "
        "'db_detected', 'docker_db_detected', or 'DETECT_DB' as the gating condition "
        "for database key prompts. "
        "This is a RED test — SKILL.md does not yet reference any such field."
    )


# ── Test 3: Infrastructure conditional section ────────────────────────────────


def test_skill_has_infrastructure_conditional_section() -> None:
    """SKILL.md Step 3 must contain a conditional infrastructure key prompts section.

    Infrastructure keys (infrastructure.db_container, infrastructure.app_port,
    infrastructure.db_port, infrastructure.container_prefix) should only be
    prompted when the project has container/Docker infrastructure indicators.
    This is a RED test — the section does not exist in SKILL.md yet.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "### Infrastructure",
            "infrastructure keys",
            "infrastructure key prompts",
            "infrastructure section",
            "conditional infrastructure",
            "infrastructure.db_container",
            "infrastructure.app_port",
            "infrastructure.container_prefix",
        )
    ), (
        "Expected SKILL.md to contain a conditional infrastructure key prompts section "
        "(e.g., '### Infrastructure', 'infrastructure.db_container', or "
        "'infrastructure.app_port') in Step 3, gated on container/Docker detection. "
        "This is a RED test — SKILL.md does not yet contain this section."
    )


# ── Test 4: required_tools guidance ──────────────────────────────────────────


def test_skill_has_required_tools_guidance() -> None:
    """SKILL.md Step 3 must explain what infrastructure.required_tools controls.

    The wizard must include guidance text explaining that infrastructure.required_tools
    controls which CLI tools DSO checks for at session start, and that their absence
    produces warnings or errors. This helps users understand the purpose of the key
    before they enter values.
    This is a RED test — SKILL.md does not yet include this guidance.
    """
    content = _read_skill()
    assert "required_tools" in content, (
        "Expected SKILL.md to contain 'required_tools' as part of guidance text "
        "explaining infrastructure.required_tools. "
        "This is a RED test — SKILL.md does not yet contain this reference."
    )
    # Also check that SKILL.md explains what required_tools controls — warnings or errors
    assert any(
        phrase in content
        for phrase in (
            "warnings or errors",
            "warnings",
            "CLI tool checks",
            "session start",
            "required tools",
        )
    ), (
        "Expected SKILL.md to contain guidance text explaining that "
        "infrastructure.required_tools controls CLI tool checks at session start "
        "and that missing tools produce warnings or errors. "
        "This is a RED test — SKILL.md does not yet include this guidance."
    )


# ── Test 5: Port inference instructions ──────────────────────────────────────


def test_skill_has_port_inference_instructions() -> None:
    """SKILL.md must contain instructions for inferring port numbers from project config.

    Port numbers should be inferred from docker-compose port mappings or .env files,
    including handling variable substitution defaults (pattern: ${VAR:-default}).
    This is a RED test — SKILL.md does not yet contain port inference instructions.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "port inference",
            "infer port",
            "inferred from",
            "docker-compose port",
            "port mapping",
            "ports=",
            "DETECT_APP_PORT",
        )
    ), (
        "Expected SKILL.md to contain port inference instructions — e.g., 'port inference', "
        "'infer port', or 'docker-compose port' describing how to extract port numbers "
        "from project config. "
        "This is a RED test — SKILL.md does not yet contain port inference instructions."
    )
    # Check for variable substitution default extraction pattern
    assert any(
        phrase in content
        for phrase in (
            "${",
            ":-",
            "variable substitution",
            "default value",
            "default extraction",
        )
    ), (
        "Expected SKILL.md to contain instructions for extracting defaults from variable "
        "substitution patterns like '${VAR:-default}' when inferring port numbers. "
        "This is a RED test — SKILL.md does not yet reference variable substitution handling."
    )


# ── Test 6: Staging conditional section ──────────────────────────────────────


def test_skill_has_staging_conditional_section() -> None:
    """SKILL.md must contain a conditional staging.url prompt gated on staging detection.

    The staging.url prompt should only appear when staging configuration is detected
    (e.g., a staging URL or environment already exists in the project). When staging
    is not detected, the section is skipped to avoid unnecessary prompting.
    This is a RED test — SKILL.md does not yet contain this conditional section.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "staging.url",
            "### Staging",
            "staging section",
            "staging keys",
            "conditional staging",
            "staging config detected",
            "staging detected",
        )
    ), (
        "Expected SKILL.md to contain a conditional staging.url prompt section "
        "(e.g., '### Staging', 'staging.url', or 'staging config detected') "
        "gated on staging configuration detection. "
        "This is a RED test — SKILL.md does not yet contain this section."
    )


# ── Test 7: Python version auto-detection ────────────────────────────────────


def test_skill_has_python_version_autodetection() -> None:
    """SKILL.md must reference auto-detecting Python version from project files.

    When setting up a Python project, SKILL.md must instruct the agent to auto-detect
    the Python version from pyproject.toml, .python-version, or the python3 binary,
    and pre-fill the worktree.python_version field rather than asking the user to
    type a version string manually.
    This is a RED test — SKILL.md does not yet reference Python version auto-detection.
    """
    content = _read_skill()
    assert any(
        phrase in content
        for phrase in (
            "python_version",
            "worktree.python_version",
            "auto-detect",
            "auto-detected",
            "python version",
            "Python version",
        )
    ), (
        "Expected SKILL.md to reference auto-detecting Python version "
        "(e.g., 'worktree.python_version', 'auto-detect', or 'Python version') "
        "from pyproject.toml, .python-version, or the python3 binary. "
        "This is a RED test — SKILL.md does not yet reference Python version auto-detection."
    )
    # Also check that at least one source file is referenced
    assert any(
        phrase in content
        for phrase in (
            "pyproject.toml",
            ".python-version",
            "python3",
            "python_version=",
        )
    ), (
        "Expected SKILL.md to reference the source files for Python version detection: "
        "pyproject.toml, .python-version, or python3 binary. "
        "This is a RED test — SKILL.md does not yet name these detection sources."
    )
