"""
Dogfood replay harness for visual-evaluator.

Discovers recent PRs (last 90 days) with UI file changes, replays the
visual-evaluator skill against them (stub mode for tests), and compares
findings against the prior reviewer-findings.json.

Reports: per-PR findings_new_to_visual_evaluator count.
Gate: >= 3 PRs with >= 1 missed finding each, OR insufficient-sample report.
"""

from __future__ import annotations

import json
import subprocess
from typing import NamedTuple


class SeedPR(NamedTuple):
    number: int
    title: str
    merged_at: str
    ui_files_changed: int


def discover_seed_prs(
    merged_since_days: int = 90,
    min_ui_files: int = 1,
    repo: str | None = None,
) -> list[SeedPR]:
    """Discover seed PRs that meet the dogfood criteria.

    Uses gh CLI when available; returns empty list when gh is unavailable
    (graceful degradation for environments without gh auth).
    """
    if not _command_available("gh"):
        return []
    repo_arg = ["--repo", repo] if repo else []
    try:
        result = subprocess.run(
            [
                "gh",
                "pr",
                "list",
                "--state",
                "merged",
                "--limit",
                "100",
                "--json",
                "number,title,mergedAt,files",
                *repo_arg,
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            return []
        prs = json.loads(result.stdout)
    except (subprocess.SubprocessError, json.JSONDecodeError):
        return []

    import datetime

    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(
        days=merged_since_days
    )

    seeds: list[SeedPR] = []
    for pr in prs:
        merged_at_str = pr.get("mergedAt", "")
        if not merged_at_str:
            continue
        try:
            merged_at = datetime.datetime.fromisoformat(
                merged_at_str.replace("Z", "+00:00")
            )
        except ValueError:
            continue
        if merged_at < cutoff:
            continue
        # Check UI file count
        files = pr.get("files", [])
        ui_count = sum(1 for f in files if _is_ui_file(f.get("path", "")))
        if ui_count < min_ui_files:
            continue
        seeds.append(
            SeedPR(
                number=pr["number"],
                title=pr.get("title", ""),
                merged_at=merged_at_str,
                ui_files_changed=ui_count,
            )
        )
    return seeds


def _is_ui_file(path: str) -> bool:
    """Heuristic: does this path look like a UI file?"""
    ui_extensions = (
        ".css",
        ".js",
        ".ts",
        ".tsx",
        ".html",
        ".jinja2",
        ".jinja",
        ".scss",
    )
    return any(path.endswith(ext) for ext in ui_extensions)


def _command_available(cmd: str) -> bool:
    """Check whether a command is on PATH."""
    return subprocess.run(["which", cmd], capture_output=True).returncode == 0


def replay_pr(pr_number: int, stub_visual_findings: dict | None = None) -> dict:
    """Replay the visual-evaluator skill against a PR.

    In stub_visual_findings mode (passed from tests), returns the stub directly
    as the simulated visual-evaluator output. In production, would invoke the
    skill against the PR's changed files.

    Returns:
        {"pr_number": int, "visual_findings": list, "prior_findings": list,
         "missed_findings": list (in visual but not prior at severity >= medium)}
    """
    visual_findings = (
        stub_visual_findings.get("findings", []) if stub_visual_findings else []
    )
    prior_findings: list = []  # Production: load from gh pr view or reviewer-findings.json
    missed = _compute_missed(visual_findings, prior_findings)
    return {
        "pr_number": pr_number,
        "visual_findings": visual_findings,
        "prior_findings": prior_findings,
        "missed_findings": missed,
    }


def _compute_missed(visual_findings: list, prior_findings: list) -> list:
    """Findings in visual_findings (severity>=medium) not present in prior_findings."""
    severity_order = {"critical": 4, "major": 3, "medium": 2, "minor": 1, "low": 0}
    missed = []
    prior_signatures = {
        (f.get("dimension"), f.get("dom_xpath")) for f in prior_findings
    }
    for f in visual_findings:
        if severity_order.get(f.get("severity", "low"), 0) < 2:
            continue
        sig = (f.get("dimension"), f.get("dom_xpath"))
        if sig not in prior_signatures:
            missed.append(f)
    return missed


def report_dogfood(
    seed_prs: list[SeedPR],
    replay_results: list[dict],
    min_qualifying_prs: int = 3,
) -> dict:
    """Generate the dogfood comparison report.

    Returns:
        {"status": "ok" | "insufficient_sample",
         "seed_pr_count": int, "qualifying_prs": list (PRs with >= 1 missed finding),
         "details": list}
    """
    if len(seed_prs) < min_qualifying_prs:
        return {
            "status": "insufficient_sample",
            "seed_pr_count": len(seed_prs),
            "qualifying_prs": [],
            "details": [],
            "message": f"Only {len(seed_prs)} qualifying PRs in window; need at least {min_qualifying_prs}",
        }
    qualifying = [r for r in replay_results if len(r["missed_findings"]) >= 1]
    return {
        "status": "ok",
        "seed_pr_count": len(seed_prs),
        "qualifying_prs": [r["pr_number"] for r in qualifying],
        "details": replay_results,
    }


def main() -> int:
    seeds = discover_seed_prs()
    print(f"Discovered {len(seeds)} seed PRs in 90-day window")
    if len(seeds) < 3:
        print("INSUFFICIENT_SAMPLE: cannot run dogfood — need >=3 PRs")
        return 1
    results = [replay_pr(s.number) for s in seeds]
    report = report_dogfood(seeds, results)
    print(json.dumps(report, indent=2, default=str))
    return 0 if report["status"] == "ok" and len(report["qualifying_prs"]) >= 3 else 1


if __name__ == "__main__":
    import sys

    sys.exit(main())
