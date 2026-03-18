---
id: dso-v558
status: open
deps: []
links: []
created: 2026-03-17T18:33:33Z
type: epic
priority: 3
assignee: Joe Oakhart
jira_key: DIG-5
---
# Figma integration for human design input

Designers may want the ability to adjust designs before they are implemented. When the design wireframe skill is used to create plans for a user interface, the user should be asked whether they would like to include a human design review for this feature. There should be two branching paths depending on the user's answer. If a human design review is requested, proposed designs should be saved to Figma using the Figma MCP, and the identifier for those designs should be saved with the corresponding feature. The epic should not proceed to implementation plan or execution until the user confirms that the human design review has been completed. Once the human design has been completed, revised designs should be retrieved using Figma MCP and converted into the 3-part design manifest format we use and saved, the the epic should be unblocked. If human design review is not requested, designs should be saved using our 3-part design format and the epic should not be blocked.

