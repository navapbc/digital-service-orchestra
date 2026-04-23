# ticket-lib-api.sh Extension Pattern

Reference guide for adding new ops to the sourceable `ticket-lib-api.sh` library (under the plugin scripts directory). The rules below are documented in the SOURCEABILITY CONTRACT at the top of that file and enforced by the pre-commit test suite.

---

## 1. Function Naming Convention

Public ops exposed to callers use the `ticket_` prefix:

```
ticket_show     ticket_list     ticket_create
ticket_comment  ticket_edit     ticket_tag
ticket_untag    ticket_transition  ticket_link
```

Private helpers used only within the library use the `_ticketlib_` prefix:

```
_ticketlib_dispatch    (defined at file scope — wraps each op in a subshell)
```

**`_ticketlib_dispatch`** is the canonical way the dispatcher invokes public ops. It wraps the call in a subshell so per-call `set -e`, traps, and variable mutations cannot leak back into the caller:

```bash
_ticketlib_dispatch() {
    local op="$1"
    shift
    ( "$op" "$@" )
}
```

The `ticket` dispatcher calls it as: `_ticketlib_dispatch ticket_show "$@"`.

Never use `TICKET_`, `_TICKET_`, or any other namespace — those collide with caller-visible variables.

---

## 2. Argv Parsing Convention

Two styles are used, depending on the op's interface.

### Flag-style (associative array) — used by `ticket_edit`

When the op accepts multiple named fields with no required positional args after the ticket ID:

```bash
local ticket_id="$1"
shift

declare -A fields
while [ $# -gt 0 ]; do
    local arg="$1"
    case "$arg" in
        --*=*)
            local field_name="${arg%%=*}"
            field_name="${field_name#--}"
            local field_value="${arg#*=}"
            fields["$field_name"]="$field_value"
            shift
            ;;
        --*)
            local field_name="${arg#--}"
            if [ $# -lt 2 ]; then
                echo "Error: --$field_name requires a value" >&2
                return 1
            fi
            shift
            fields["$field_name"]="$1"
            shift
            ;;
        *)
            echo "Error: unexpected argument '$arg'" >&2
            return 1
            ;;
    esac
done
```

Both `--field=value` and `--field value` forms are accepted. Unrecognized flags return 1.

### Positional + optional flags — used by `ticket_show`, `ticket_comment`

When the op takes one or two required positional args plus optional flags:

```bash
local format="default"
local ticket_id=""
local arg
for arg in "$@"; do
    case "$arg" in
        --format=llm)
            format="llm"
            ;;
        --format=*)
            echo "Error: unsupported format '${arg#--format=}'" >&2
            return 1
            ;;
        -*)
            echo "Error: unknown option '$arg'" >&2
            return 1
            ;;
        *)
            if [ -z "$ticket_id" ]; then
                ticket_id="$arg"
            fi
            ;;
    esac
done
```

Use the `for arg in "$@"` form (not `while [ $# -gt 0 ]; do shift`) when positional and flag args may appear in any order. Use the `while`/`shift` form (as in the flag-style section above) only when strict left-to-right consumption is needed.

---

## 3. Error Return Codes

Inside library functions, always use `return` — never `exit` (which would kill the caller's shell).

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (validation failure, not-found, I/O failure) |
| 2 | Optimistic concurrency conflict (current status has changed since read) |
| 3 | Not-found (ticket directory does not exist) |

Codes 2 and 3 allow callers to distinguish transient conflicts from missing data without parsing stderr. Use 1 for all other failures.

---

## 4. DSO_TICKET_LEGACY=1 Guard Pattern

Every `ticket_*` function must begin with the legacy escape hatch, then open a subshell for the implementation body. Copy this template exactly:

```bash
ticket_myop() {
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-myop.sh" "$@"
        return $?
    fi
    (
        set -euo pipefail
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true
        source "$_TICKETLIB_DIR/ticket-lib.sh"
        # ... implementation
    )
}
```

Key points:

- `DSO_TICKET_LEGACY=1` delegates to the legacy standalone script, preserving behavior when the bash-native path is unavailable (e.g., CI environment regressions).
- `set -euo pipefail` is **inside** the subshell — it never leaks to the caller.
- The `unset` line clears git hook env vars so git commands inside the function target the correct repo, not the hook's injected worktree.
- `source "$_TICKETLIB_DIR/ticket-lib.sh"` makes `write_commit_event` and `ticket_read_status` available. Omit this line only if the op performs no writes and no status reads.
- `_TICKETLIB_DIR` is set at file scope (before the source guard) and is always available.

---

## 5. Write/Read Integration Points

### Writing events

All event writes go through `write_commit_event` from `ticket-lib.sh`. This is bash-native (uses `jq`; no python3 required for the write path):

```bash
# 1. Build the event JSON into a temp file.
local temp_event
temp_event=$(mktemp "$TRACKER_DIR/.tmp-myop-XXXXXX")
# shellcheck disable=SC2064
trap "rm -f '$temp_event'" EXIT

python3 -c "
import json, sys, time, uuid
event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'MYOP',      # must match an allowed enum in ticket-lib.sh
    'env_id': sys.argv[1],
    'author': sys.argv[2],
    'data': { ... }
}
with open(sys.argv[3], 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$env_id" "$author" "$temp_event"

# 2. Commit it atomically.
write_commit_event "$ticket_id" "$temp_event"
rm -f "$temp_event"
```

`write_commit_event <ticket_id> <temp_event_json_path>` — acquires a file lock, writes the event file to the tickets worktree, and commits it. Returns 1 on failure; never exits.

The `event_type` value must be one of the allowed enum values defined in `ticket-lib.sh` (`CREATE`, `STATUS`, `COMMENT`, `LINK`, `UNLINK`, `SNAPSHOT`, `SYNC`, `REVERT`, `EDIT`, `ARCHIVED`). To introduce a new event type, add it to that enum first.

### Reading full ticket state

When the op needs all fields (title, tags, links, comments):

```bash
_TICKET_DIR="$TRACKER_DIR/$ticket_id" \
_TICKET_ID="$ticket_id" \
_SCRIPT_DIR="$_TICKETLIB_DIR" python3 -c "
import sys, os, json
sys.path.insert(0, os.environ['_SCRIPT_DIR'])
from ticket_reducer import reduce_ticket
state = reduce_ticket(os.environ['_TICKET_DIR'])
# use state dict
"
```

`reduce_ticket(ticket_dir)` (imported from the `ticket_reducer` Python package) materializes the full event log into a state dict.

### Reading status only

When the op only needs the current status string:

```bash
local current_status
current_status=$(ticket_read_status "$TRACKER_DIR" "$ticket_id") || return 1
```

`ticket_read_status <tracker_dir> <ticket_id>` is cheaper than a full reduce — use it for optimistic concurrency checks before writes.

---

## 6. Sourceability Checklist

These rules are enforced by the SOURCEABILITY CONTRACT at the top of `ticket-lib-api.sh`. The pre-commit test suite also checks them. Verify each before opening a PR:

- [ ] **No file-scope `set -euo pipefail`** — would leak strict mode into the caller's shell.
- [ ] **No file-scope `exit`** — would kill the caller process.
- [ ] **No file-scope `trap`** — would clobber caller traps.
- [ ] **No file-scope mutation of `GIT_DIR` / `GIT_INDEX_FILE` / `GIT_WORK_TREE` / `GIT_COMMON_DIR`** — would corrupt the caller's git environment.
- [ ] **Function and variable names use only `ticket_` or `_ticketlib_` namespace** — no `_TICKET_` or other names that collide with caller-visible variables.
- [ ] **Idempotent source guard at top of file** — re-sourcing is a no-op:
  ```bash
  if declare -f _ticketlib_dispatch >/dev/null 2>&1; then
      return 0 2>/dev/null
  fi
  ```
- [ ] **Each `ticket_*` function uses a subshell for `set -euo pipefail` scope** — strict mode is never file-scope; it is confined to the `( ... )` block inside each function.

---

## Worked Example: Adding `ticket_assign`

Suppose a downstream epic adds an `assign` subcommand that sets the `assignee` field via an EDIT event.

**Step 1 — add the function to `ticket-lib-api.sh`:**

```bash
# ── ticket_assign ─────────────────────────────────────────────────────────────
# Sets the assignee field on a ticket.
ticket_assign() {
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-assign.sh" "$@"
        return $?
    fi

    (
        set -euo pipefail
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true
        # shellcheck source=/dev/null
        source "$_TICKETLIB_DIR/ticket-lib.sh"

        local TRACKER_DIR
        if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
            TRACKER_DIR="$TICKETS_TRACKER_DIR"
        else
            local REPO_ROOT
            REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        if [ $# -lt 2 ]; then
            echo "Usage: ticket assign <ticket_id> <assignee>" >&2
            return 1
        fi

        local ticket_id="$1"
        local assignee="$2"

        if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
            echo "Error: ticket '$ticket_id' does not exist" >&2
            return 3
        fi

        local env_id author
        env_id=$(cat "$TRACKER_DIR/.env-id")
        author=$(git config user.name 2>/dev/null || echo "Unknown")

        local temp_event
        temp_event=$(mktemp "$TRACKER_DIR/.tmp-assign-XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$temp_event'" EXIT

        python3 -c "
import json, sys, time, uuid
event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'EDIT',
    'env_id': sys.argv[1],
    'author': sys.argv[2],
    'data': {'fields': {'assignee': sys.argv[3]}}
}
with open(sys.argv[4], 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$env_id" "$author" "$assignee" "$temp_event"

        write_commit_event "$ticket_id" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to commit EDIT event" >&2
            return 1
        }
        rm -f "$temp_event"
    )
}
```

**Step 2 — wire it in the `ticket` dispatcher:**

```bash
assign)
    source "$SCRIPT_DIR/ticket-lib-api.sh"
    _ticketlib_dispatch ticket_assign "$@"
    ;;
```

**Step 3 — verify the sourceability checklist** (all seven items above) before committing.
