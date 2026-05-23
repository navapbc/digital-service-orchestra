# Health Record Contract

Schema version: 1

File location: `bridge_state/health/<pass_id>.json`

## Fields

| Field | Type | Description |
|-------|------|-------------|
| schema_version | int | Always 1 for this version |
| pass_id | str | Reconciler pass identifier |
| pre_pass_fsck_total | int | Bridge fsck total before pass |
| post_pass_fsck_total | int | Bridge fsck total after pass |
| per_type_open_counts | dict | Open count per ticket type {epic,story,task,bug} |
| local_mutation_count_at_pass | int | Number of mutations applied |
| timestamp_ns | int | UTC epoch nanoseconds when record was written |
