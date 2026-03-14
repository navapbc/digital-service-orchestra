#!/usr/bin/env python3
"""Syntax checker for bash (.sh), YAML (.yml/.yaml), and JSON (.json) files.

Called by: make syntax-check (app/Makefile)
Returns: exit 0 if all files pass, exit 1 with per-file errors on failure.

Uses git ls-files to respect .gitignore automatically.
Uses only stdlib + pyyaml (already a project dependency).
"""

import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml


def git_tracked_files(repo_root: Path, suffixes: tuple[str, ...]) -> list[Path]:
    """Return files matching suffixes that git tracks or would track (respects .gitignore)."""
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"error: git ls-files failed: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    paths = []
    for line in result.stdout.splitlines():
        p = repo_root / line
        if p.suffix in suffixes and p.is_file():
            paths.append(p)
    return sorted(paths)


def _check_one_bash(args: tuple[Path, Path]) -> str | None:
    f, repo_root = args
    result = subprocess.run(["bash", "-n", str(f)], capture_output=True, text=True)
    if result.returncode != 0:
        return f"bash: {f.relative_to(repo_root)}: {result.stderr.strip()}"
    return None


def check_bash(repo_root: Path) -> tuple[list[str], int]:
    files = git_tracked_files(repo_root, (".sh",))
    errors: list[str] = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = pool.map(_check_one_bash, [(f, repo_root) for f in files])
    for err in results:
        if err is not None:
            errors.append(err)
    return errors, len(files)


def check_yaml(repo_root: Path) -> tuple[list[str], int]:
    files = git_tracked_files(repo_root, (".yml", ".yaml"))
    errors = []
    for f in files:
        try:
            # BaseLoader parses structure without resolving tags, so CloudFormation
            # (!GetAtt, !Ref, !Sub) and other custom-tag YAML files are accepted.
            # Still catches conflict markers and malformed structure.
            yaml.load(  # noqa: S506
                f.read_text(encoding="utf-8", errors="replace"),
                Loader=yaml.BaseLoader,
            )
        except yaml.YAMLError as e:
            errors.append(f"yaml: {f.relative_to(repo_root)}: {e}")
    return errors, len(files)


def check_json(repo_root: Path) -> tuple[list[str], int]:
    files = git_tracked_files(repo_root, (".json",))
    errors = []
    for f in files:
        try:
            json.loads(f.read_text(encoding="utf-8", errors="replace"))
        except json.JSONDecodeError as e:
            errors.append(f"json: {f.relative_to(repo_root)}: {e}")
    return errors, len(files)


def main() -> None:
    # Script lives at lockpick-workflow/scripts/check-file-syntax.py
    # parents[0] = lockpick-workflow/scripts/
    # parents[1] = lockpick-workflow/
    # parents[2] = repo root
    repo_root = Path(__file__).resolve().parents[2]

    bash_errors, bash_n = check_bash(repo_root)
    yaml_errors, yaml_n = check_yaml(repo_root)
    json_errors, json_n = check_json(repo_root)
    all_errors = bash_errors + yaml_errors + json_errors

    if all_errors:
        for e in all_errors:
            print(e, file=sys.stderr)
        sys.exit(1)

    print(f"Syntax OK: {bash_n} bash, {yaml_n} yaml, {json_n} json files checked")


if __name__ == "__main__":
    main()
