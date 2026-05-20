"""dso_ci_review.file_filter — Pre-filter non-reviewable files.

Filters a list of file paths into reviewable and skipped sets before
dispatching to LLM specialists. Three filter layers are applied in order:

1. Linguist tags from .gitattributes (linguist-generated, linguist-vendored,
   linguist-documentation) — skip with reason "linguist:<tag>"
2. Default + configured ignore.glob patterns — skip with reason
   "ignore.glob:<pattern>"
3. Configured ignore.regex patterns — skip with reason "ignore.regex:<pattern>"

All three layers are ADDITIVE (not replacing each other). A file skipped by
linguist tags is still reported even if it also matches a glob pattern —
first-match-wins determines which reason is recorded.

Story 1608-4d8c-da53-47bc: large PRs reviewed via chunked file-level dispatch
with LLM aggregation.
Task 9bba-3160-a849-45ef: S7.T2 Implement file_filter.py (GREEN)
"""

from __future__ import annotations

import fnmatch
import re
import warnings
from pathlib import Path


# ---------------------------------------------------------------------------
# Default ignore glob patterns (applied even without operator config)
# ---------------------------------------------------------------------------

DEFAULT_IGNORE_GLOBS: list[str] = [
    "**/package-lock.json",
    "**/yarn.lock",
    "**/poetry.lock",
    "**/go.sum",
]


# ---------------------------------------------------------------------------
# .gitattributes parser
# ---------------------------------------------------------------------------

_LINGUIST_TAGS = frozenset(
    [
        "linguist-generated",
        "linguist-vendored",
        "linguist-documentation",
    ]
)


def parse_gitattributes_linguist_tags(
    gitattributes_path: Path | str,
) -> dict[str, list[str]]:
    """Parse a .gitattributes file and extract paths with linguist tags.

    Returns a dict mapping file path (as specified in .gitattributes) to a
    list of matched linguist tag names.

    Lines beginning with '#' are treated as comments and ignored.
    Non-linguist attributes (text, eol, etc.) are silently ignored.

    Args:
        gitattributes_path: Path object or string path to the .gitattributes
            file to parse.

    Returns:
        Dict mapping pattern -> list[str] of linguist tag names found on that
        pattern. Only patterns with at least one linguist tag are included.
    """
    path = Path(gitattributes_path)
    result: dict[str, list[str]] = {}

    if not path.is_file():
        return result

    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return result

    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # Each non-comment line has the format:
        #   <pattern>  <attr1>=<val1>  <attr2>=<val2>  ...
        parts = stripped.split()
        if len(parts) < 2:
            continue

        file_pattern = parts[0]
        attrs = parts[1:]

        found_tags: list[str] = []
        for attr in attrs:
            # Attributes can appear as:
            #   linguist-generated=true   (set to value)
            #   linguist-generated        (set flag, no value)
            #   -linguist-generated       (unset)
            attr_name = attr.split("=", 1)[0].lstrip("-")
            if attr_name in _LINGUIST_TAGS:
                # Only include if not explicitly unset (prefixed with -)
                if not attr.startswith("-"):
                    found_tags.append(attr_name)

        if found_tags:
            result[file_pattern] = found_tags

    return result


# ---------------------------------------------------------------------------
# Config loader
# ---------------------------------------------------------------------------


def load_filter_config(config_path: str | None = None) -> dict:
    """Load and validate file_filter configuration from dso-config.conf.

    Reads the following keys (all optional):
      review.file_filter.max_files   — max files to send to LLM review
      review.file_filter.max_calls   — max LLM dispatch calls
      review.file_filter.ignore.glob — additional glob pattern (additive)
      review.file_filter.ignore.regex — additional regex pattern (additive)

    Validation:
      - max_files=0: emits UserWarning (does not raise)
      - max_calls=0: emits UserWarning (does not raise)

    Returns a dict of resolved config values. Unknown keys are ignored.
    """
    config: dict = {
        "max_files": None,
        "max_calls": None,
        "ignore_globs": [],
        "ignore_regexes": [],
    }

    if config_path is None:
        return config

    try:
        with open(config_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()

                if key == "review.file_filter.max_files":
                    try:
                        config["max_files"] = int(value)
                    except ValueError:
                        pass
                elif key == "review.file_filter.max_calls":
                    try:
                        config["max_calls"] = int(value)
                    except ValueError:
                        pass
                elif key == "review.file_filter.ignore.glob":
                    config["ignore_globs"].append(value)
                elif key == "review.file_filter.ignore.regex":
                    config["ignore_regexes"].append(value)
    except (OSError, UnicodeDecodeError):
        pass

    # Emit warnings for zero values (likely misconfiguration)
    if config["max_files"] == 0:
        warnings.warn(
            "review.file_filter.max_files=0 means no files will be reviewed; "
            "this is likely a misconfiguration.",
            UserWarning,
            stacklevel=2,
        )
    if config["max_calls"] == 0:
        warnings.warn(
            "review.file_filter.max_calls=0 means no LLM calls will be dispatched; "
            "this is likely a misconfiguration.",
            UserWarning,
            stacklevel=2,
        )

    return config


# ---------------------------------------------------------------------------
# Glob matching helper
# ---------------------------------------------------------------------------


def _matches_glob(file_path: str, pattern: str) -> bool:
    """Return True if file_path matches pattern using fnmatch with **/ support.

    Patterns starting with '**/' are treated as suffix matches — the pattern
    after '**/' is checked against the basename (and any path suffix).
    Plain patterns are matched against the full path and also the basename.
    """
    # Normalize to forward slashes
    fp = file_path.replace("\\", "/")

    # If pattern has **/ prefix, match against any trailing portion
    if pattern.startswith("**/"):
        suffix_pattern = pattern[3:]  # strip the "**/"
        # Match the full path via fnmatch (e.g. "a/b/package-lock.json")
        if fnmatch.fnmatch(fp, pattern):
            return True
        # Also match if the basename matches the suffix_pattern
        basename = fp.rsplit("/", 1)[-1]
        if fnmatch.fnmatch(basename, suffix_pattern):
            return True
        # Match any trailing path segment
        if fnmatch.fnmatch(fp, f"*/{suffix_pattern}"):
            return True
        return False

    # Standard fnmatch against full path and basename
    if fnmatch.fnmatch(fp, pattern):
        return True
    basename = fp.rsplit("/", 1)[-1]
    if fnmatch.fnmatch(basename, pattern):
        return True
    return False


# ---------------------------------------------------------------------------
# Main filter function
# ---------------------------------------------------------------------------


def filter_files(
    file_paths: list[str],
    config: dict | None = None,
    repo_root: Path | str | None = None,
) -> tuple[list[str], list[tuple[str, str]]]:
    """Filter file paths into reviewable and skipped sets.

    Three filter layers applied in order (all additive):
      1. Linguist tags from .gitattributes in repo_root
      2. Default ignore globs (DEFAULT_IGNORE_GLOBS)
      3. Custom ignore.glob and ignore.regex from config

    Args:
        file_paths: List of relative file paths to filter.
        config: Optional pre-loaded config dict from load_filter_config().
            If None, no custom glob/regex config is applied but defaults
            still apply. If repo_root contains a .claude/dso-config.conf,
            it will be auto-loaded when config is None.
        repo_root: Repository root path. Used to find .gitattributes and
            auto-load config when config is None.

    Returns:
        A 2-tuple (reviewable, skipped_with_reasons):
          - reviewable: list of file paths that should be reviewed
          - skipped_with_reasons: list of (path, reason) tuples for
            files that were filtered out
    """
    if not file_paths:
        return [], []

    repo_root_path = Path(repo_root) if repo_root is not None else None

    # Auto-load config from repo_root if not provided
    if config is None and repo_root_path is not None:
        config_file = repo_root_path / ".claude" / "dso-config.conf"
        if config_file.is_file():
            config = load_filter_config(config_path=str(config_file))

    if config is None:
        config = {}

    # Merge ignore globs: defaults first, then custom (additive)
    all_globs = list(DEFAULT_IGNORE_GLOBS) + list(config.get("ignore_globs", []))
    all_regexes = list(config.get("ignore_regexes", []))

    # Parse linguist tags from .gitattributes
    linguist_tags: dict[str, list[str]] = {}
    if repo_root_path is not None:
        ga_path = repo_root_path / ".gitattributes"
        linguist_tags = parse_gitattributes_linguist_tags(ga_path)

    reviewable: list[str] = []
    skipped: list[tuple[str, str]] = []

    for file_path in file_paths:
        skip_reason: str | None = None

        # Layer 1: linguist tags from .gitattributes
        if skip_reason is None:
            for pattern, tags in linguist_tags.items():
                if _matches_glob(file_path, pattern):
                    # Report first matching tag
                    skip_reason = f"linguist:{tags[0]}"
                    break

        # Layer 2: default + custom ignore globs
        if skip_reason is None:
            for glob_pattern in all_globs:
                if _matches_glob(file_path, glob_pattern):
                    skip_reason = f"ignore.glob:{glob_pattern}"
                    break

        # Layer 3: custom ignore regexes
        if skip_reason is None:
            for regex_pattern in all_regexes:
                try:
                    if re.search(regex_pattern, file_path):
                        skip_reason = f"ignore.regex:{regex_pattern}"
                        break
                except re.error:
                    # Malformed regex — skip silently
                    pass

        if skip_reason is not None:
            skipped.append((file_path, skip_reason))
        else:
            reviewable.append(file_path)

    return reviewable, skipped
