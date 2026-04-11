"""
Regression guard: all SKILL.md files must have `allowed-tools` with a non-null value.

Claude Code's plugin system classifies SKILL.md files as proper "skills"
(with Skill tool content injection) only when `allowed-tools` is PRESENT
and has a non-null, non-empty value (a space-separated string or a YAML list
of tool names). Both absent AND null values cause the skill to be silently
skipped — it does not appear in the /reload-plugins skill count.

History of this bug:
  - Bug 06fc-1ebc: 29 SKILL.md files had no `allowed-tools` → 3 skills loaded
  - Fix attempt (5418956e): added `allowed-tools:` (bare null YAML key) → still 3 skills
    The null value parses as Python None, which the loader treats the same as absent.
  - Bug 9a3b-7426 (this guard): fix the fix — set a non-null value for all 29 files.

Correct patterns:
  - `allowed-tools: Read, Grep, Glob, Bash, Write, Edit, Task, AskUserQuestion`
  - `allowed-tools:\\n  - Read\\n  - Grep`   (YAML list)

Invalid patterns that cause silent skill-skip:
  - `allowed-tools:`   ← parses as None (YAML null)
  - (field absent)     ← treated same as null by plugin loader
"""

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILLS_DIR = REPO_ROOT / "plugins" / "dso" / "skills"
EXCLUDED_DIRS = {"shared"}


def _parse_frontmatter(skill_md_path: Path) -> dict:
    """Return the parsed YAML frontmatter dict from a SKILL.md file.

    Parses the YAML frontmatter block (between opening and closing ---).
    Returns an empty dict if no frontmatter is found or parsing fails.
    """
    content = skill_md_path.read_text(encoding="utf-8")
    if not content.startswith("---"):
        return {}
    parts = content.split("---", 2)
    if len(parts) < 3:
        return {}
    try:
        parsed = yaml.safe_load(parts[1])
        return parsed if isinstance(parsed, dict) else {}
    except yaml.YAMLError:
        return {}


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
def test_skill_allowed_tools_not_null(skill_md: Path) -> None:
    """If `allowed-tools` is present in SKILL.md frontmatter, its value must not be null.

    A bare `allowed-tools:` key (null YAML value) causes Claude Code's plugin
    loader to silently skip the skill — it does not appear in /reload-plugins
    skill count and the Skill tool cannot inject its content.

    The field is optional. If you want to allow all tools, omit it entirely.
    If you need to restrict or pre-approve specific tools, set a non-empty
    space-separated string or YAML list.
    """
    frontmatter = _parse_frontmatter(skill_md)
    if "allowed-tools" not in frontmatter:
        return  # Field absent is valid: means "all tools allowed"

    value = frontmatter["allowed-tools"]
    assert value is not None and value != "" and value != [], (
        f"{skill_md.parent.name}/SKILL.md has `allowed-tools:` with a null or "
        f"empty value ({value!r}). The Claude Code plugin loader silently skips "
        f"skills with null `allowed-tools` — they will not appear in "
        f"/reload-plugins skill count. Either remove the `allowed-tools:` line "
        f"entirely (recommended for skills that allow all tools) or set a "
        f"non-empty value: `allowed-tools: Read, Grep, Glob, Bash, Write, Edit, "
        f"Task, AskUserQuestion`"
    )
