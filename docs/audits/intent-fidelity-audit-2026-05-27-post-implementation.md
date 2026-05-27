# Intent Fidelity Audit: Post-Implementation (2026-05-27)

Second run of the intent fidelity audit prompt, executed after all 4 phases of the intent-fidelity-pipeline were merged to main.

**Audit prompt**: `docs/audits/intent-fidelity-audit-prompt.md`
**Design doc**: `docs/designs/intent-fidelity-pipeline.md`
**PRs merged**: #396 (Phase 1), #397 (Phase 2), #400 (Phase 3), #406 (Phase 4)

---

## Root Cause Resolution Status

| Root Cause | Status | Mechanism |
|-----------|--------|-----------|
| RC1: Verification Gap (verifier cannot execute code) | **RESOLVED** | `pre-verifier-execute.sh` executes DD Verify commands; completion verifier Step 2.7 evaluates traces mechanically; FAIL traces are definitive |
| RC2: DD Measurability Self-Assessed | PARTIALLY RESOLVED | `verify_commands` array with negative-constraint list blocks file-inspection commands; haiku cross-check validates behavioral DDs; but vacuous tests (pytest asserting True) evade detection |
| RC3: Defer-as-Skip | PARTIALLY RESOLVED | Execution traces make failures visible; simplified remediation provides direct-fix path; but obligation tickets have no completion enforcement |
| RC4: Decomposition Coverage Gaps | PARTIALLY RESOLVED | Verify-intent on SCs flows to verify_commands on DDs; but commands are speculative (test files don't exist at planning time); mutability is SHOULD not MUST |
| RC5: Scrutiny Gates Bypassable | PARTIALLY RESOLVED | HARD-GATE language is strong; PIL marker required for brainstorm:complete tag; but enforcement is behavioral (LLM compliance), not mechanical |

## Intent Fidelity Scorecard (Before vs. After)

| Stage | Before | After | What Changed |
|-------|--------|-------|-------------|
| 1. Brainstorming | MEDIUM | **HIGH** | Step 2.15 Verify-intent drafting (subject+action+observable); classify-sc-type.sh deterministic classifier; negative-constraint list |
| 2. Preplanning | MEDIUM | **MEDIUM** | verify_commands array on DDs; Step 1b writes to tickets; but commands are speculative (reference test files that don't yet exist) |
| 3. Implementation Plan | LOW | **MEDIUM** | Step 5b haiku cross-check validates behavioral DDs; but cross-check is syntactic (catches grep-as-test, not pytest-as-no-op) |
| 4. Sprint | LOW | **MEDIUM** | Pre-verifier execution HARD-GATE; simplified remediation for clear errors; verify command mutability; but HARD-GATE is behavioral enforcement on LLM |
| 5. Verification | LOW | **HIGH** | Step 2.7 trace evaluation with mechanical rules; FAIL is definitive; EVIDENCE_PENDING blocks closure; aspirational detection as secondary check |
| 6. Closure | MEDIUM | **LOW** | EVIDENCE_PENDING halts pipeline; check-verifier-verdict.sh handles it; but `ticket transition ... closed` has no mechanical check for verifier verdict |

## New Risks Introduced

### 3.1 False Confidence from Partial Traces (LOW)
Trace with 3/5 PASS and 2/5 EVIDENCE_PENDING could be perceived as "mostly done." Mitigated by EVIDENCE_PENDING escalation requiring explicit user action.

### 3.2 Simplified Remediation Masking Deeper Issues (LOW)
NotImplementedError stubs might be symptoms of architectural issues. Mitigated by max-1-per-story cap and full re-run after fix.

### 3.3 Verify Command Staleness (MEDIUM)
Commands reference speculative paths that may not match actual implementation. Mutability is SHOULD not MUST. Stale commands waste remediation cycles.

### 3.4 Backward Compatibility as Bypass Channel (MEDIUM)
When pre-verifier-execute.sh exits non-zero, the orchestrator falls back to `VERIFY_TRACE_PATH=""` — silently losing the primary defense layer. The instruction says "log the error" but does not specify visibility level.

## Remaining Gaps (Priority Order)

1. **No hard enforcement on closure path (HIGH)**: `ticket transition ... closed` has no mechanical check for verifier dispatch. The HARD-GATE is behavioral instruction text, not a hook that blocks the transition.

2. **Speculative Verify commands (MEDIUM)**: Commands written at planning time reference test files that don't yet exist. Sub-agents may not update them (SHOULD not MUST).

3. **Vacuous test detection (MEDIUM)**: Pipeline catches file-inspection commands but not semantically vacuous tests (pytest asserting True, exit 0 with no prior commands).

4. **Obligation ticket completion (LOW-MEDIUM)**: Deferred-evidence obligation tickets have no enforcement of completion. Could become a new defer-as-skip vector.

5. **Cross-stage intent drift (LOW)**: Semantic narrowing across 4 translation stages (intent → command → test → trace). Phase 3 subject-noun check is a weak signal.

## Recommendations

### 1. Add a Transition Hook for Verification Gate (HIGHEST PRIORITY)
Block `ticket transition <id> ... closed` for story/epic tickets unless a completion-verifier PASS verdict exists. Converts the behavioral HARD-GATE into mechanical enforcement. Config-gated via `verify.require_verdict_for_close`.

### 2. Make Verify Command Mutability a MUST
After each sub-agent returns, compare Verify command's test file path against actually-created files via Glob. If path doesn't exist, flag as required update.

### 3. Add Vacuous Test Detector
After PASS trace, read the test file and apply deterministic check: if test contains only `assert True`, `exit 0` with no prior commands, or `skip`/`xfail` on all functions → downgrade to EVIDENCE_PENDING.

### 4. Sweep Obligation Tickets in /dso:retro
Include obligation tickets in retro's stale-ticket detection. Surface past-deadline open obligations as P2 findings.

### 5. Elevate Degradation Visibility
When pre-verifier falls back to empty trace, emit structured DEGRADATION_EVENT on the ticket and include `VERIFY_TRACE_DEGRADATION: true` in verifier prompt.

## Overall Assessment

The pipeline moves from "structural presence is sufficient" to "behavioral proof is expected." The 72% gap rate from the d076 postmortem should decrease substantially for new epics. The system's remaining vulnerability is that every enforcement point above the ticket CLI layer is behavioral guidance consumed by an LLM orchestrator. The HARD-GATE pattern raises the bar from "trivially bypassable" to "requires significant LLM reasoning failure to bypass" — but is not "mechanically impossible to bypass." Recommendation 1 (transition hook) would close this gap.
