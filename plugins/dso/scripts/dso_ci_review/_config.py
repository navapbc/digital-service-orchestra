"""dso_ci_review._config — shared config-reading helpers.

This is a leaf module: it imports only stdlib and is depended on by both
``runner.py`` and ``region_split.py``. It exists to eliminate the previous
verbatim duplication of `_default_config_path` and `_read_config_int` across
those modules (PR #169 review f-duplicated-helpers — drift risk that
inevitably bites a future format change, e.g. mid-line comments / env-var
interpolation / default-path lookup change).

Anything added here must NOT import from runner or region_split — both
modules import from us, so a cycle would break the whole CI review path.
"""

from __future__ import annotations

import os


def default_config_path() -> str:
    """Return the canonical dso-config.conf path for the repo containing
    this module.

    The module lives 5 dirname levels below ``<repo>/.claude/dso-config.conf``:
    _config.py → dso_ci_review/ → scripts/ → dso/ → plugins/ → repo_root/
    """
    return os.path.join(
        os.path.dirname(
            os.path.dirname(
                os.path.dirname(
                    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                )
            )
        ),
        ".claude",
        "dso-config.conf",
    )


def read_config_int(key: str, default: int, config_path: str | None = None) -> int:
    """Read an integer config value from dso-config.conf.

    Resolution order:
      1. ``key=<value>`` in ``config_path`` (or auto-detected repo config)
      2. ``default`` (returned when key absent or value not a valid integer)

    The reader treats any line beginning with ``#`` (after stripping
    leading whitespace) as a comment, and silently ignores malformed
    lines.
    """
    if config_path is None:
        config_path = default_config_path()

    if os.path.isfile(config_path):
        try:
            with open(config_path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    parts = line.split("=", 1)
                    if len(parts) == 2 and parts[0].strip() == key:
                        value = parts[1].strip()
                        try:
                            return int(value)
                        except ValueError:
                            return default
        except (OSError, UnicodeDecodeError):
            return default
    return default


# Truthy / falsy literals accepted for boolean config values (case-insensitive).
_TRUE_LITERALS: frozenset[str] = frozenset({"1", "true", "yes", "on"})
_FALSE_LITERALS: frozenset[str] = frozenset({"0", "false", "no", "off"})


def read_config_bool(
    key: str, default: bool, config_path: str | None = None
) -> bool:
    """Read a boolean config value from dso-config.conf.

    Resolution order:
      1. ``key=<value>`` in ``config_path`` (or auto-detected repo config),
         parsed case-insensitively against the true/false literal sets
         (``1/true/yes/on`` and ``0/false/no/off``).
      2. ``default`` (returned when key absent, value unrecognized, or the
         config is unreadable).

    Mirrors ``read_config_int``'s comment-handling and fail-to-default
    semantics so boolean and integer keys behave consistently.
    """
    if config_path is None:
        config_path = default_config_path()

    if os.path.isfile(config_path):
        try:
            with open(config_path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    parts = line.split("=", 1)
                    if len(parts) == 2 and parts[0].strip() == key:
                        value = parts[1].strip().lower()
                        if value in _TRUE_LITERALS:
                            return True
                        if value in _FALSE_LITERALS:
                            return False
                        return default
        except (OSError, UnicodeDecodeError):
            return default
    return default
