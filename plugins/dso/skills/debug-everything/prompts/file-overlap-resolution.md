# File Overlap Resolution (Phase H Step 4)

Loaded only when sub-agents in a Phase G batch may have modified overlapping files. Skipped in Bug-Fix Mode and skipped when zero conflicts are detected.

## 1. Collect modified files per agent

From Task results or `git diff --name-only` after worktree integration.

## 2. Run overlap detection

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh file-overlap \  # shim-exempt: internal orchestration script
  --agent=<task-id-1>:<file1>,<file2> \
  --agent=<task-id-2>:<file3>,<file4>
```

Outputs `CONFLICTS: <N>` plus one `CONFLICT:` line per overlap with `PRIMARY=<agent>` and `SECONDARY=<agent1>,<agent2>`. Exit 0 = no conflicts; exit 1 = conflicts.

If zero conflicts → return; proceed to the calling phase's next step (critic review).

## 3. Resolve each conflicting file

- **Primary agent**: the one whose ticket is most directly about that file (highest priority or most file-specific).
- **Secondary agents**: all others. Capture each secondary's diff for the conflicting files first, then revert all at once: `git checkout -- <conflicting-files>`.
- Re-run secondary agents **one at a time, in priority order** (not parallel), each with original prompt plus a `### Conflict Resolution Context` block containing the captured diff and an instruction not to overwrite the primary's changes. Commit each re-run before launching the next.

After each re-run:
- Agent only touched non-conflicting files → success.
- Agent overwrote the same files again:
  - Non-interactive: apply Non-Interactive Deferral Protocol with `gate_name=file_overlap`. Revert (`git checkout -- <conflicting-files>`). Proceed to the calling phase's critic-review step.
  - Interactive: escalate to user; do not retry.

## 4. Oscillation guard (paired with critic review)

Track critic outcomes per issue ID. On the **2nd CONCERN for the same issue**, invoke `/dso:oscillation-check` (sub-agent, model="sonnet") with `context=critic`. If it returns `OSCILLATION`:
- Non-interactive: apply Non-Interactive Deferral Protocol with `gate_name=oscillation_guard`. Record both fix approaches and both critic concerns in the deferral comment. Leave bug open. Do NOT retry.
- Interactive: escalate to user with both fix approaches and both concerns. Do NOT retry.
