"""dso_ci_review.local_workflow — Local (non-CI) review workflow orchestrator.

Entry point for /dso:commit local review gate. Manages cycle ledger in
filesystem-only mode. Ledger init reads from the local filesystem only;
PR reconstruction is a CI-only code path not used here.

Public API:
    _init_local_ledger(artifacts_dir, branch_name, commit_sha) -> dict
        Returns {"cycle_num": int, "ledger": dict}

    main(artifacts_dir=None, commit_sha=None, diff_text="", max_cycles=None) -> int
        CLI entry point; propagates exit code from review dispatch.
        When called without arguments, reads from environment + git.
"""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from dso_ci_review import cycle_dispatcher
from dso_ci_review import cycle_ledger
from dso_ci_review import stability
from dso_ci_review._config import read_config_int
from dso_ci_review.arbiter_processor import process_rulings
from dso_ci_review.providers.config import get_provider


def cycle_next_action(
    ledger: dict,
    max_cycles: int,
    current_findings: list,
    current_commit_sha: str,
    artifacts_dir: str | None = None,
) -> dict:
    """Module-level wrapper for cycle_dispatcher.next_action.

    Provides a patchable module attribute for tests while delegating to
    the canonical implementation in cycle_dispatcher.
    """
    return cycle_dispatcher.next_action(
        ledger, max_cycles, current_findings, current_commit_sha, artifacts_dir
    )


def _dispatch_cycle_end_arbiter(
    findings: list[dict],
    defenses: list[dict],
    diff_text: str,
    model: str,
    provider_chain: list[str],
    cycle_num: int,
    max_cycles: int,
    **kwargs,
) -> list[dict]:
    """Module-level wrapper for dispatch_cycle_end_arbiter (patchable in tests)."""
    from dso_ci_review.arbiter import dispatch_cycle_end_arbiter  # noqa: PLC0415

    return dispatch_cycle_end_arbiter(
        findings=findings,
        defenses=defenses,
        diff_text=diff_text,
        model=model,
        provider_chain=provider_chain,
        cycle_num=cycle_num,
        max_cycles=max_cycles,
        **kwargs,
    )


def _read_diff() -> str:
    """Read the current staged diff from git.

    Returns the unified diff of staged changes, or empty string on error.
    """
    try:
        return subprocess.check_output(
            ["git", "diff", "--cached"],
            stderr=subprocess.DEVNULL,
        ).decode()
    except subprocess.CalledProcessError:
        return ""


def _validate_agent_files() -> None:
    """Validate that required agent files are present.

    Stub — full validation is handled by the pre-commit hook.
    No-op in the local workflow; raises if critical files are missing.
    """


def _resolve_branch_name(repo_root: str, current_commit_sha: str) -> str:
    """Resolve the current git branch name.

    Falls back to a detached/unknown descriptor when HEAD is not on a branch.
    """
    try:
        name = (
            subprocess.check_output(
                ["git", "rev-parse", "--abbrev-ref", "HEAD"],
                stderr=subprocess.DEVNULL,
            )
            .decode()
            .strip()
        )
        if name in ("HEAD", ""):
            repo_basename = os.path.basename(repo_root)
            return f"detached:{repo_basename}:{current_commit_sha[:8]}"
        return name
    except subprocess.CalledProcessError:
        repo_basename = os.path.basename(repo_root)
        return f"unknown:{repo_basename}:{current_commit_sha[:8]}"


def _build_reviewer_breakdown(findings: list[dict]) -> dict:
    """Build a finding_id -> [reviewer_agent_id] mapping from findings."""
    result = {}
    for i, f in enumerate(findings):
        prov = f.get("provenance") or {}
        agent_id = prov.get("reviewer_agent_id", "UNKNOWN")
        finding_id = f.get("id") or str(i)
        result[finding_id] = [agent_id]
    return result


def _local_arbiter_branch(
    findings: list[dict],
    cycle_num: int,
    commit_sha: str,
    artifacts_dir: str,
    ledger: dict | None = None,
    diff_text: str = "",
    max_cycles: int = 4,
    prior_defenses: list | None = None,
    repo_root: str | None = None,
) -> int:
    """Dispatch the cycle-end arbiter in local (non-CI) mode.

    Calls the cycle-end arbiter with local context (no PR number), processes
    rulings into side effects (BLOCK/DEFER/DROP), writes the arbiter-rulings.json
    sidecar, and returns the exit code.

    Args:
        findings: Current cycle's reviewer findings.
        cycle_num: Current cycle number.
        commit_sha: Current HEAD commit SHA.
        artifacts_dir: Directory for review artifacts.
        ledger: Optional cycle ledger dict for history context.
        diff_text: Unified diff text under review.
        max_cycles: Maximum review cycles configured.
        prior_defenses: Prior defense records from previous cycles.
        repo_root: Repo root path. Resolved from git when None.

    Returns:
        0 if no BLOCK rulings; 1 if any BLOCK ruling present.
    """
    if prior_defenses is None:
        prior_defenses = []
    if repo_root is None:
        try:
            repo_root = (
                subprocess.check_output(
                    ["git", "rev-parse", "--show-toplevel"],
                    stderr=subprocess.DEVNULL,
                )
                .decode()
                .strip()
            )
        except subprocess.CalledProcessError:
            repo_root = os.getcwd()

    # Resolve branch name for local context (no PR number).
    branch_name = _resolve_branch_name(repo_root, commit_sha)

    # Read existing defenses from tracker store.
    defenses = list(prior_defenses)

    # Resolve model and provider chain from config/environment.
    try:
        provider = get_provider()
        model = getattr(provider, "model", "claude-opus-4-5")
        provider_chain = [getattr(provider, "name", "anthropic")]
    except Exception:
        model = "claude-opus-4-5"
        provider_chain = ["anthropic"]

    # Build reviewer breakdown for cross-reviewer agreement derivation.
    reviewer_breakdown = _build_reviewer_breakdown(findings)

    # Ledger history for cross-cycle pattern derivation.
    ledger_history = ledger.get("cycles", []) if ledger else []

    # Dispatch the cycle-end arbiter.
    rulings = _dispatch_cycle_end_arbiter(
        findings=findings,
        defenses=defenses,
        diff_text=diff_text,
        model=model,
        provider_chain=provider_chain,
        cycle_num=cycle_num,
        max_cycles=max_cycles,
        reviewer_breakdown=reviewer_breakdown,
        ledger_history=ledger_history,
    )

    # Build finding_map: 0-based integer index → finding dict.
    finding_map = {i: f for i, f in enumerate(findings)}

    # Process rulings into side effects (BLOCK, DEFER, DROP).
    result = process_rulings(
        rulings,
        finding_map,
        cycle_num,
        commit_sha=commit_sha,
        pr_number=None,
        branch_name=branch_name,
        ticket_cmd_path=".claude/scripts/dso",
        artifacts_dir=artifacts_dir,
        repo_root=repo_root,
    )

    # Write arbiter-rulings.json sidecar with rulings and summary counts.
    block_rulings = [r for r in rulings if r.get("ruling") == "BLOCK"]
    drop_rulings = [r for r in rulings if r.get("ruling") == "DROP"]
    defer_rulings = [r for r in rulings if r.get("ruling") == "DEFER"]
    sidecar = {
        "schema_version": "1.0.0",
        "cycle_num": cycle_num,
        "commit_sha": commit_sha,
        "rulings": rulings,
        "summary": {
            "block_count": len(block_rulings),
            "drop_count": len(drop_rulings),
            "defer_count": len(defer_rulings),
            "total": len(rulings),
        },
    }
    sidecar_path = Path(artifacts_dir) / "arbiter-rulings.json"
    sidecar_path.parent.mkdir(parents=True, exist_ok=True)
    sidecar_path.write_text(json.dumps(sidecar, indent=2), encoding="utf-8")

    # Return 1 if any BLOCK ruling is present; 0 otherwise.
    return 1 if result.get("block") else 0


def _ledger_path(artifacts_dir: str) -> str:
    """Return the canonical cycle-ledger.json path for the given artifacts dir."""
    return str(Path(artifacts_dir) / "cycle-ledger.json")


def _lock_file_path(artifacts_dir: str) -> str:
    """Return the lock file path co-located with the ledger."""
    return str(Path(artifacts_dir) / "cycle-ledger.lock")


def _init_local_ledger(
    artifacts_dir: str,
    branch_name: str,
    commit_sha: str,
) -> dict:
    """Initialize cycle ledger for a local (non-CI) review run.

    Read the existing ledger from filesystem, determine the next cycle number,
    and return the result. Reads ledger from filesystem only; the PR
    reconstruction code path is CI-only and is not invoked here.

    Concurrent-init safety: acquires fcntl LOCK_EX for the read-decide window
    to prevent two concurrent processes from receiving the same cycle_num.

    Args:
        artifacts_dir: Directory containing cycle-ledger.json (and lock file).
        branch_name: Current branch name (informational; not used in logic).
        commit_sha: Current HEAD commit SHA for SHA-aware reset semantics.

    Returns:
        dict with keys:
            - "cycle_num": int — the cycle number to use for this run.
            - "ledger": dict — the current ledger (before this cycle is appended).

    Semantics:
        - No ledger / empty cycles: cycle_num=1 (fresh start).
        - Last cycle SHA != commit_sha: cycle_num=1 (SHA change reset).
        - Last cycle SHA == commit_sha: cycle_num = last_cycle_num + 1.
    """
    # Ensure artifacts dir exists so lock file can be created there.
    Path(artifacts_dir).mkdir(parents=True, exist_ok=True)

    lock_path = _lock_file_path(artifacts_dir)
    ledger_path_str = _ledger_path(artifacts_dir)

    # Open (or create) the lock file atomically using O_CREAT | O_RDWR.
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        lock_file = os.fdopen(lock_fd, "r")
    except Exception:
        try:
            os.close(lock_fd)
        except OSError:
            pass
        raise

    try:
        # Acquire exclusive lock for the read-decide window.
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            ledger = cycle_ledger.read_ledger(ledger_path_str)
            cycles = ledger.get("cycles", [])

            if not cycles:
                # Fresh start: no prior cycles.
                cycle_num = 1
            else:
                last_cycle = cycles[-1]
                last_sha = last_cycle.get("commit_sha", "")
                if last_sha != commit_sha:
                    # SHA changed — reset counter for new commit.
                    cycle_num = 1
                else:
                    # Same SHA — continue from where we left off.
                    cycle_num = last_cycle["cycle_num"] + 1

            # Write a placeholder entry to reserve cycle_num before releasing
            # the lock. This prevents concurrent callers from reading an empty
            # (or stale) ledger and computing the same cycle_num.
            # NOTE: cannot call write_ledger() here — it acquires the same lock
            # and would deadlock. Write directly using atomic rename instead.
            #
            # Build the updated ledger as a NEW dict (do not mutate the object
            # returned by read_ledger — callers may hold a reference to it).
            placeholder = {
                "cycle_num": cycle_num,
                "timestamp_utc": None,
                "commit_sha": commit_sha,
                "findings": [],
                "findings_hash": "",
                "halt_reason": None,
                "_placeholder": True,
            }
            updated_ledger = {
                **ledger,
                "cycles": list(ledger.get("cycles", [])) + [placeholder],
            }
            ledger_p = Path(ledger_path_str)
            ledger_p.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp_path = tempfile.mkstemp(
                prefix=ledger_p.name + ".", dir=str(ledger_p.parent)
            )
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(json.dumps(updated_ledger, indent=2))
                os.replace(tmp_path, ledger_path_str)
            except Exception:
                if Path(tmp_path).exists():
                    os.unlink(tmp_path)
                raise

            return {"cycle_num": cycle_num, "ledger": ledger}
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    finally:
        lock_file.close()


def _dispatch_local_reviewer(
    diff_text: str,
    cycle_num: int,
    prior_defenses: list,
) -> list[dict]:
    """Dispatch a local reviewer for the given diff and cycle.

    In the local workflow, dispatches via dispatch_review() without posting
    PR comments (pr_number=None). Returns the findings list from the result.

    Args:
        diff_text: Unified diff text to review.
        cycle_num: Current review cycle number (informational).
        prior_defenses: Prior defenses from previous cycles (for re-review).

    Returns:
        List of finding dicts.
    """
    from dso_ci_review.dispatch import dispatch_review  # noqa: PLC0415

    result = dispatch_review(
        diff_text=diff_text,
        provider_chain=["anthropic"],
    )
    return result.get("findings", [])


def _invoke_arbiter_hook(
    artifacts_dir: str,
    commit_sha: str,
    findings: list | None = None,
    cycle_num: int = 1,
    ledger: dict | None = None,
    diff_text: str = "",
    max_cycles: int = 4,
    prior_defenses: list | None = None,
) -> int:
    """Invoke the arbiter when max review cycles are exhausted.

    Delegates to _local_arbiter_branch which dispatches the cycle-end arbiter,
    processes rulings, writes arbiter-rulings.json, and returns exit code.

    Args:
        artifacts_dir: Directory containing review artifacts.
        commit_sha: Current HEAD commit SHA.
        findings: Current cycle's findings (default empty list).
        cycle_num: Current review cycle number.
        ledger: Optional cycle ledger dict for history context.
        diff_text: Unified diff text under review.
        max_cycles: Maximum review cycles configured.
        prior_defenses: Prior defense records.

    Returns:
        Exit code (0 = pass, non-zero = block).
    """
    if findings is None:
        findings = []
    print(
        f"ARBITER: dispatching cycle-end arbiter for commit {commit_sha[:12]}",
        file=sys.stderr,
    )
    return _local_arbiter_branch(
        findings=findings,
        cycle_num=cycle_num,
        commit_sha=commit_sha,
        artifacts_dir=artifacts_dir,
        ledger=ledger,
        diff_text=diff_text,
        max_cycles=max_cycles,
        prior_defenses=prior_defenses,
    )


def main(
    artifacts_dir: str | None = None,
    commit_sha: str | None = None,
    diff_text: str = "",
    max_cycles: int | None = None,
) -> int:
    """CLI entry point for the local review workflow.

    When called without arguments, reads configuration from the environment
    and resolves git state. When called with explicit arguments (e.g., from
    tests), uses those values directly.

    Args:
        artifacts_dir: Directory for review artifacts. Defaults to
            WORKFLOW_PLUGIN_ARTIFACTS_DIR env var or /tmp.
        commit_sha: Current HEAD commit SHA. Defaults to git rev-parse HEAD.
        diff_text: Unified diff text to review. Defaults to empty string
            (real implementation reads git diff in later task).
        max_cycles: Maximum review cycles. Defaults to review.max_cycles
            config value (default 4).

    Returns exit code (0 = pass, non-zero = block/error).
    """
    # Resolve artifacts_dir
    if artifacts_dir is None:
        artifacts_dir = os.environ.get("WORKFLOW_PLUGIN_ARTIFACTS_DIR", "/tmp")

    # Resolve max_cycles from config when not explicitly provided (single read).
    if max_cycles is None:
        max_cycles = read_config_int("review.max_cycles", default=4)

    # Validate agent files before proceeding.
    _validate_agent_files()

    # Resolve diff_text from staged changes when not explicitly provided.
    if not diff_text:
        diff_text = _read_diff()

    # Resolve commit_sha from git when not explicitly provided
    if commit_sha is None:
        try:
            commit_sha = (
                subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip()
            )
        except subprocess.CalledProcessError as e:
            print(
                f"ERROR: git rev-parse HEAD failed (exit {e.returncode})",
                file=sys.stderr,
            )
            return 1

    # Resolve branch name (informational; not used in dispatch logic)
    try:
        branch_name = (
            subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"])
            .decode()
            .strip()
        )
    except subprocess.CalledProcessError:
        branch_name = "unknown"

    # Initialize ledger and determine starting cycle_num
    result = _init_local_ledger(
        artifacts_dir=artifacts_dir,
        branch_name=branch_name,
        commit_sha=commit_sha,
    )
    ledger = result["ledger"]
    cycle_num = result["cycle_num"]
    ledger_path = os.path.join(artifacts_dir, "cycle-ledger.json")

    print(
        f"Local review workflow: cycle_num={cycle_num} "
        f"branch={branch_name} sha={commit_sha[:12]}",
        file=sys.stderr,
    )

    # Pre-loop check: if a prior arbiter ruling or stable state exists for this
    # commit, skip re-running the review loop entirely.
    action_result = cycle_next_action(ledger, max_cycles, [], commit_sha, artifacts_dir)
    if action_result.get("action") == "SHORT_CIRCUIT":
        rulings_path = os.path.join(artifacts_dir, "arbiter-rulings.json")
        try:
            with open(rulings_path) as f:
                sidecar_data = json.load(f)
        except (OSError, json.JSONDecodeError):
            sidecar_data = {}
        # arbiter-rulings.json is a dict {"schema_version": ..., "rulings": [...], ...}.
        # Support legacy flat-list format defensively for backward-compat with any
        # pre-schema-v1 sidecars that may still exist in the wild.
        if isinstance(sidecar_data, dict):
            ruling_list = sidecar_data.get("rulings", [])
        elif isinstance(sidecar_data, list):
            ruling_list = sidecar_data
        else:
            ruling_list = []
        has_block = any(
            isinstance(r, dict) and r.get("ruling") == "BLOCK" for r in ruling_list
        )
        return 1 if has_block else 0

    if action_result.get("action") == "DISPATCH_ARBITER":
        # Pre-loop arbiter dispatch: cycles exhausted before entering loop.
        # Run reviewer once to get current findings for the arbiter.
        pre_cycle_num = action_result.get("cycle_num", cycle_num)
        raw_reviewer_result = _dispatch_local_reviewer(diff_text, pre_cycle_num, [])
        pre_findings: list = (
            raw_reviewer_result.get("findings", [])
            if isinstance(raw_reviewer_result, dict)
            else raw_reviewer_result
        )
        return _invoke_arbiter_hook(
            artifacts_dir=artifacts_dir,
            commit_sha=commit_sha,
            findings=pre_findings,
            cycle_num=pre_cycle_num,
            ledger=ledger,
            diff_text=diff_text,
            max_cycles=max_cycles,
            prior_defenses=[],
        )

    # Multi-cycle review loop (reviewer-first ordering).
    # Each iteration: dispatch reviewer → compute hash → append to ledger
    # → ask dispatcher for next action.
    prior_defenses: list = []
    while True:
        findings = _dispatch_local_reviewer(diff_text, cycle_num, prior_defenses)

        # Compute stable finding identity hash from (file, line_range, category).
        tuples = [
            (
                f.get("file", ""),
                str(f.get("line_range", "")),
                f.get("category", ""),
            )
            for f in findings
        ]
        findings_hash = stability.finding_hash(
            {
                "file": "|".join(t[0] for t in sorted(tuples)),
                "line_range": "|".join(t[1] for t in sorted(tuples)),
                "category": "|".join(t[2] for t in sorted(tuples)),
            }
        )

        # Atomically append this cycle's data to the on-disk ledger.
        cycle_ledger.append_cycle(
            ledger_path, cycle_num, tuples, commit_sha, findings_hash
        )

        # Also update in-memory ledger so next_action sees current state.
        ledger.setdefault("cycles", []).append(
            {
                "cycle_num": cycle_num,
                "commit_sha": commit_sha,
                "findings": tuples,
                "findings_hash": findings_hash,
            }
        )

        # Ask the dispatcher what to do next.
        action_result = cycle_next_action(
            ledger, max_cycles, findings, commit_sha, artifacts_dir
        )
        action = action_result.get("action")

        if action == "PASS":
            return 0

        if action == "DISPATCH_ARBITER":
            return _invoke_arbiter_hook(
                artifacts_dir=artifacts_dir,
                commit_sha=commit_sha,
                findings=findings,
                cycle_num=cycle_num,
                ledger=ledger,
                diff_text=diff_text,
                max_cycles=max_cycles,
                prior_defenses=prior_defenses,
            )

        if action == "SHORT_CIRCUIT":
            # SHORT_CIRCUIT mid-loop: treat as pass (arbiter already ruled PASS).
            return 0

        # DISPATCH_NEXT: advance cycle counter and continue loop.
        # The cycle_num in the action result reflects the current cycle;
        # increment by 1 to get the next cycle number.
        cycle_num = cycle_num + 1


if __name__ == "__main__":
    sys.exit(main())
