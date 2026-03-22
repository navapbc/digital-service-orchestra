---
id: dso-sq4k
status: closed
deps: []
links: []
created: 2026-03-17T18:33:47Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-12
---
# Research and investigation in pre-planning or brainstorm

Our goal is to shift investigation and research tasks into preplanning. We want the execution of the implementation on stories to be as autonomous as possible, which means answering open questions and clearly defining requirements before we start our first batch of agents. 
The preplanning skill should identify any area where research or investigation is needed. For example, researching best practices or expert advice that will be incorporated into later work in the epic. This includes but is not limited to prompt engineering tasks, feasibility questions, and clarifying requirements. Look for gaps in our understanding at the story level.
If areas are identified that require additional research or investigation, the preplanning skill should launch one or more sub-agents in parallel to research and investigate. These sub-agents should be advised to use websearch and webfetch if researching best practices, expert advice, or other questions where access to broader Internet resources will improve the quality of our output. 
Each sub-agent should be told the problem is is solving, gap in understanding it is closing, or question it is answering. The prompt should include a list of questions that the agent should answer, and directions to include the answers along with insights and clarifications in the agent's response.
The results of these investigation should be saved to a temporary file to safeguard against auto-compaction. They should be incorporated into the stories preplanning creates where appropriate to provide clarification, guidance, and context that will be useful in completing the story.  If the research and investigation results contain broader context that would be useful across multiple stories, the epic should be updated to include this context. 
This research and investigation should happen before stories are created. It should be skipped if there are no open questions, areas in need of clarification, or areas requiring investigation or research for the epic. Our goal isn't to perform unnecessary research and investigation, but to have a clear picture of the work before we divide it into stories and have the user approve it.


## Notes

<!-- note-id: y88ll34z -->
<!-- timestamp: 2026-03-22T22:54:34Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Superseded by dso-d63r (Planning Intelligence — Research & Scenario Hardening)
