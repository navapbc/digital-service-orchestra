# Plan Mode Post-Approval Workflow

After a plan is approved via ExitPlanMode, do NOT begin implementation immediately. Instead:

1. **Create a beads epic** from the plan title and context description
2. **Create child tasks** with clear success criteria for each implementation step
   - Follow best practices for LLM agent tasks
   - Include file paths, implementation details, and testable acceptance criteria
3. **Add dependencies**: `bd dep add` between tasks to enforce implementation order
4. **Validate beads health**: Run `validate-beads.sh --quick`
5. **Report**: Epic ID, task dependency graph, and which tasks are ready to work
6. **STOP and wait** for further instructions — do not begin implementing any tasks
