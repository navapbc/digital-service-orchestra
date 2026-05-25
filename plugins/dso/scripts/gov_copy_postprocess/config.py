"""Config loader for gov-copy post-processor.

Reads flat dot-notation `key=value` config files (the canonical DSO format
parsed by `${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh`). Keys expected:

    gov_copy.banned_words = utilize,leverage,facilitate
    gov_copy.fk_max = 8
    gov_copy.closing_ratio = 0.95

INI section headers (e.g. `[gov_copy]`) are NOT supported — they would be
silently ignored by read-config.sh and produce empty values here too.
"""
from dataclasses import dataclass
from pathlib import Path


class ConfigError(Exception):
    pass


@dataclass
class GovCopyConfig:
    banned_words: set[str]
    fk_max: int
    closing_ratio: float


_REQUIRED_KEYS = ("gov_copy.banned_words", "gov_copy.fk_max", "gov_copy.closing_ratio")


def _parse_flat_conf(path: Path) -> dict[str, str]:
    """Parse a flat `key=value` config file. Skips blank lines, comments (#), and
    INI section headers (lines starting with '['). Whitespace around the '=' is
    tolerated to match read-config.sh permissive behavior."""
    out: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


def load_gov_copy_config(config_path) -> GovCopyConfig:
    """Load gov_copy.* keys from a flat dot-notation config file.

    Raises ConfigError when the file is missing, when any of the three required
    keys (`gov_copy.banned_words`, `gov_copy.fk_max`, `gov_copy.closing_ratio`)
    is absent, or when an integer/float value fails to parse.
    """
    path = Path(config_path)
    if not path.exists():
        raise ConfigError(f"config file not found: {path}")
    flat = _parse_flat_conf(path)
    missing = [k for k in _REQUIRED_KEYS if k not in flat]
    if missing:
        raise ConfigError(
            f"missing required gov_copy.* keys in {path}: {', '.join(missing)}"
        )
    try:
        banned_words_raw = flat["gov_copy.banned_words"]
        banned_words = {w.strip() for w in banned_words_raw.split(",") if w.strip()}
        fk_max = int(flat["gov_copy.fk_max"])
        closing_ratio = float(flat["gov_copy.closing_ratio"])
    except (ValueError, TypeError) as e:
        raise ConfigError(f"invalid config value in {path}: {e}") from e
    return GovCopyConfig(banned_words=banned_words, fk_max=fk_max, closing_ratio=closing_ratio)
