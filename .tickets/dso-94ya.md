---
id: dso-94ya
status: open
deps: []
links: []
created: 2026-03-17T18:33:58Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-18
---
# Add a preflight check to sprint that validates current project state

Other epics or bugs may change the project between epic creation and execution. Before we decide whether to call preplanning, we should use a sub-agent to validate that the epic and any children are consistent with the current project state. This call should only happen if the epic was created more than an hour ago. This agent should be mindful of dependency chains. If task A creates a class and task B references that class (which doesn't exist in the current project), then these tasks are still still consistent with the current project state because Task A is a dependency of Task B. We are looking for cases where code has been moved, refactored, or deleted making the epic or story contain stale information that needs to be updated. This agent may review the commit history between ticket creation and now to identify changes to the project since an epic or story was created. When an epic or story doesn't match the project state, a second sub-agent should be dispatched to validate the findings and update the tickets if needed to reflect the changes to the project since the epic or story was created. Splitting the update into a separate agent provides independent validation that prevents hallucinations.

