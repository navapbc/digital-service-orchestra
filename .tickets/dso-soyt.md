---
id: dso-soyt
status: open
deps: []
links: []
created: 2026-03-17T18:34:02Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-20
---
# Incorporate Semantic Search & MCP (Model Context Protocol)

Fowler has recently discussed Context Engineering, specifically using MCP Servers and tools like Claude Code hooks. By using a deterministic tool to "fetch" context (like a call graph or symbols), you provide the LLM with the "ground truth" of the codebase.  
Deterministic Fetching: Instead of letting the LLM "remember" how a class is structured, use a tool to pipe the exact AST structure into the prompt.
The Guardrail: This limits the LLM's "creative" interpretation of your internal APIs.

