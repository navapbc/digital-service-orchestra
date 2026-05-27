# Visual Evaluator SC-1 Coverage Traceability

Maps each SC-1 sub-criterion to its schema field, agent prompt anchor, and regression test.

| SC-1 Sub-criterion | Schema Field | Agent Anchor | Test |
|---|---|---|---|
| Agent emits bbox_confidence (anchored\|inferred) for each finding | `findings[].bbox_confidence` (enum: anchored, inferred) | §DOM Cross-Check Rules: "Only emit anchored when you can associate the region with a named DOM container" | `tests/plugin/test_visual_evaluator_agent.py::test_schema_bbox_confidence_enum` |
| Agent emits dom_xpath per finding | `findings[].dom_xpath` (string or null) | §Output Schema: dom_xpath defined as XPath selector or null | `tests/plugin/test_visual_evaluator_agent.py::test_schema_has_required_top_level_fields` |
| dom_xpath_visually_consistent reflects bbox-to-DOM agreement | `findings[].dom_xpath_visually_consistent` (boolean) | §DOM Cross-Check Rules: "VLM judgment (NOT a live DOM query). Set true when visible region corresponds to XPath element" | `tests/plugin/test_visual_evaluator_domcheck.py::test_mismatch_fixture_inconsistent`, `::test_consistent_fixture_consistent` |
| attribution_class classifies defect origin | `attribution_class` (enum: implementation_drift, design_flaw, mixed, uncertain) | §Attribution Decision Tree: 4 numbered rules with short-circuit semantics | `tests/plugin/test_visual_evaluator_agent_structure.py::test_attribution_decision_tree` |
| attribution_confidence indicates certainty | `attribution_confidence` (enum: high, medium, low) | §Output Schema: attribution_confidence defined | `tests/plugin/test_visual_evaluator_agent.py::test_schema_has_required_top_level_fields` |
| scores has 5 integer 1-5 dimensions | `scores.{whitespace_balance, element_density, visual_hierarchy_legibility, alignment_grid_adherence, intent_match}` (integer, min 1, max 5) | §Scoring Rubric: 25-row anchor table (5 dims × 5 scores) | `tests/plugin/test_visual_evaluator_agent.py::test_schema_scores_five_integer_dimensions`, `tests/plugin/test_visual_evaluator_agent_structure.py::test_25_rubric_anchors` |

## Coverage Summary

- **6 of 6 SC-1 sub-criteria covered** ✓
- Schema source: `${CLAUDE_PLUGIN_ROOT}/docs/visual-evaluator-schema.json`
- Agent source: `${CLAUDE_PLUGIN_ROOT}/agents/visual-evaluator.md`
- Params source: `${CLAUDE_PLUGIN_ROOT}/config/visual-evaluator-params.yaml`
- Tests: `tests/plugin/test_visual_evaluator_agent.py`, `tests/plugin/test_visual_evaluator_agent_structure.py`, `tests/plugin/test_visual_evaluator_domcheck.py`
