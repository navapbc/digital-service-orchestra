---
id: w21-dixy
status: closed
deps: [w21-soe9]
links: []
created: 2026-03-22T03:07:39Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2r0x
---
# Implement detect_status_flap() and integrate flap halt into process_outbound()

## Description

Implement flap detection in `plugins/dso/scripts/bridge-outbound.py` to halt STATUS pushes for tickets that oscillate between statuses more than N times within a configurable window.

**TDD requirement:** Tests in w21-soe9 must be RED before starting. Run `python3 -m pytest tests/scripts/test_bridge_outbound.py -k 'flap' --tb=line -q` and confirm failures. Then implement until all flap tests pass GREEN.

**Implementation steps:**

1. Add `detect_status_flap(ticket_dir: Path, *, flap_threshold: int = 3, window_seconds: int = 3600) -> bool` to bridge-outbound.py:
   - Glob all `*-STATUS.json` and `*-BRIDGE_ALERT.json` files in ticket_dir
   - Parse timestamps; filter to those within `window_seconds` of now
   - Extract status values from the STATUS event files (read `data.status` or `status` field)
   - Count direction reversals: each time the status returns to a previous value, increment flap count
   - Return True if flap_count >= flap_threshold

2. Integrate into `process_outbound()` STATUS event handling:
   - Before pushing STATUS to Jira, call `detect_status_flap(ticket_dir, flap_threshold=config_threshold)`
   - If flap detected: call `write_bridge_alert(ticket_id, reason="STATUS flap detected: N oscillations within window", ...)` and skip `acli_client.update_issue()`
   - Log the flap detection (use `logging.warning`)

3. Pass `flap_threshold` and `flap_window_seconds` through the `process_outbound()` signature (with defaults: threshold=3, window=3600).

**Key constraint:** Flap detection reads STATUS events written by BOTH outbound (local developer actions) and inbound bridge (bridge_env_id-authored STATUS events), so bidirectional oscillation is detected. Do not filter by env_id when reading STATUS event history.

**Files to modify:** plugins/dso/scripts/bridge-outbound.py

## Acceptance Criteria

- [ ] `detect_status_flap(ticket_dir)` function exists in bridge-outbound.py
  Verify: python3 -c "import importlib.util; spec=importlib.util.spec_from_file_location('b','/$(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); assert hasattr(m,'detect_status_flap')"
- [ ] All 6 flap detection tests pass (GREEN)
  Verify: python3 -m pytest tests/scripts/test_bridge_outbound.py -k 'flap' --tb=short -q 2>&1 | grep -q 'passed'
- [ ] All pre-existing bridge-outbound tests still pass
  Verify: python3 -m pytest tests/scripts/test_bridge_outbound.py --tb=short -q 2>&1 | grep -q 'passed'
- [ ] BRIDGE_ALERT event is written when flap threshold is exceeded
  Verify: python3 -m pytest tests/scripts/test_bridge_outbound.py::test_process_outbound_emits_bridge_alert_on_flap --tb=short -q 2>&1 | grep -q 'passed'
- [ ] acli_client.update_issue is NOT called for flapping tickets
  Verify: python3 -m pytest tests/scripts/test_bridge_outbound.py::test_process_outbound_halts_status_push_for_flapping_ticket --tb=short -q 2>&1 | grep -q 'passed'
- [ ] write_bridge_alert() is implemented in bridge-outbound.py (NOT imported from bridge-inbound) to write BRIDGE_ALERT event files when flap is detected
  Verify: python3 -c "import importlib.util; spec=importlib.util.spec_from_file_location('b','$(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); assert hasattr(m,'write_bridge_alert') or hasattr(m,'_write_bridge_alert')"
- [ ] ruff format --check and ruff check pass
  Verify: ruff format --check plugins/dso/scripts/bridge-outbound.py && ruff check plugins/dso/scripts/bridge-outbound.py

## Notes

**2026-03-22T03:20:48Z**

CHECKPOINT: Read tests and source. 6 flap tests in TestFlapDetection/TestFlapIntegration classes (tests 6-11). Need to implement detect_status_flap(), write_bridge_alert(), and integrate into process_outbound() STATUS handling.

**2026-03-22T03:23:00Z**

CHECKPOINT: All 11 tests pass (5 pre-existing + 6 flap). Implemented detect_status_flap(), write_bridge_alert(), and integrated flap halt into process_outbound() STATUS handling in bridge-outbound.py.

**2026-03-22T03:25:28Z**

CHECKPOINT 6/6: Done ✓ — detect_status_flap() + flap halt in process_outbound. 11/11 tests pass. BLOCKED: cannot commit due to RED test gate bug w21-4w0c.
