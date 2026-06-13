---
id: scaffold-integration-harness
title: Scaffold an Integration Test Harness for an Architectural Change
category: generation
operation: For an architectural change, produce an end-to-end test scaffold or integration-harness spec that defines the verification strategy, including an explicit self-use / bootstrap-gap analysis.
when_to_use: >
  When a change alters system architecture, infrastructure, tooling, or a
  platform boundary and needs an integration-level verification strategy defined
  before the work is decomposed. Use to force the end-to-end test surface to be
  designed up front and to surface bootstrap gaps — cases where the process
  building the change cannot run on the architecture the change delivers.
inputs:
  - name: change
    type: object
    required: true
    description: The architectural change — its description, goals/success criteria, and the boundaries it touches.
  - name: output_target
    type: string
    required: false
    description: Where to write the scaffold/spec (a test file path or a harness-spec doc path).
outputs:
  format: structured-artifact
  schema: >
    A non-empty end-to-end test scaffold or integration-harness spec describing
    the verification strategy, and a required Self-Use Compatibility section that
    names any bootstrap gap or affirms its absence.
tools:
  required: []
  optional:
    - read-only inspection of the affected boundaries
    - writing the scaffold/spec to the output target
  prohibited:
    - modifying existing source files
    - producing an empty scaffold (a skeleton structure is the minimum)
    - omitting the Self-Use Compatibility analysis
determinism: generative
model_hint: sonnet
source: Architectural probe producing an integration-test scaffold/harness spec with a self-use/bootstrap-gap section.
---

# Scaffold an Integration Test Harness for an Architectural Change

You produce, for an architectural change, at least one of: an **end-to-end test
scaffold** (a runnable skeleton that exercises the change across its boundaries)
or an **integration-harness spec** (the schema/strategy for verifying the
integration). The artifact defines *how the change will be proven to work
end-to-end*, before it is decomposed into tasks.

## Procedure

1. Read the change, its goals, and the boundaries it touches.
2. Design the end-to-end verification: the entry point, the path through the
   affected boundaries, the observable outcome that proves success, and the
   fixtures/harness needed to drive it.
3. Write a non-empty scaffold or spec (a skeleton structure is the minimum) to the
   output target.
4. Write the **Self-Use Compatibility** analysis (required).

## Self-Use Compatibility (required section)

Answer explicitly:

- Can the process that builds this change run on the architecture the change
  delivers?
- If the change introduces infrastructure, tooling, or platform changes: can the
  build process use those changes as it builds them, or does a **bootstrap gap**
  exist?
- If a bootstrap gap exists, name it concretely (e.g. "the runner upgrade this
  change delivers cannot be used during the work that installs it").
- If none exists, say so affirmatively (e.g. "execution requires only existing
  infrastructure; no bootstrap gap").

## Output contract

Emit (and write to the output target) a non-empty artifact containing the
end-to-end verification strategy and a `## Self-Use Compatibility` section per
above.

## Constraints

- Do exactly one thing: produce the integration verification scaffold/spec. Do
  NOT implement the change itself or modify existing source files.
- The artifact must be non-empty and MUST include the Self-Use Compatibility
  section.
