# Investigation Prompt Selector

These are **distinct investigation prompts** — each applies a different process
(depth and technique), even though they share the root-cause RESULT schema. They
are NOT interchangeable and NOT parameterizations of one base. This index helps a
caller pick the right one (or dispatch several in parallel for synthesis); it does
not combine them.

## By complexity and technique

| Situation | Use |
|-----------|-----|
| Simple, single-file/subsystem defect; one fix wanted | `investigate-bug-root-cause` |
| Moderate, possibly multi-file, non-obvious cause; want ranked candidates + fix options | `investigate-bug-intermediate` |
| High complexity; evidence is in the code's execution behavior | `investigate-bug-advanced-code-tracer` |
| High complexity; a regression — evidence is in change history | `investigate-bug-advanced-historical` |
| Several related bugs — one shared cause or independent ones? | `investigate-bug-cluster` |
| Advanced stalled; suspect execution-path/concurrency — go deeper | `investigate-bug-escalated-code-tracer` |
| Advanced stalled; suspect deep change history (config/CI/merges) | `investigate-bug-escalated-history` |
| Advanced stalled; suspect a dependency/known upstream issue | `investigate-bug-escalated-web` |
| Theoretical consensus exists; need empirical ground truth (can veto) | `investigate-bug-escalated-empirical` |

## Composition patterns (not prompts)

- **Advanced parallel:** run `investigate-bug-advanced-code-tracer` and
  `investigate-bug-advanced-historical` concurrently; a caller compares their
  `ROOT_CAUSE` for convergence and escalates if they diverge.
- **Escalated parallel:** run the three theoretical escalated lenses
  (`code-tracer`, `history`, `web`) concurrently, then
  `investigate-bug-escalated-empirical` to confirm or veto their consensus.

A note on `intermediate-fallback`: the source agent of that name is, by its own
declaration, identical in process and criteria to the intermediate tier (only the
dispatch persona differs). Per the one-operation-per-prompt rule, it is the same
operation as `investigate-bug-intermediate` and is not given a separate prompt.
