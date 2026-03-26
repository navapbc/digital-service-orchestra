#!/usr/bin/env python3
"""blast-radius-score.py — Compute blast-radius score for a set of changed file paths.

Reads file paths from stdin (one per line) and outputs a JSON object:
  {
    "score": <int>,
    "signals": [<str>, ...],
    "complex_override": <bool>,
    "layer_count": <int>,
    "change_type": "<additive|subtractive|substitutive|mixed>"
  }

Score is computed from:
  - Known high-impact config/entry/wiring file patterns (KNOWN_PATTERNS)
  - Path depth (shallow paths score higher)
  - Directory conventions (config/, utils/, shared/, lib/, pkg/, internal/, cmd/)
  - Layer count (number of distinct top-level directories)

Default threshold: 5. complex_override=True when score > threshold.
"""

import json
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# KNOWN_PATTERNS: module-level dict mapping glob-style basename patterns to
# their blast-radius weight (higher = more impactful).
# ≥ 40 cross-stack patterns required.
# ---------------------------------------------------------------------------
KNOWN_PATTERNS: dict[str, int] = {
    # Entry points / main wiring
    "main.py": 3,
    "main.go": 3,
    "main.rs": 3,
    "main.ts": 3,
    "main.js": 3,
    "main.rb": 3,
    "main.java": 3,
    "main.kt": 3,
    "main.swift": 3,
    "main.c": 3,
    "main.cpp": 3,
    # Routing / URL wiring
    "routes.py": 3,
    "routes.ts": 3,
    "routes.js": 3,
    "router.ts": 3,
    "router.js": 3,
    "urls.py": 3,
    # Application entry / bootstrap
    "app.py": 3,
    "app.ts": 3,
    "app.js": 3,
    "app.rb": 2,
    "application.py": 2,
    "bootstrap.php": 2,
    # Index files (TypeScript / JavaScript)
    "index.ts": 2,
    "index.js": 2,
    "index.tsx": 2,
    "index.jsx": 2,
    # Library roots (Rust)
    "lib.rs": 3,
    # WSGI / ASGI entry
    "wsgi.py": 3,
    "asgi.py": 3,
    # Middleware / models / schema
    "middleware.py": 2,
    "models.py": 2,
    "schema.py": 2,
    "schemas.py": 2,
    # Dependency / build manifests
    "Cargo.toml": 3,
    "Cargo.lock": 1,
    "pyproject.toml": 3,
    "setup.cfg": 2,
    "setup.py": 2,
    "package.json": 2,
    "package-lock.json": 1,
    "yarn.lock": 1,
    "pnpm-lock.yaml": 1,
    "go.mod": 2,
    "go.sum": 1,
    "requirements.txt": 2,
    "Pipfile": 2,
    "Pipfile.lock": 1,
    "Gemfile": 2,
    "Gemfile.lock": 1,
    "pom.xml": 2,
    "build.gradle": 2,
    "build.rs": 2,
    # Build / infra config
    "Makefile": 2,
    "makefile": 2,
    "CMakeLists.txt": 2,
    "Dockerfile": 3,
    "docker-compose.yml": 3,
    "docker-compose.yaml": 3,
    "docker-compose.override.yml": 2,
    # JavaScript / TypeScript bundler / framework config
    "next.config.js": 3,
    "next.config.ts": 3,
    "next.config.mjs": 3,
    "webpack.config.js": 3,
    "webpack.config.ts": 3,
    "vite.config.js": 2,
    "vite.config.ts": 2,
    "rollup.config.js": 2,
    "rollup.config.ts": 2,
    "babel.config.js": 2,
    "babel.config.json": 2,
    ".babelrc": 2,
    "tsconfig.json": 2,
    "jsconfig.json": 2,
    "jest.config.js": 1,
    "jest.config.ts": 1,
    "vitest.config.ts": 1,
    # CI / workflow files (matched by directory prefix in scoring logic)
    ".github/workflows": 3,
    # Settings / configuration files
    "settings.py": 2,
    "config.py": 2,
    "config.go": 2,
    "config.rs": 2,
    "config.ts": 2,
    "config.js": 2,
    "configuration.py": 2,
    "conf.py": 2,
    "conftest.py": 1,
    "celery.py": 2,
    # Infrastructure as code
    "terraform.tf": 3,
    "main.tf": 3,
    "variables.tf": 2,
    "outputs.tf": 2,
    "k8s.yaml": 2,
    "k8s.yml": 2,
    "helm.yaml": 2,
    ".env": 2,
    ".env.example": 1,
}

# Directory conventions that boost blast radius (lower score contribution
# since these are often shared / cross-cutting)
HIGH_IMPACT_DIRS: set[str] = {
    "config",
    "configs",
    "shared",
    "lib",
    "libs",
    "pkg",
    "pkgs",
    "internal",
    "cmd",
    "core",
    "common",
    "utils",
    "util",
    "helpers",
    "infrastructure",
    "infra",
    "platform",
}

THRESHOLD = 5


def _path_depth_score(path: str) -> int:
    """Shallower paths score higher (max 3 at root, min 0 for very deep)."""
    parts = Path(path).parts
    depth = len(parts) - 1  # 0 = root-level file
    if depth == 0:
        return 3
    if depth == 1:
        return 2
    if depth == 2:
        return 1
    return 0


def _pattern_score(path: str) -> tuple[int, list[str]]:
    """Return (score, signals) for known patterns matching this path."""
    score = 0
    signals: list[str] = []
    basename = Path(path).name
    path_lower = path.lower()

    # Direct basename match
    if basename in KNOWN_PATTERNS:
        pts = KNOWN_PATTERNS[basename]
        score += pts
        signals.append(f"known_pattern:{basename}(+{pts})")

    # Prefix match for directory-based patterns (e.g. ".github/workflows")
    for pattern, pts in KNOWN_PATTERNS.items():
        if "/" in pattern and path_lower.startswith(pattern.lower()):
            score += pts
            signals.append(f"dir_pattern:{pattern}(+{pts})")
            break

    return score, signals


def _dir_convention_score(path: str) -> tuple[int, list[str]]:
    """Boost score if any path component is a high-impact directory."""
    parts = Path(path).parts
    score = 0
    signals: list[str] = []
    for part in parts[:-1]:  # skip basename
        if part.lower() in HIGH_IMPACT_DIRS:
            score += 1
            signals.append(f"impact_dir:{part}(+1)")
            break  # count once per file
    return score, signals


def _detect_change_type(paths: list[str]) -> str:
    """Infer change type from file set heuristics.

    Heuristic: if the file set contains only additions (new files without
    corresponding deletions — we cannot know deletions from stdin alone,
    so we classify based on content patterns):

    Since we only receive a flat list of paths we use naming hints:
      - 'new_*', '*_add*', '*_create*' → additive
      - 'delete_*', 'remove_*', '*_del*' → subtractive
      - mix of test + source files with no config → substitutive
      - multiple top-level dirs + config files → mixed

    When signals are ambiguous, default to 'mixed' for multi-file sets,
    'substitutive' for single-file or same-dir sets.
    """
    if not paths:
        return "additive"

    names_lower = [Path(p).name.lower() for p in paths]
    dirs = {Path(p).parts[0] for p in paths if len(Path(p).parts) > 1}

    additive_hints = sum(
        1 for n in names_lower if re.search(r"(^new_|_add|_create|_insert)", n)
    )
    subtractive_hints = sum(
        1 for n in names_lower if re.search(r"(^delete_|^remove_|_del_|_rm_)", n)
    )

    has_config = any(n in KNOWN_PATTERNS for n in names_lower)
    has_test = any(
        re.search(r"(test_|_test\.|spec\.|\.spec\.)", n) for n in names_lower
    )
    multi_dir = len(dirs) >= 2

    if additive_hints > 0 and subtractive_hints == 0:
        return "additive"
    if subtractive_hints > 0 and additive_hints == 0:
        return "subtractive"
    if len(paths) == 1:
        return "substitutive"
    if multi_dir and (has_config or has_test):
        return "mixed"
    if has_config and has_test:
        return "mixed"
    if multi_dir:
        return "mixed"
    return "substitutive"


def compute_blast_radius(paths: list[str]) -> dict:
    """Compute blast-radius score for a list of file paths."""
    if not paths:
        return {
            "score": 0,
            "signals": [],
            "complex_override": False,
            "layer_count": 0,
            "change_type": "additive",
        }

    total_score = 0
    all_signals: list[str] = []
    top_level_dirs: set[str] = set()

    for path in paths:
        parts = Path(path).parts
        if len(parts) > 1:
            top_level_dirs.add(parts[0])
        # root-level files count as their own "layer"
        else:
            top_level_dirs.add("<root>")

        depth_pts = _path_depth_score(path)
        pattern_pts, pattern_sigs = _pattern_score(path)
        dir_pts, dir_sigs = _dir_convention_score(path)

        file_score = depth_pts + pattern_pts + dir_pts
        total_score += file_score
        all_signals.extend(pattern_sigs + dir_sigs)

    layer_count = len(top_level_dirs)
    # Bonus for wide cross-layer blast
    if layer_count >= 3:
        total_score += layer_count - 2
        all_signals.append(f"cross_layer_bonus:+{layer_count - 2}")

    change_type = _detect_change_type(paths)
    complex_override = total_score > THRESHOLD

    return {
        "score": total_score,
        "signals": all_signals,
        "complex_override": complex_override,
        "layer_count": layer_count,
        "change_type": change_type,
    }


def main() -> None:
    raw = sys.stdin.read()
    paths = [line.strip() for line in raw.splitlines() if line.strip()]
    result = compute_blast_radius(paths)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
