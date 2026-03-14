#!/usr/bin/env python3
"""Task classification scoring engine.

Reads task JSON from stdin, scores against YAML agent profiles,
and outputs enriched classification JSON.
"""

import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "Error: PyYAML is required. Run via classify-task.sh or "
        "'cd app && poetry run python ../scripts/classify-task.py'",
        file=sys.stderr,
    )
    sys.exit(1)


def load_profiles(profiles_dir: Path) -> list[dict]:
    """Load all *.yaml files from profiles_dir, skipping test-cases.yaml.

    Returns profiles sorted by filename for deterministic ordering,
    each augmented with a _file key.
    """
    profiles = []
    for yaml_file in sorted(profiles_dir.glob("*.yaml")):
        if yaml_file.name == "test-cases.yaml":
            continue
        with open(yaml_file) as f:
            profile = yaml.safe_load(f)
        profile["_file"] = yaml_file.name
        profiles.append(profile)
    return profiles


def count_keyword_matches(text: str, keywords: list[str]) -> int:
    """Count how many keywords appear in the lowercase text.

    For multi-word keywords (contain space) or short keywords (<=3 chars):
        use simple substring 'in' check.
    For single-word keywords: use re.search with word boundaries to avoid
        spurious matches (e.g. "path" matching "paths").
    """
    text_lower = text.lower()
    count = 0
    for kw in keywords:
        kw_lower = kw.lower()
        if " " in kw_lower or len(kw_lower) <= 3:
            if kw_lower in text_lower:
                count += 1
        else:
            if re.search(r"\b" + re.escape(kw_lower) + r"\b", text_lower):
                count += 1
    return count


def score_task_against_profile(text: str, profile: dict) -> int:
    """Score a task text against a profile.

    Score = (strong × 3) + (moderate × 2) + (weak × 1) - (negative × 3)
    """
    keywords = profile.get("keywords", {})
    strong = keywords.get("strong") or []
    moderate = keywords.get("moderate") or []
    weak = keywords.get("weak") or []
    negative = profile.get("negative") or []

    score = (
        count_keyword_matches(text, strong) * 3
        + count_keyword_matches(text, moderate) * 2
        + count_keyword_matches(text, weak) * 1
        - count_keyword_matches(text, negative) * 3
    )
    return score


def compute_complexity(
    passing_profile_count: int, blocks_count: int, description: str
) -> str:
    """Compute complexity based on three signals; any 2 of 3 → 'high'.

    Signal 1: 3+ profiles pass min_score (task spans multiple domains)
    Signal 2: blocks_count >= 2 (task is a high fan-out blocker)
    Signal 3: 3+ distinct directory paths found in the description
    """
    signal1 = passing_profile_count >= 3

    signal2 = blocks_count >= 2

    # Signal 3: 3+ distinct directories found in description
    dir_pattern = re.compile(r"(?:src|tests|app|scripts|\.claude)/[^\s/\"',)]*/")
    dirs_found = set(dir_pattern.findall(description))
    signal3 = len(dirs_found) >= 3

    signals_true = sum([signal1, signal2, signal3])
    return "high" if signals_true >= 2 else "low"


def _is_bug_type(task: dict) -> bool:
    """Check if task is a bug-type ticket.

    Checks the task_type field (from structured input) and also falls back
    to scanning the raw ticket content for the YAML front-matter 'type: bug'.
    """
    task_type = task.get("task_type", "")
    if task_type == "bug":
        return True
    # Fall back to checking raw content for front-matter type field
    raw = task.get("raw", "")
    if raw:
        for line in raw.splitlines():
            stripped = line.strip()
            if stripped.startswith("type:") and "bug" in stripped:
                return True
    return False


def classify_task(task: dict, profiles: list[dict]) -> dict:
    """Classify a single task against all profiles and return enriched dict."""
    title = task.get("title", "")
    description = task.get("description", "")
    acceptance_criteria = task.get("acceptance_criteria", "")
    blocks = task.get("blocks", 0)
    blocks_count = len(blocks) if isinstance(blocks, list) else int(blocks or 0)
    is_bug = _is_bug_type(task)

    text = (title + " " + description + " " + acceptance_criteria).lower()

    # Score each profile
    scores: dict[str, int] = {}
    passing: list[dict] = []

    for profile in profiles:
        score = score_task_against_profile(text, profile)
        agent_type = profile["agent_type"]
        if score > 0:
            scores[agent_type] = score
        min_score = profile.get("min_score", 3)
        if score >= min_score:
            passing.append(profile)

    # Sort passing profiles by (score, base_priority) descending.
    # Highest score wins; base_priority breaks ties.
    passing.sort(
        key=lambda p: (
            scores.get(p["agent_type"], 0),
            p.get("base_priority", 0),
        ),
        reverse=True,
    )

    # Bug-type tasks must never be routed to read-only agents.
    # Filter out read-only profiles when the task is a bug.
    if is_bug:
        passing = [p for p in passing if not p.get("read_only", False)]

    complexity = compute_complexity(len(passing), blocks_count, description)

    if passing:
        winner = passing[0]
        subagent = winner["agent_type"]
        category = winner.get("category")
        if complexity == "high":
            model = winner["model"]["complex"]
        else:
            model = winner["model"]["default"]
        reason = (
            f"Matched profile {winner['_file']} with score "
            f"{scores.get(subagent, 0)}"
        )
    else:
        subagent = "general-purpose"
        category = None
        model = "sonnet"
        reason = "No profiles passed min_score threshold"

    # Detect interface-contract tasks from text keywords (priority override)
    interface_keywords = ["interface", "contract", "abstract", "protocol", "base class"]
    is_interface = any(kw in text for kw in interface_keywords) or bool(
        re.search(r"\babc\b", text)
    )

    # Assign priority (integer 1-4 for backward compat with sprint consumer)
    if is_interface or category == "interface-contract":
        priority = 1
    elif blocks_count >= 2:
        priority = 2
    elif category == "db-dependent":
        priority = 4
    else:
        priority = 3

    # Assign class
    if is_interface or category == "interface-contract":
        task_class = "interface-contract"
    elif blocks_count >= 2:
        task_class = "fan-out-blocker"
    elif category == "db-dependent":
        task_class = "db-dependent"
    elif category == "skill-guided":
        task_class = "skill-guided"
    else:
        task_class = "independent"

    return {
        "id": task.get("id", ""),
        "priority": priority,
        "class": task_class,
        "subagent": subagent,
        "model": model,
        "complexity": complexity,
        "reason": reason,
        "scores": scores,
    }


def run_test(profiles_dir: Path) -> int:
    """Run test cases from test-cases.yaml. Return 0 if all pass, 1 otherwise."""
    test_cases_path = profiles_dir / "test-cases.yaml"
    with open(test_cases_path) as f:
        cases = yaml.safe_load(f)

    profiles = load_profiles(profiles_dir)

    all_passed = True
    for i, case in enumerate(cases, 1):
        task = {
            "id": f"test-{i}",
            "title": case.get("title", ""),
            "description": case.get("description", ""),
            "acceptance_criteria": case.get("acceptance_criteria", ""),
            "blocks": case.get("blocks", 0),
            "task_type": case.get("task_type", ""),
        }

        result = classify_task(task, profiles)

        expected_agent = case["expected_agent"]
        expected_complexity = case.get("expected_complexity")

        agent_ok = result["subagent"] == expected_agent
        complexity_ok = (
            expected_complexity is None or result["complexity"] == expected_complexity
        )

        if agent_ok and complexity_ok:
            print(f"PASS [{i}] {case['title'][:60]}")
        else:
            all_passed = False
            print(f"FAIL [{i}] {case['title'][:60]}")
            if not agent_ok:
                print(
                    f"     agent:      got={result['subagent']!r}  "
                    f"expected={expected_agent!r}"
                )
            if not complexity_ok:
                print(
                    f"     complexity: got={result['complexity']!r}  "
                    f"expected={expected_complexity!r}"
                )
            print(f"     scores: {result['scores']}")

    return 0 if all_passed else 1


def main() -> None:
    """Entry point."""
    profiles_dir = Path(__file__).parent / "agent-profiles"

    if "--test" in sys.argv:
        exit_code = run_test(profiles_dir)
        sys.exit(exit_code)

    # Read JSON from stdin
    raw = sys.stdin.read()
    try:
        tasks = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"JSON decode error: {exc}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(tasks, list):
        tasks = [tasks]

    profiles = load_profiles(profiles_dir)

    results = []
    for task in tasks:
        try:
            classified = classify_task(task, profiles)
        except Exception as exc:  # noqa: BLE001
            classified = {
                "id": task.get("id", ""),
                "priority": 3,
                "class": "independent",
                "subagent": "general-purpose",
                "model": "sonnet",
                "complexity": "low",
                "reason": f"Classification error: {exc}",
                "scores": {},
            }
        results.append(classified)

    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
