#!/usr/bin/env bash
# hooks/lib/validate-check-runners.sh
# Check runner functions extracted from validate.sh:
#   - run_test_check: time-bounded test runner via test-batched.sh
#   - check_migrations: migration heads check (file-based, no DB required)
#   - check_hook_drift: DSO hook drift between .pre-commit-config.yaml and examples/
#   - check_ci: CI status check via gh CLI
#
# Callers must have the following variables set before calling these functions
# (they are set by validate.sh in the main script body):
#   CHECK_DIR, VERBOSE, VERBOSE_LOCK_FILE, APP_DIR, REPO_ROOT, WORKTREE_MODE,
#   TIMEOUT_TESTS, TIMEOUT_CI, CMD_TEST_UNIT, CMD_TEST_DIRS,
#   VALIDATE_TEST_STATE_FILE, VALIDATE_TEST_BATCHED_SCRIPT
#
# CMD_TEST_DIRS (optional): colon-separated list of directories containing test-*.sh files.
# When set, run_test_check uses --runner=bash --test-dir=$CMD_TEST_DIRS so each
# test-*.sh file runs as an individual resumable item (incremental progress).
# When unset or empty, falls back to CMD_TEST_UNIT via the generic runner.
#
# Also requires run_with_timeout, verbose_print, _test_state_already_passed
# (from validate-helpers.sh) to be available.
#
# Source this file from validate.sh after validate-helpers.sh is sourced.

# run_test_check: time-bounded test runner using test-batched.sh.
# Checks state file first (reuse pass from previous invocation).
# If tests already passed: writes rc=0 immediately (skips re-running).
# If not: runs test-batched.sh with --timeout=45 (within Claude tool ceiling).
# If test-batched.sh outputs the Structured Action-Required Block: writes rc=42 (pending, needs another run).
run_test_check() {
    local name="tests" timeout="$TIMEOUT_TESTS" test_cmd="$CMD_TEST_UNIT"
    [ "$VERBOSE" = "1" ] && verbose_print "$name" "running"

    # ── Reuse cached result if tests already passed this session ─────────────
    if _test_state_already_passed "$VALIDATE_TEST_STATE_FILE" "$test_cmd"; then
        echo "0" > "$CHECK_DIR/${name}.rc"
        echo "(reused from session state)" > "$CHECK_DIR/${name}.log"
        [ "$VERBOSE" = "1" ] && verbose_print "$name" "PASS (reused from session state)"
        return 0
    fi

    # ── Run tests via test-batched.sh ─────────────────────────────────────────
    # Use a 45s budget (well within the ~73s Claude tool timeout ceiling).
    # test-batched.sh saves state and emits the Structured Action-Required Block when the budget is exhausted,
    # allowing validate.sh to be re-invoked to continue where tests left off.
    local batched_timeout=45
    local batched_script="$VALIDATE_TEST_BATCHED_SCRIPT"

    if [ -x "$batched_script" ]; then
        local rc=0
        # When CMD_TEST_DIRS is configured (colon-separated dirs), use the bash runner
        # so each test-*.sh file runs as an individual resumable item. This enables
        # incremental progress across validate.sh re-invocations for large test suites
        # that exceed the 45s budget. Without this, the generic runner treats the entire
        # suite as one atomic command and records it as "interrupted" on timeout, causing
        # an infinite PENDING loop (bug 07f1-f8b6 / bf39-4494).
        local batched_runner_args=""
        if [ -n "${CMD_TEST_DIRS:-}" ]; then
            batched_runner_args="--runner=bash --test-dir=${CMD_TEST_DIRS}"
        fi
        # Run test-batched.sh with the session state file; capture both stdout+stderr.
        # test-batched.sh manages its own internal timeout budget (--timeout=45).
        # The outer run_with_timeout uses the full TIMEOUT_TESTS as a safety
        # backstop for truly hung processes that exceed the internal budget.
        # shellcheck disable=SC2086
        TEST_BATCHED_STATE_FILE="$VALIDATE_TEST_STATE_FILE" \
            run_with_timeout "$timeout" "$name" \
            bash "$batched_script" --timeout="$batched_timeout" --per-test-timeout="$batched_timeout" $batched_runner_args "$test_cmd" \
            > "$CHECK_DIR/${name}.log" 2>&1 || rc=$?
        echo "$rc" > "$CHECK_DIR/${name}.rc"

        # Detect partial run: test-batched.sh emits the Structured Action-Required Block
        # when the time budget is exhausted (contains "ACTION REQUIRED").
        # In this case it exits 0, but tests are not done — mark as pending (rc=42).
        if [ "$rc" = "0" ] && grep -qE "ACTION REQUIRED|action required" "$CHECK_DIR/${name}.log" 2>/dev/null; then
            echo "42" > "$CHECK_DIR/${name}.rc"
            [ "$VERBOSE" = "1" ] && verbose_print "$name" "PENDING (run validate.sh again to continue)"
            return 0
        fi

        if [ "$VERBOSE" = "1" ]; then
            if [ "$rc" = "0" ]; then
                verbose_print "$name" "PASS"
            elif [ "$rc" = "124" ]; then
                verbose_print "$name" "FAIL (timeout ${timeout}s)"
            else
                verbose_print "$name" "FAIL"
            fi
        fi
    else
        # Fallback: test-batched.sh not available — run directly (original behavior)
        local rc=0
        # shellcheck disable=SC2086
        run_with_timeout "$timeout" "$name" $test_cmd > "$CHECK_DIR/${name}.log" 2>&1 || rc=$?
        echo "$rc" > "$CHECK_DIR/${name}.rc"
        if [ "$VERBOSE" = "1" ]; then
            if [ "$rc" = "0" ]; then
                verbose_print "$name" "PASS"
            elif [ "$rc" = "124" ]; then
                verbose_print "$name" "FAIL (timeout ${timeout}s)"
            else
                verbose_print "$name" "FAIL"
            fi
        fi
    fi
}

# Migration heads check (file-based, no DB required)
check_migrations() {
    local migration_dir="$APP_DIR/src/db/migrations/versions"
    [ "$VERBOSE" = "1" ] && verbose_print "migrate" "running"

    if [ ! -d "$migration_dir" ]; then
        echo "skip" > "$CHECK_DIR/migrate.rc"
        [ "$VERBOSE" = "1" ] && verbose_print "migrate" "PASS (skipped)"
        return 0
    fi

    local all_revs down_revs head_count=0 heads=""
    all_revs=$(grep -h '^revision' "$migration_dir"/*.py 2>/dev/null | sed 's/.*= *"\([^"]*\)".*/\1/' | sort -u)
    down_revs=$(grep -h '^down_revision' "$migration_dir"/*.py 2>/dev/null | sed 's/.*= *"\([^"]*\)".*/\1/' | sort -u)

    for rev in $all_revs; do
        if ! echo "$down_revs" | grep -q "^${rev}$"; then
            head_count=$((head_count + 1))
            heads="$heads $rev"
        fi
    done

    if [ "$head_count" -le 1 ]; then
        echo "0" > "$CHECK_DIR/migrate.rc"
        echo "1 head" > "$CHECK_DIR/migrate.info"
        [ "$VERBOSE" = "1" ] && verbose_print "migrate" "PASS"
    else
        echo "1" > "$CHECK_DIR/migrate.rc"
        echo "$head_count heads:$heads" > "$CHECK_DIR/migrate.info"
        [ "$VERBOSE" = "1" ] && verbose_print "migrate" "FAIL ($head_count heads)"
    fi
}

# Hook drift check: DSO hooks in .pre-commit-config.yaml must also exist in examples/
check_hook_drift() {
    [ "$VERBOSE" = "1" ] && verbose_print "hook-drift" "running"

    local own_config="$REPO_ROOT/.pre-commit-config.yaml"
    local example_config="${CLAUDE_PLUGIN_ROOT}/docs/examples/pre-commit-config.example.yaml"

    # Skip if either file is missing (non-DSO-plugin repos won't have both)
    if [ ! -f "$own_config" ] || [ ! -f "$example_config" ]; then
        echo "skip" > "$CHECK_DIR/hook-drift.rc"
        [ "$VERBOSE" = "1" ] && verbose_print "hook-drift" "PASS (skipped)"
        return 0
    fi

    # Extract hook IDs from both configs and compare.
    # Hooks listed in .hook-drift-allowlist (one ID per line, # comments ok) are
    # intentionally absent from examples/ and excluded from drift comparison.
    local own_hooks example_hooks missing="" missing_count=0
    local allowlist_file="$REPO_ROOT/.hook-drift-allowlist"
    local allowlist=""
    if [ -f "$allowlist_file" ]; then
        allowlist=$(grep -v '^\s*#' "$allowlist_file" | grep -v '^\s*$' | tr -d ' ' | sort)
    fi
    own_hooks=$(grep -E '^\s+- id:' "$own_config" | sed 's/.*- id: *//' | tr -d ' ' | sort)
    example_hooks=$(grep -E '^\s+- id:' "$example_config" | sed 's/.*- id: *//' | tr -d ' ' | sort)

    while IFS= read -r hook_id; do
        [ -z "$hook_id" ] && continue
        # Skip hooks in the allowlist (intentionally absent from examples/)
        if [ -n "$allowlist" ] && echo "$allowlist" | grep -qx "$hook_id"; then
            continue
        fi
        if ! echo "$example_hooks" | grep -qx "$hook_id"; then
            missing="${missing:+$missing, }$hook_id"
            missing_count=$((missing_count + 1))
        fi
    done <<< "$own_hooks"

    if [ "$missing_count" -eq 0 ]; then
        echo "0" > "$CHECK_DIR/hook-drift.rc"
        echo "all hooks present in example" > "$CHECK_DIR/hook-drift.info"
        [ "$VERBOSE" = "1" ] && verbose_print "hook-drift" "PASS"
    else
        echo "1" > "$CHECK_DIR/hook-drift.rc"
        printf "hooks in .pre-commit-config.yaml missing from examples/: %s\n" "$missing" > "$CHECK_DIR/hook-drift.log"
        echo "$missing_count missing" > "$CHECK_DIR/hook-drift.info"
        [ "$VERBOSE" = "1" ] && verbose_print "hook-drift" "FAIL ($missing_count hooks missing from example)"
    fi
}

# CI status check:
# - completed:success → PASS
# - completed:failure → FAIL
# - cancelled → skip; use last non-cancelled completed run's result
# - pending + previous success → PASS (assume still good)
# - pending + previous failure → FAIL immediately
# - pending + no previous completed run → PASS (no failure evidence)
check_ci() {
    [ "$VERBOSE" = "1" ] && verbose_print "ci" "running"

    # jq is required for CI status parsing (complex array/object expressions).
    # Without it, skip with a warning rather than producing garbage output.
    if ! command -v jq &>/dev/null; then
        echo "skip" > "$CHECK_DIR/ci.rc"
        echo "WARNING: jq not installed — CI status check skipped" > "$CHECK_DIR/ci.log"
        [ "$VERBOSE" = "1" ] && verbose_print "ci" "PASS (skipped: jq not installed)"
        return
    fi
    cd "$REPO_ROOT" || return
    local gh_branch_flag=""
    [ "$WORKTREE_MODE" -eq 1 ] && gh_branch_flag="--branch main"

    # Fetch recent CI runs with full metadata for commit analysis.
    # We fetch up to 10 so we can skip cancelled runs when looking for the
    # last meaningful (success/failure) result.
    local ci_json
    ci_json=$(
        (
            # shellcheck disable=SC2086
            run_with_timeout "$TIMEOUT_CI" "ci-status" \
                gh run list --workflow=CI $gh_branch_flag --limit 10 \
                --json status,conclusion,databaseId,headSha,createdAt \
                2>/dev/null
        ) || echo "TIMEOUT_OR_ERROR"
    )

    if [ "$ci_json" = "TIMEOUT_OR_ERROR" ]; then
        echo "TIMEOUT_OR_ERROR" > "$CHECK_DIR/ci.result"
        echo "error" > "$CHECK_DIR/ci.rc"
        [ "$VERBOSE" = "1" ] && verbose_print "ci" "FAIL (timeout/error)"
        return
    fi

    local latest_status latest_conclusion latest_id latest_sha latest_created
    latest_status=$(echo "$ci_json" | jq -r '.[0].status' 2>/dev/null)
    latest_conclusion=$(echo "$ci_json" | jq -r '.[0].conclusion // ""' 2>/dev/null)
    latest_id=$(echo "$ci_json" | jq -r '.[0].databaseId' 2>/dev/null)
    latest_sha=$(echo "$ci_json" | jq -r '.[0].headSha' 2>/dev/null)
    latest_created=$(echo "$ci_json" | jq -r '.[0].createdAt' 2>/dev/null)

    # Find the most recent *non-cancelled* completed run (skipping the latest run itself).
    # This ensures cancelled runs are never treated as previous failures.
    local prev_conclusion prev_id prev_sha
    prev_conclusion=$(echo "$ci_json" | jq -r '[.[1:] | .[] | select(.status == "completed" and .conclusion != "cancelled")][0].conclusion // ""' 2>/dev/null)
    prev_id=$(echo "$ci_json" | jq -r '[.[1:] | .[] | select(.status == "completed" and .conclusion != "cancelled")][0].databaseId // ""' 2>/dev/null)
    prev_sha=$(echo "$ci_json" | jq -r '[.[1:] | .[] | select(.status == "completed" and .conclusion != "cancelled")][0].headSha // ""' 2>/dev/null)

    # If latest run is completed, report directly.
    # A "cancelled" conclusion means the run was manually stopped — not a test failure.
    # Fall through to the previous run's result to determine the true CI health.
    if [ "$latest_status" = "completed" ] && [ "$latest_conclusion" != "cancelled" ]; then
        echo "completed:$latest_conclusion" > "$CHECK_DIR/ci.result"
        if [ "$latest_conclusion" = "success" ]; then
            echo "0" > "$CHECK_DIR/ci.rc"
            [ "$VERBOSE" = "1" ] && verbose_print "ci" "PASS"
        else
            echo "1" > "$CHECK_DIR/ci.rc"
            [ "$VERBOSE" = "1" ] && verbose_print "ci" "FAIL ($latest_conclusion)"
        fi
        return
    fi

    # Latest run was cancelled — treat it like a pending run and check the previous result
    if [ "$latest_status" = "completed" ] && [ "$latest_conclusion" = "cancelled" ]; then
        if [ "$prev_conclusion" = "success" ]; then
            echo "completed:success" > "$CHECK_DIR/ci.result"
            echo "0" > "$CHECK_DIR/ci.rc"
            echo "true" > "$CHECK_DIR/ci.skipped_wait"
            echo "true" > "$CHECK_DIR/ci.was_cancelled"
            [ "$VERBOSE" = "1" ] && verbose_print "ci" "PASS (latest run cancelled; previous run passed)"
            return
        elif [ -n "$prev_conclusion" ] && [ "$prev_conclusion" != "null" ]; then
            # Previous non-cancelled run failed — treat as if CI is pending with a previous failure
            # (fall through to the pending+failure path below)
            latest_status="in_progress"
        else
            # No usable non-cancelled previous run — report cancelled as non-failure
            echo "completed:cancelled" > "$CHECK_DIR/ci.result"
            echo "0" > "$CHECK_DIR/ci.rc"
            echo "true" > "$CHECK_DIR/ci.was_cancelled"
            [ "$VERBOSE" = "1" ] && verbose_print "ci" "PASS (run was cancelled, no prior run to compare)"
            return
        fi
    fi

    # Latest is pending/in_progress — check previous completed run
    if [ "$prev_conclusion" = "success" ]; then
        # Previous CI was green — assume still good, don't wait
        echo "completed:success" > "$CHECK_DIR/ci.result"
        echo "0" > "$CHECK_DIR/ci.rc"
        echo "true" > "$CHECK_DIR/ci.skipped_wait"
        [ "$VERBOSE" = "1" ] && verbose_print "ci" "PASS (pending, previous run passed)"
        return
    fi

    if [ -n "$prev_conclusion" ] && [ "$prev_conclusion" != "null" ]; then
        # Previous CI failed — report failure immediately.
        # Use ci-status.sh --wait to wait for the pending run to complete.
        echo "in_progress:failure" > "$CHECK_DIR/ci.result"
        echo "1" > "$CHECK_DIR/ci.rc"
        echo "true" > "$CHECK_DIR/ci.pending_with_failure"
        [ "$VERBOSE" = "1" ] && verbose_print "ci" "FAIL (pending, previous run failed)"
        return
    fi

    # No previous non-cancelled completed run found — no evidence of failure.
    # Treat as passing (CI hasn't had a chance to report yet).
    echo "in_progress:no_history" > "$CHECK_DIR/ci.result"
    echo "0" > "$CHECK_DIR/ci.rc"
    echo "true" > "$CHECK_DIR/ci.skipped_wait"
    [ "$VERBOSE" = "1" ] && verbose_print "ci" "PASS (pending, no previous completed run)"
}
