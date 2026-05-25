"""Config loader for gov-copy post-processor."""
import configparser
from dataclasses import dataclass
from pathlib import Path


class ConfigError(Exception):
    pass


@dataclass
class GovCopyConfig:
    banned_words: set[str]
    fk_max: int
    closing_ratio: float


def load_gov_copy_config(config_path) -> GovCopyConfig:
    """Load [gov_copy] block from the explicit config file path. Raises ConfigError on errors."""
    path = Path(config_path)
    if not path.exists():
        raise ConfigError(f"config file not found: {path}")
    parser = configparser.ConfigParser()
    parser.read(path)
    if "gov_copy" not in parser:
        raise ConfigError(f"missing [gov_copy] section in {path}")
    section = parser["gov_copy"]
    try:
        banned_words_raw = section.get("banned_words", "")
        banned_words = {w.strip() for w in banned_words_raw.split(",") if w.strip()}
        fk_max = section.getint("fk_max")
        closing_ratio = section.getfloat("closing_ratio")
    except (ValueError, configparser.NoOptionError, TypeError) as e:
        raise ConfigError(f"invalid config value: {e}") from e
    return GovCopyConfig(banned_words=banned_words, fk_max=fk_max, closing_ratio=closing_ratio)
