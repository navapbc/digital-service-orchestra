# Skill Trace Format Specification

This document defines the trace log format used by DSO skill observability instrumentation. Trace logs capture breadcrumbs at Skill tool invocation and entry/exit boundaries, enabling post-session analysis of control flow loss patterns.

## Log File Path Convention

```
/tmp/dso-skill-trace-<session-id>.log
```

`<session-id>` is a per-session identifier derived by the instrumentation at the call site (e.g., the first SKILL_INVOKE breadcrumb in a session establishes the file; subsequent breadcrumbs append to the same file).

The analysis script discovers all trace logs via the glob pattern `/tmp/dso-skill-trace-*.log`.

## Breadcrumb Types

Each breadcrumb is a single-line JSON object appended to the log file. Four breadcrumb types are defined:

| Type | Emitted By | When |
|------|-----------|------|
| `SKILL_INVOKE` | Parent skill (e.g., sprint) | Immediately before invoking a child skill via the Skill tool |
| `SKILL_RESUMED` | Parent skill (e.g., sprint) | Immediately after a child skill returns via the Skill tool |
| `SKILL_ENTER` | Child skill (e.g., implementation-plan, preplanning) | At the beginning of the child skill's execution |
| `SKILL_EXIT` | Child skill (e.g., implementation-plan, preplanning) | At the end of the child skill's execution |

> **CONTROL_LOSS** is not a breadcrumb type. It is a derived event detected by the analysis script from an unmatched `SKILL_INVOKE` — a `SKILL_INVOKE` record with no subsequent `SKILL_RESUMED` for the same `session_id` + `session_ordinal` pairing.

## Field Reference

All breadcrumbs share a common JSON schema. Fields are defined as follows:

| Field | Type | Present On | Description |
|-------|------|-----------|-------------|
| `type` | string | all | One of: `SKILL_INVOKE`, `SKILL_RESUMED`, `SKILL_ENTER`, `SKILL_EXIT` |
| `timestamp` | string (ISO 8601) | all | Wall-clock time when the breadcrumb was written, e.g., `"2026-04-02T17:39:27Z"` |
| `skill_name` | string | all | Short name of the skill being tracked, e.g., `"implementation-plan"`, `"preplanning"` |
| `nesting_depth` | integer | all | Nesting depth at time of emission; 0 = top-level call, 1 = first nested call, etc. Passed from parent to child via inline convention (see Depth-Passing Convention below) |
| `skill_file_size` | integer or null | `SKILL_ENTER`, `SKILL_EXIT` | Byte size of the child skill's `SKILL.md` file, resolved via `CLAUDE_PLUGIN_ROOT`. `null` if the file cannot be stat'd |
| `tool_call_count` | integer or null | `SKILL_ENTER`, `SKILL_EXIT` | Session-global tool call counter at time of emission. **Approximate**: counter is best-effort and may not reflect all tool calls accurately (see Known Limitations) |
| `elapsed_ms` | integer or null | `SKILL_EXIT` | Wall-clock milliseconds elapsed between `SKILL_ENTER` and `SKILL_EXIT` for this invocation. `null` if start time is unavailable |
| `session_ordinal` | integer | all | Monotonically increasing invocation count for the session. The first skill invocation in a session is ordinal `1`. **Best-effort**: resets to `1` after context compaction (see Known Limitations) |
| `cumulative_bytes` | integer or null | `SKILL_ENTER`, `SKILL_EXIT` | Running total of `skill_file_size` bytes loaded across all skill invocations in the session up to and including this one. `null` if any prior `skill_file_size` was `null` |
| `termination_directive` | boolean or null | `SKILL_EXIT` | `true` if a termination directive was detected in the child skill's output, `false` if not detected, `null` if detection was not attempted. Detection scans the `STATUS` line of the child skill's output only (see Known Limitations) |
| `user_interaction_count` | integer | `SKILL_EXIT` | Number of user interaction events observed during the child skill's execution. Counted as best-effort from session context |

## Example Breadcrumbs

### SKILL_INVOKE

```json
{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"implementation-plan","nesting_depth":1,"session_ordinal":3,"tool_call_count":42,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}
```

### SKILL_RESUMED

```json
{"type":"SKILL_RESUMED","timestamp":"2026-04-02T17:41:15Z","skill_name":"implementation-plan","nesting_depth":1,"session_ordinal":3,"tool_call_count":58,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}
```

### SKILL_ENTER

```json
{"type":"SKILL_ENTER","timestamp":"2026-04-02T17:39:28Z","skill_name":"implementation-plan","nesting_depth":1,"session_ordinal":3,"tool_call_count":43,"skill_file_size":14208,"elapsed_ms":null,"cumulative_bytes":28416,"termination_directive":null,"user_interaction_count":0}
```

### SKILL_EXIT

```json
{"type":"SKILL_EXIT","timestamp":"2026-04-02T17:41:14Z","skill_name":"implementation-plan","nesting_depth":1,"session_ordinal":3,"tool_call_count":57,"skill_file_size":14208,"elapsed_ms":106000,"cumulative_bytes":28416,"termination_directive":false,"user_interaction_count":1}
```

## Depth-Passing Convention

Nesting depth is passed from a parent skill's call site to the child skill via inline text in the Skill tool invocation prompt. The convention is:

```
DSO_TRACE_NESTING_DEPTH=<N>
```

Where `<N>` is the parent's `nesting_depth + 1`. The parent skill includes this line in the args or preamble passed to the Skill tool. Child skills parse this value from their invocation context to populate `nesting_depth` in their breadcrumbs.

If `DSO_TRACE_NESTING_DEPTH` is absent from the invocation context, the child defaults to `nesting_depth: 1`.

## CONTROL_LOSS Detection

The analysis script (`skill-trace-analyze`) detects control loss as follows:

1. For each `SKILL_INVOKE` breadcrumb in a session, the script checks whether a `SKILL_RESUMED` breadcrumb exists with the same `session_ordinal` and `skill_name`.
2. If no matching `SKILL_RESUMED` is found, the session is classified as having a **CONTROL_LOSS** event at that invocation.
3. CONTROL_LOSS events are reported in the diagnostic output alongside hypothesis classifications.

## Fault Tolerance

All breadcrumb-writing Bash calls MUST use `|| true` to prevent trace failures from breaking skill execution:

```bash
echo '{"type":"SKILL_INVOKE",...}' >> /tmp/dso-skill-trace-${SESSION_ID}.log || true
```

If `/tmp` is not writable, the write silently fails and skill execution continues unaffected.

## Known Limitations

| Limitation | Description |
|-----------|-------------|
| **Ordinal resets on compaction** | `session_ordinal` is maintained in-memory and resets to `1` when the model context is compacted (`/compact`). Analysis scripts treat ordinal as best-effort within a compaction window, not globally unique across a full session |
| **Tool count approximate** | `tool_call_count` reflects a session-global counter that is approximate. The counter may not capture all tool calls (e.g., reads that occur within sub-agent context), and its increment timing relative to other session events is not guaranteed |
| **Termination directive scans STATUS line only** | `termination_directive` detection scans only the `STATUS:` line of the child skill's output (if present). It does not scan the full `SKILL.md` content or all output lines. This means false negatives are possible if a termination directive appears elsewhere, and false positives are possible if the word appears coincidentally in the STATUS line |
| **Session ID stability** | The `session-id` component of the log file name is best-effort. If a session produces multiple trace files (e.g., after restart), the analysis script processes each independently |
| **Elapsed ms precision** | `elapsed_ms` is wall-clock and may include time the model was not actively executing (e.g., waiting for user input). It is not a measure of compute time |

## Analysis Script

The trace analysis script is registered in the DSO shim:

```bash
.claude/scripts/dso skill-trace-analyze [--log <path>] [--all]
```

- Without arguments: processes all `/tmp/dso-skill-trace-*.log` files
- `--log <path>`: processes a specific log file
- `--all`: synonym for the default (process all logs)

The script produces a diagnostic report per session mapping each session to the 10 hypotheses (H1–H10) defined in the epic, marking each as `confirmed`, `refuted`, or `insufficient-data` based on breadcrumb data thresholds.

Full script source: `scripts/skill-trace-analyze.sh` # shim-exempt: canonical source path reference, not an invocation
