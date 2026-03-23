# Plan Mode Post-Approval Workflow

After a plan is approved via ExitPlanMode, do NOT begin implementation immediately. Do NOT prompt to clear context. Instead:

1. **Create a ticket epic** (`ticket create epic "<plan title>"`) from the plan title and context description
2. **Run `/dso:preplanning`** on the newly created epic to decompose it into prioritized user stories with measurable done definitions
3. **Validate issue health**: Run `validate-issues.sh --quick`
4. **Report**: Epic ID, user story dependency graph, and which tasks are ready to work
5. **STOP and wait** for further instructions — do not begin implementing any tasks
