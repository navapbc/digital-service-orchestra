# Example: Reconciliation + Story Creation

Worked example showing how `/dso:preplanning` reconciles existing children against an epic's vision, then produces vertical-slice stories with Foundation/Enhancement splitting and consideration flagging from the Risk & Scope Scan.

**Epic**: "Implement document classification pipeline"
**Epic Criterion**: "Users can upload a document and see its classification"

**Existing Child**: "Add database schema for documents" (status: pending)

## Reconciliation

- **Reuse?** No — this is a horizontal layer, not a vertical slice
- **Modify?** No — conflicts with vertical slicing approach
- **Delete?** Yes — will be absorbed into vertical story slices

## Risk & Scope Scan

- [Testing] New LLM classification interaction — ensure mock-compatible interface
- [Performance] Documents may be large (100+ pages) — consider processing timeouts
- [Accessibility] Upload and results pages are new UI — WCAG 2.1 AA required

## New Stories (vertical slices)

**Story 1** (Foundation): "As a user, I can upload a document and see its classification"
- **Scope**: Upload flow, classification display, basic document types (PDF/Word)
- **Done Definitions**:
  - When complete, a user can upload a PDF or Word document and see its classified type within 30 seconds ← Satisfies: "Users can upload a document and see its classification"
  - When complete, the classification result persists and is visible when the user returns ← Satisfies: "Classification results are preserved"
- **Considerations**: [Testing] Mock-compatible LLM interface; [Performance] Processing timeout for large files

**Story 2** (Enhancement of Story 1): "As a user, I can see detailed classification confidence and sub-categories"
- **Scope**: Confidence scores, sub-category breakdown, classification explanation
- **Done Definitions**:
  - When complete, a user can see a confidence percentage and sub-categories for each classification ← Satisfies: "Users can understand why a document was classified a certain way"
- **Depends on**: Story 1
