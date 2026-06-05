"""Bug 40cd-fefc-4576-488f regression tests.

When the Reviews API 422s in a cycle, findings/defenses fall back to the
issue-comment surface. The cycle>=2 defense lookup (`_fetch_pr_defenses`) must
be surface-agnostic — consuming DEFENSE_RECORD entries from BOTH the PR
review-thread surface (`/repos/<repo>/pulls/<n>/comments`) AND the
issue-conversation surface (`gh pr view --json comments`) — so a defense
recorded against a finding landed on either surface is associated in cycle 2.

Also covers the per-finding anchor WARNING emitted when the Reviews API 422s,
so fabricated-anchor findings (anchored to a line not in the diff) are visible
in the CI job log.

These tests were RED before the fix:
  (a) _fetch_pr_defenses only read `gh pr view --json comments` (issue surface);
      a defense that landed on the review-thread surface was missed.
  (b) the 422 fallback logged no per-finding anchor diagnostics.
"""

import subprocess
from unittest.mock import patch

import dso_ci_review.runner as runner_mod


def _completed(stdout="", returncode=0, stderr=""):
    return subprocess.CompletedProcess(
        args=["gh"], returncode=returncode, stdout=stdout, stderr=stderr
    )


# ---------------------------------------------------------------------------
# (a) Defense lookup consumes the review-thread (issue-fallback) surface.
# ---------------------------------------------------------------------------
def test_fetch_pr_defenses_reads_review_thread_surface(monkeypatch):
    """A DEFENSE_RECORD present ONLY on the review-thread surface must be found.

    RED before fix: _fetch_pr_defenses queried only `gh pr view --json comments`
    (issue surface), so this record was invisible and cycle 2 re-emitted the
    finding verbatim.
    """
    monkeypatch.setenv("GITHUB_TOKEN", "token-stub")
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")

    defense_body = (
        'DEFENSE_RECORD: {"finding_fingerprint": "F1", "ticket_id": "T-1", '
        '"defense_type": "resolved", "defense_text": "fixed in 5fd0dd10"}'
    )

    def _fake_run(cmd, *args, **kwargs):
        # Issue-conversation surface: empty (the finding landed elsewhere).
        if cmd[:3] == ["gh", "pr", "view"]:
            return _completed(stdout="")
        # Review-thread surface: carries the defense record.
        if cmd[:2] == ["gh", "api"] and any(
            "/pulls/" in str(c) and str(c).endswith("/comments") for c in cmd
        ):
            return _completed(stdout=defense_body + "\n")
        return _completed(stdout="")

    with patch.object(runner_mod.subprocess, "run", side_effect=_fake_run):
        defenses = runner_mod._fetch_pr_defenses(658)

    fingerprints = [d.get("finding_fingerprint") for d in defenses]
    assert "F1" in fingerprints, (
        "Defense recorded on the review-thread surface must be collected by "
        f"the surface-agnostic cycle-2 lookup; got: {defenses!r}"
    )


def test_fetch_pr_defenses_dedupes_across_surfaces(monkeypatch):
    """A defense mirrored to BOTH surfaces must be returned exactly once."""
    monkeypatch.setenv("GITHUB_TOKEN", "token-stub")
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")

    body = (
        'DEFENSE_RECORD: {"finding_fingerprint": "F2", "ticket_id": "T-2", '
        '"defense_type": "resolved", "defense_text": "same record"}'
    )

    def _fake_run(cmd, *args, **kwargs):
        if cmd[:3] == ["gh", "pr", "view"]:
            return _completed(stdout=body + "\n")
        if cmd[:2] == ["gh", "api"]:
            return _completed(stdout=body + "\n")
        return _completed(stdout="")

    with patch.object(runner_mod.subprocess, "run", side_effect=_fake_run):
        defenses = runner_mod._fetch_pr_defenses(658)

    f2 = [d for d in defenses if d.get("finding_fingerprint") == "F2"]
    assert len(f2) == 1, (
        f"Record present on both surfaces must dedupe to one; got: {defenses!r}"
    )


def test_fetch_pr_defenses_still_reads_issue_surface(monkeypatch):
    """Regression: defenses on the issue-conversation surface still work."""
    monkeypatch.setenv("GITHUB_TOKEN", "token-stub")
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")

    body = (
        'DEFENSE_RECORD: {"finding_fingerprint": "F3", "ticket_id": "T-3", '
        '"defense_type": "resolved", "defense_text": "issue-surface defense"}'
    )

    def _fake_run(cmd, *args, **kwargs):
        if cmd[:3] == ["gh", "pr", "view"]:
            return _completed(stdout=body + "\n")
        # Review-thread surface empty.
        if cmd[:2] == ["gh", "api"]:
            return _completed(stdout="")
        return _completed(stdout="")

    with patch.object(runner_mod.subprocess, "run", side_effect=_fake_run):
        defenses = runner_mod._fetch_pr_defenses(658)

    assert [d.get("finding_fingerprint") for d in defenses] == ["F3"], (
        f"Issue-surface defense must still be collected; got: {defenses!r}"
    )


def test_fetch_pr_defenses_derives_repo_when_env_unset(monkeypatch):
    """GITHUB_REPOSITORY unset (local run): Surface 2 must derive the repo via
    `gh repo view` rather than silently skip the review-thread surface.

    Guards the F1/F2 regression: a malformed/absent env var must NOT regress a
    run to a single surface when the slug is otherwise discoverable.
    """
    monkeypatch.setenv("GITHUB_TOKEN", "token-stub")
    monkeypatch.delenv("GITHUB_REPOSITORY", raising=False)

    defense_body = (
        'DEFENSE_RECORD: {"finding_fingerprint": "F4", "ticket_id": "T-4", '
        '"defense_type": "resolved", "defense_text": "review-thread defense"}'
    )

    def _fake_run(cmd, *args, **kwargs):
        # gh repo view derives the slug.
        if cmd[:3] == ["gh", "repo", "view"]:
            return _completed(stdout="owner/repo\n")
        # Issue surface: empty.
        if cmd[:3] == ["gh", "pr", "view"]:
            return _completed(stdout="")
        # Review-thread surface (now reachable via derived slug).
        if cmd[:2] == ["gh", "api"] and any(
            "/pulls/" in str(c) and str(c).endswith("/comments") for c in cmd
        ):
            return _completed(stdout=defense_body + "\n")
        return _completed(stdout="")

    with patch.object(runner_mod.subprocess, "run", side_effect=_fake_run):
        defenses = runner_mod._fetch_pr_defenses(658)

    assert [d.get("finding_fingerprint") for d in defenses] == ["F4"], (
        "With GITHUB_REPOSITORY unset, the review-thread surface must still be "
        f"queried via gh-derived slug; got: {defenses!r}"
    )


def test_fetch_pr_defenses_warns_when_repo_unresolvable(monkeypatch, capsys):
    """When the repo slug cannot be resolved (env unset AND gh derivation
    fails), Surface 2 is skipped with a visible WARNING — not silently."""
    monkeypatch.setenv("GITHUB_TOKEN", "token-stub")
    monkeypatch.delenv("GITHUB_REPOSITORY", raising=False)

    def _fake_run(cmd, *args, **kwargs):
        if cmd[:3] == ["gh", "repo", "view"]:
            return _completed(returncode=1, stderr="not a git repo")
        if cmd[:3] == ["gh", "pr", "view"]:
            return _completed(stdout="")
        return _completed(stdout="")

    with patch.object(runner_mod.subprocess, "run", side_effect=_fake_run):
        defenses = runner_mod._fetch_pr_defenses(658)

    stderr = capsys.readouterr().err
    assert "Surface 2" in stderr and "skipped" in stderr, (
        "An unresolvable repo slug must emit a visible WARNING that Surface 2 "
        f"was skipped; stderr was:\n{stderr}"
    )
    # Surface 1 succeeded (returncode 0, empty body) so the function does not
    # return [] — it returns the (empty) deduped parse of Surface 1.
    assert defenses == []


def test_fetch_pr_defenses_returns_empty_when_both_surfaces_fail(monkeypatch):
    """When neither surface fetch succeeds, return [] (best-effort, no raise)."""
    monkeypatch.setenv("GITHUB_TOKEN", "token-stub")
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")

    def _fake_run(cmd, *args, **kwargs):
        return _completed(returncode=1, stderr="boom")

    with patch.object(runner_mod.subprocess, "run", side_effect=_fake_run):
        defenses = runner_mod._fetch_pr_defenses(658)

    assert defenses == []


# ---------------------------------------------------------------------------
# (b) Reviews API 422 logs per-finding anchor warnings.
# ---------------------------------------------------------------------------
def test_reviews_api_422_logs_per_finding_anchor_warning(monkeypatch, capsys):
    """On a Reviews API failure, each anchored finding's path:line is logged.

    RED before fix: the fallback logged only a single generic warning, so a
    fabricated anchor (e.g. PR #658 finding 1 anchored to an unmodified line)
    left no path:line trace in the job log.
    """
    monkeypatch.setenv("GITHUB_TOKEN", "token-stub")
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
    monkeypatch.setenv("GITHUB_REF", "refs/pull/658/merge")
    monkeypatch.setenv("GITHUB_SHA", "deadbeefcafe")

    findings = [
        {
            "severity": "critical",
            "category": "correctness",
            "description": "fabricated anchor finding",
            "cited_lines": ["plugins/dso/scripts/dso_ci_review/runner.py:9999"],
        },
        {
            "severity": "important",
            "category": "correctness",
            "description": "second finding",
            "cited_lines": ["plugins/dso/scripts/dso_ci_review/runner.py:42"],
        },
    ]

    def _is_reviews_api_call(cmd) -> bool:
        # Dispatch on argv STRUCTURE, not substring sniffing: the Reviews API
        # POST is `gh api -X POST /repos/<repo>/pulls/<n>/reviews`.
        return (
            isinstance(cmd, list)
            and cmd[:2] == ["gh", "api"]
            and any(str(c).endswith("/reviews") for c in cmd)
        )

    def _is_pr_comment_call(cmd) -> bool:
        # The issue-comment fallback is `gh pr comment <n> --body <body>`.
        return isinstance(cmd, list) and cmd[:3] == ["gh", "pr", "comment"]

    def _fake_run(cmd, *args, **kwargs):
        # Reviews API call fails with a 422, forcing the issue-comment fallback.
        if _is_reviews_api_call(cmd):
            raise subprocess.CalledProcessError(
                returncode=1, cmd=cmd, output="", stderr="422 Unprocessable Entity"
            )
        # head SHA resolution + fallback issue comments succeed.
        return _completed(stdout="")

    # _resolve_pr_head_sha falls back to GITHUB_SHA env when gh calls return "".
    with patch.object(
        runner_mod.subprocess, "run", side_effect=_fake_run
    ) as mock_run:
        runner_mod._post_pr_review(findings)

    stderr = capsys.readouterr().err
    assert "runner.py:9999" in stderr, (
        "Per-finding anchor warning must surface the fabricated anchor path:line "
        f"so it is visible in the job log; stderr was:\n{stderr}"
    )
    assert "runner.py:42" in stderr, (
        f"All anchored findings' anchors must be logged; stderr was:\n{stderr}"
    )

    # The warnings are printed BEFORE the fallback runs, so asserting on stderr
    # alone passes vacuously if the fallback were ever skipped. Pin the contract:
    # the Reviews-API 422 MUST re-route anchored findings to the issue-comment
    # fallback (`gh pr comment`).
    calls = [c.args[0] for c in mock_run.call_args_list]
    assert any(_is_reviews_api_call(cmd) for cmd in calls), (
        "the Reviews API must have been attempted; calls were:\n"
        + "\n".join(str(c) for c in calls)
    )
    assert any(_is_pr_comment_call(cmd) for cmd in calls), (
        "after the Reviews API 422, anchored findings must be re-routed to the "
        "`gh pr comment` issue-comment fallback; calls were:\n"
        + "\n".join(str(c) for c in calls)
    )
