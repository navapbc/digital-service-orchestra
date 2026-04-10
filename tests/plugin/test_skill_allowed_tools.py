"""
RED test: all SKILL.md files must have `allowed-tools` frontmatter field.

Claude Code's plugin system classifies SKILL.md files as proper "skills"
(with Skill tool content injection) only when they have `allowed-tools` in
their YAML frontmatter. Files without this field are classified as "agents":
they appear in the system-reminder but the Skill tool returns only a terse
"Launching skill: X" string without injecting the skill body (silent
injection failure).

This test enforces that every SKILL.md file in plugins/dso/skills/ has the
`allowed-tools` frontmatter key so Claude Code classifies them as skills.

Reference: Bug 06fc-1ebc — only 3 DSO skills visible in host projects because
only 3 SKILL.md files had `allowed-tools` (playwright-debug, preplanning,
ui-discover). The other 29 were classified as "agents" by Claude Code.
"""

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILLS_DIR = REPO_ROOT / "plugins" / "dso" / "skills"
EXCLUDED_DIRS = {"shared"}


def _parse_frontmatter_keys(skill_md_path: Path) -> set:
    """Return the set of frontmatter keys from a SKILL.md file.

    Parses only the YAML frontmatter block (between opening and closing ---).
    Returns an empty set if no frontmatter is found.
    """
    content = skill_md_path.read_text(encoding="utf-8")
    if not content.startswith("---"):
        return set()
    parts = content.split("---", 2)
    if len(parts) < 3:
        return set()
    keys: set = set()
    for line in parts[1].splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if ":" in stripped and not stripped.startswith(" "):
            key = stripped.split(":", 1)[0].strip()
            if key:
                keys.add(key)
    return keys


def _all_skill_md_files():
    """Collect all SKILL.md paths from skills/ (excluding shared/)."""
    paths = []
    for skill_dir in sorted(SKILLS_DIR.iterdir()):
        if not skill_dir.is_dir():
            continue
        if skill_dir.name in EXCLUDED_DIRS:
            continue
        skill_md = skill_dir / "SKILL.md"
        if skill_md.exists():
            paths.append(skill_md)
    return paths


@pytest.mark.parametrize(
    "skill_md",
    _all_skill_md_files(),
    ids=lambda p: p.parent.name,
)
def test_skill_has_allowed_tools_frontmatter(skill_md: Path) -> None:
    """SKILL.md must declare `allowed-tools` in its YAML frontmatter.

    Without `allowed-tools`, Claude Code's plugin loader classifies the file
    as an "agent" instead of a "skill". Agents are listed in the system
    context but the Skill tool does not inject their content on invocation —
    it returns only "Launching skill: <name>" (a silent injection failure).

    Adding `allowed-tools` (even with an empty value) causes Claude Code to
    register the file as a proper skill with full content injection.
    """
    frontmatter_keys = _parse_frontmatter_keys(skill_md)
    assert "allowed-tools" in frontmatter_keys, (
        f"{skill_md.parent.name}/SKILL.md is missing the `allowed-tools` "
        f"frontmatter field. Claude Code classifies SKILL.md files without "
        f"this field as 'agents', preventing Skill tool content injection. "
        f"Add `allowed-tools:` to the frontmatter (empty value is acceptable). "
        f"Found frontmatter keys: {sorted(frontmatter_keys)}"
    )
