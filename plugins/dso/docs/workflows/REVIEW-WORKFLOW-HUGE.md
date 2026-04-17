# Large-Refactor Review Workflow

> **Status**: Scaffold — full implementation delivered by story `efe7-7f1d`.
> This file is referenced by REVIEW-WORKFLOW.md Step 2b when `review.huge_diff_file_threshold` is exceeded.

## Purpose

This workflow handles code review for large commits (file count ≥ `review.huge_diff_file_threshold`).
Unlike the standard review path, large refactors are routed to specialised agents that check
pattern conformance and inspect anomalous files.

## Entry Condition

Called from REVIEW-WORKFLOW.md Step 2b when `review-huge-diff-check.sh` exits 2.

## Steps

_Full step-by-step workflow to be defined in story `efe7-7f1d`._

## Exit

Return to REVIEW-WORKFLOW.md caller after completing this workflow.
