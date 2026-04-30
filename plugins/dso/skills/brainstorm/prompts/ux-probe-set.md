# UX Probe Set

Structured probe set for Phase 1 Gate Step 1.5 (UI Intent Detection). When UI intent is confirmed and the `ux_probe_fired` flag is unset, ask these three probes sequentially as free-text follow-up questions.

## Probe Array

```json
[
  {
    "id": "criticality",
    "dimension": "interaction_criticality",
    "prompt": "Which user interactions in this feature are highest-stakes — where a mistake, error, or delay would be most disruptive to the user?",
    "example_good": "The payment submission step — if it fails silently, the user doesn't know their order wasn't placed.",
    "example_bad": "All interactions are important."
  },
  {
    "id": "non_happy_path",
    "dimension": "non_happy_path_coverage",
    "prompt": "What happens when things go wrong in this flow — validation errors, timeouts, empty states, or partial data? Which failure modes are most likely to confuse users?",
    "example_good": "If the API times out during file upload, the user sees a retry prompt and the partial upload is preserved.",
    "example_bad": "Errors show a generic error message."
  },
  {
    "id": "flow_entry_exit",
    "dimension": "flow_entry_exit",
    "prompt": "Where do users enter this flow (entry points) and where do they end up after completing or abandoning it (exit points)?",
    "example_good": "Entry: from the dashboard 'New Report' button or a deep link. Exit: redirected to the report view on success, back to dashboard on cancel.",
    "example_bad": "Users access it from the main menu."
  }
]
```

## Usage

Ask each probe's `prompt` as a free-text follow-up. Do not read out `example_good` or `example_bad` to the user — they are for agent calibration only. Record responses and incorporate them into the epic spec as structured UX intent.
