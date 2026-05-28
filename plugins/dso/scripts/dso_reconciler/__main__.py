#!/usr/bin/env python3
"""dso_reconciler.__main__ — steady-state pass orchestrator.

Invoked as ``python -m dso_reconciler`` by the GHA reconcile-bridge workflow.
Orchestrates one steady-state pass calling the pipeline modules in sequence:
  fetcher → differ → applier → mapping → manifest → health

Pipeline modules are loaded on demand via ``_try_load_step``; modules that
are not present in this deployment are skipped (graceful no-op), allowing
the orchestrator to be deployed alongside partial module rollouts.

Exit codes:
  0 — all present modules converged successfully
  1 — an unrecoverable error occurred in a pipeline step
"""

from __future__ import annotations

import argparse
import datetime
import importlib
import importlib.util
import sys
from pathlib import Path

# Dotted-name keys used for sys.modules seeding so that both production code
# and unit tests (which pre-seed sys.modules with these exact keys) share the
# same module objects and patch() targets resolve correctly.
_ADVISORY_LOCK_KEY = "plugins.dso.scripts.dso_reconciler._advisory_lock"
_MODE_KEY = "plugins.dso.scripts.dso_reconciler.mode"


def _load_sibling_keyed(dotted_key: str, filename: str):
    """Load a sibling .py file under *dotted_key* in sys.modules.

    If *dotted_key* is already present in sys.modules, returns the cached
    module — this allows tests to pre-seed the module and have production code
    reuse it, making patch() targets on *dotted_key* work correctly.

    Unlike ``_try_load_step``, this helper raises ``ImportError`` when the
    file is absent rather than returning None, since callers depend on it.
    """
    if dotted_key in sys.modules:
        return sys.modules[dotted_key]
    here = Path(__file__).parent
    path = here / filename
    if not path.exists():
        raise ImportError(f"Required sibling module not found: {path}")
    spec = importlib.util.spec_from_file_location(dotted_key, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot create spec for {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[dotted_key] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _try_load_step(name: str):
    """Attempt to import a sibling module by name; return None if absent.

    Registers the loaded module in ``sys.modules`` under its dotted spec name
    (``dso_reconciler.<name>``) BEFORE exec_module runs. This is load-bearing
    on Python 3.14 because the new dataclass type-resolution helper
    (``dataclasses._is_type`` -> ``sys.modules.get(cls.__module__).__dict__``)
    requires that any module containing a ``@dataclass`` be discoverable via
    the same key the class's ``__module__`` attribute points at. If
    ``sys.modules.get(cls.__module__)`` returns None (because we loaded the
    module via importlib.util but never put it in sys.modules), dataclass
    instantiation fails with ``AttributeError: 'NoneType' object has no
    attribute '__dict__'`` (bug 5be7 chain — defect #4 / chain item 4).

    Registration must happen BEFORE ``exec_module`` so that any decorator
    that runs during module body execution (e.g. ``@dataclass``) sees the
    module already in sys.modules.
    """
    here = Path(__file__).parent
    module_path = here / f"{name}.py"
    if not module_path.exists():
        return None
    dotted_name = f"dso_reconciler.{name}"
    spec = importlib.util.spec_from_file_location(dotted_name, module_path)
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[dotted_name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _run_reconcile_check(repo_root: Path) -> int:
    """Execute a read-only reconciliation check and report discrepancies.

    Returns 0 on success, 1 on error.
    """
    rc_mod = _try_load_step("reconcile_check")
    if rc_mod is None:
        print("ERROR: reconcile_check.py not found", file=sys.stderr)
        return 1

    fetcher = _try_load_step("fetcher")
    if fetcher is None:
        print(
            "ERROR: fetcher.py not found — cannot load Jira snapshot", file=sys.stderr
        )
        return 1

    try:
        # Fetch current Jira snapshot
        pass_id = datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H-%M-%S"
        )
        curr_path = fetcher.fetch_snapshot(pass_id, repo_root)
        import json as _json

        jira_snapshot = _json.loads(curr_path.read_text())

        # Load local tickets from .tickets-tracker
        tracker_dir = repo_root / ".tickets-tracker"  # tickets-boundary-ok
        local_tickets: list[dict] = []
        if tracker_dir.is_dir():
            for entry in sorted(tracker_dir.iterdir()):
                if not entry.is_dir() or ".scratch" in entry.parts:
                    continue
                meta_path = entry / "ticket.json"
                if meta_path.exists():
                    ticket = _json.loads(meta_path.read_text())
                    if "id" not in ticket:
                        ticket["id"] = entry.name
                    local_tickets.append(ticket)

        # Load binding store. The applier module exposes BindingStore.
        applier = _try_load_step("applier")
        if applier is None or not hasattr(applier, "BindingStore"):
            # Minimal stub: no bindings
            class _EmptyBindings:
                def all_bindings(self) -> list:
                    return []

            binding_store = _EmptyBindings()
        else:
            binding_store = applier.BindingStore(repo_root)

        report = rc_mod.reconcile_check(local_tickets, jira_snapshot, binding_store)
        print(rc_mod.format_report(report))

        # Write JSON report
        output_path = repo_root / "bridge_state" / "reconcile-check.json"
        rc_mod.write_report_json(report, output_path)
        print(f"\nFull report written to {output_path}")
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: reconcile-check failed: {exc}", file=sys.stderr)
        return 1


def run_pass(
    repo_root: Path | None = None,
    pass_id: str | None = None,
    target_mode=None,
    filter_local_ids: set[str] | None = None,
) -> int:
    """Execute one steady-state reconciliation pass via reconcile.reconcile_once().

    Returns 0 on converged state, EXIT_RESCHEDULE (75) when applier signals a
    reschedule (rebase_retry exhausted), 1 on any other unrecoverable error.

    When *pass_id* is None (legacy entry-point), one is generated here so the
    helper remains usable in isolation. Production callers should pass the
    pass_id from main() so the lock-holder and the recorded reconcile pass
    share the same identifier — previously two distinct timestamps were
    generated and a sub-second race could record mismatched pass_ids.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    reconcile = _try_load_step("reconcile")
    if reconcile is None:
        # Graceful no-op when reconcile.py is absent in the current deployment
        # (e.g., orchestrator deployed ahead of the reconcile module).
        print("OK: no-op (reconcile.py not present in this deployment)")
        return 0

    # F6: load the applier module so RescheduleError + EXIT_RESCHEDULE are
    # available for explicit handling. Without this, the broad `except
    # Exception` below would mask RescheduleError under exit 1, hiding the
    # reschedule signal from any scheduler that distinguishes 75 from 1.
    applier = _try_load_step("applier")

    if pass_id is None:
        pass_id = datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H-%M-%S"
        )
    reschedule_error_cls = (
        getattr(applier, "RescheduleError", None) if applier else None
    )
    exit_reschedule = getattr(applier, "EXIT_RESCHEDULE", 75) if applier else 75

    try:
        result = reconcile.reconcile_once(
            pass_id,
            repo_root=repo_root,
            target_mode=target_mode,
            filter_local_ids=filter_local_ids,
        )
    except Exception as exc:  # noqa: BLE001
        if reschedule_error_cls is not None and isinstance(exc, reschedule_error_cls):
            print(
                f"RESCHEDULE: reconcile_once signalled reschedule: {exc}",
                file=sys.stderr,
            )
            return exit_reschedule
        print(f"ERROR: reconcile_once raised: {exc}", file=sys.stderr)
        return 1

    print(f"OK: steady-state pass converged — {result['mutation_count']} mutations")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point for ``python -m dso_reconciler``.

    Guard sequence (execution order required — reordering breaks dd-2/dd-3/dd-4):
      1. argparse           — parse --mode (default: live) and --repo-root
      2. Mode.from_str      — validate mode string BEFORE any fetcher reference (dd-2)
      3. check_pass_lock    — exit non-zero if another pass is in flight (dd-3)
      4. check_phase_gate   — exit non-zero if gate file blocks this mode (dd-4)
      5. acquire_pass_lock  — claim the lock for this pass
      6. try/finally        — run_pass() with guaranteed release_pass_lock (dd-3)
    """
    parser = argparse.ArgumentParser(prog="dso_reconciler")
    parser.add_argument(
        "--repo-root",
        default=None,
        help="Repository root (default: auto-detect from script location)",
    )
    # --mode is NOT required; omitting it defaults to 'live' so that
    # inject-and-heal.sh (which calls 'python3 -m dso_reconciler --repo-root ...'
    # with no --mode flag) continues to work with the steady-state production mode.
    parser.add_argument(
        "--mode",
        default=None,
        help=(
            "Rollout-safety mode: reconcile-check | dry-run | bootstrap-strict "
            "| bootstrap-throttle | live (default: live)"
        ),
    )
    parser.add_argument(
        "--dry-run-enumerate",
        action="store_true",
        default=False,
        help=(
            "Print the list of ticket-tracker entries that the reconciler would enumerate "
            "(after .scratch/ exclusion) and exit without running a pass. "
            "Each entry is printed as an absolute path, one per line."
        ),
    )
    parser.add_argument(
        "--filter-local-ids",
        default=None,
        help=(
            "Comma-separated list of local ticket IDs.  When set, all three "
            "differs run on their full unfiltered inputs (same code paths as "
            "production) but only mutations targeting these IDs (or their "
            "bound Jira keys) reach the applier.  For validation use only."
        ),
    )
    args = parser.parse_args(argv)
    # Default to the project repo root when --repo-root is omitted. Mirrors
    # run_pass()'s default at lines 84-85 so the four advisory_lock guard
    # calls below (which declare repo_root: Path, not Optional) never see
    # None and accidentally invoke `git -C None ...` (bug 5be7-d657-1dde-4237).
    repo_root = (
        Path(args.repo_root) if args.repo_root else Path(__file__).resolve().parents[4]
    )

    # --dry-run-enumerate: list enumerable ticket directories and exit.
    # This path is intentionally placed before advisory-lock and mode checks so
    # the flag is usable in test fixtures without a live Jira config or lock state.
    if getattr(args, "dry_run_enumerate", False):
        resolved_root = (
            repo_root if repo_root is not None else Path(__file__).parents[4]
        )
        tickets_dir = resolved_root / ".tickets-tracker"
        if not tickets_dir.is_dir():
            # No tracker directory — emit nothing and exit cleanly.
            return 0
        for entry in sorted(tickets_dir.iterdir()):
            if not entry.is_dir():
                continue
            # Apply the same .scratch/ exclusion used by health.py walkers.
            if ".scratch" in entry.parts:
                continue
            print(entry)
        return 0

    # -------------------------------------------------------------------------
    # Step 1: Mode validation (dd-2) — BEFORE any fetcher reference.
    # Load mode.py under the dotted key so tests can pre-seed sys.modules.
    # -------------------------------------------------------------------------
    mode_mod = _load_sibling_keyed(_MODE_KEY, "mode.py")
    mode_str = args.mode if args.mode is not None else mode_mod.Mode.LIVE.value
    try:
        target_mode = mode_mod.Mode.from_str(mode_str)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    # -------------------------------------------------------------------------
    # Step 1b: reconcile-check mode — read-only diagnostic, no lock needed.
    # -------------------------------------------------------------------------
    if target_mode == mode_mod.Mode.RECONCILE_CHECK:
        return _run_reconcile_check(repo_root)

    # -------------------------------------------------------------------------
    # Step 2: Advisory lock + phase-gate checks.
    # Load _advisory_lock under the dotted key so tests can pre-seed sys.modules.
    # -------------------------------------------------------------------------
    advisory = _load_sibling_keyed(_ADVISORY_LOCK_KEY, "_advisory_lock.py")

    # Step 2a: pass-lock check (dd-3)
    if advisory.check_pass_lock(repo_root):
        print(
            "reconcile: .reconciler-pass-lock present on tickets branch "
            "— another pass in flight",
            file=sys.stderr,
        )
        return 3

    # Step 2b: phase-gate check (dd-4)
    if advisory.check_phase_gate(target_mode, repo_root):
        print(
            f"reconcile: .reconciler-phase-gate blocks advancement to "
            f"{target_mode.value}; remove the file from tickets to advance",
            file=sys.stderr,
        )
        return 4

    # -------------------------------------------------------------------------
    # Step 3: acquire lock, run pass, release in finally
    #
    # Generate pass_id ONCE here and thread it into both the lock-holder and
    # run_pass(). Previously run_pass generated a second timestamp, so under
    # any sub-second clock advance the recorded reconcile pass_id could
    # diverge from the lock owner pass_id — silent operational hazard for
    # post-mortems correlating locks to pass records.
    # -------------------------------------------------------------------------
    pass_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H-%M-%S")
    advisory.acquire_pass_lock(pass_id, repo_root)
    try:
        filter_local_ids: set[str] | None = None
        if args.filter_local_ids is not None:
            parsed = {
                s.strip() for s in args.filter_local_ids.split(",") if s.strip()
            }
            if not parsed:
                print(
                    "ERROR: --filter-local-ids must contain at least one "
                    "non-empty ID",
                    file=sys.stderr,
                )
                return 2
            filter_local_ids = parsed
        return run_pass(
            repo_root=repo_root,
            pass_id=pass_id,
            target_mode=target_mode,
            filter_local_ids=filter_local_ids,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: run_pass raised: {exc}", file=sys.stderr)
        return 1
    finally:
        advisory.release_pass_lock(pass_id, repo_root)


if __name__ == "__main__":
    sys.exit(main())
