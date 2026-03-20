---
id: w21-bsnz
status: open
deps: []
links: []
created: 2026-03-20T20:55:26Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-87
---
# Create a process to remediate legacy code

We want to create a process that is capable of improving the code quality of an existing project. Using this process repeatedly on the same codebase should result in improvement or no change, not regression or spiraling complexity. This process should assume a fragile system actively in use, and approach the process with a principle similar to medicine: first, do no harm.

Just as medicine involves surgery and powerful drugs, fixing legacy software may involve significant changes. The principle is to perform those changes in a way that creates a smooth migration with backwards compatibility, careful handling of edge cases, rollback plans, and meticulous behavioral validation between the original system state and the state after refactor. This process should include the concept of running the revised software in parallel with the original software, exercising both with mutation testing, and comparing results to detect behavioral drift caused by the changes. All behavioral drift isn't bad, but all drift needs to be explained and approved by the user.

The first step of this process is gathering information about the legacy codebase and structuring it in a format that allows agents to more easily see patterns related to code quality. Our goal is to develop a process capable of handling a codebase that is too large to load into a single context window. It should handle large spaghetti code bases that may contain errors or incomplete references. Information gathering should produce a format that can be indexed and divided into multiple files if the size of the codebase warrants that. Gathering information on the legacy system should also gather information from git commit history. We should identify hotspots of brittle code that cause problems when changed or are changed frequently. These are both targets for improvement and areas to exercise caution not to break the existing system. We should also look for git history patterns of repeated fluctuation between states, code that has been repeatedly expanded or patched without a full rewrite, and trends that indicate recurring pain points.

The second step of this process is hypothesis testing and behavioral validation. Before we propose changes to the code, we need to demonstrate that we understand the code. We should identify areas where we have low confidence in the behavior of the application, and confirm actual behavior through logging and experimentation. Any changes should be reverted afterwards and the results clearly documented.

## Phases

1. Analysis step
2. Planning step (epic generation?)
3. Remediation step (execute epic with sprint?)
4. Validation step (included in epic?)
5. Migration step (included in epic?) — must include monitoring and rollback plan. Must minimize risk of user impact by avoiding large cutover events.

