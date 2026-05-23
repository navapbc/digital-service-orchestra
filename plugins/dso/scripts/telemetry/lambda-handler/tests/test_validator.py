from validator import validate_event

BASE = {
    "event_id": "e1", "timestamp": "2024-01-01T00:00:00Z", "client_id": "c1",
    "session_id": "s1", "epic_id": "ep1", "story_id": "st1",
    "reviewer_id": "r1", "verdict": "PASS", "score": 5,
}


def test_valid_minimal_event_passes():
    ok, err = validate_event(BASE)
    assert ok and err is None


def test_missing_required_field_fails():
    payload = {k: v for k, v in BASE.items() if k != "event_id"}
    ok, err = validate_event(payload)
    assert not ok and "event_id" in err


def test_wrong_type_fails():
    payload = {**BASE, "score": "five"}
    ok, err = validate_event(payload)
    assert not ok and "score" in err


def test_invalid_enum_fails():
    payload = {**BASE, "verdict": "MAYBE"}
    ok, err = validate_event(payload)
    assert not ok and "verdict" in err


def test_optional_field_present_with_correct_type_passes():
    payload = {**BASE, "cited_excerpt": "some text"}
    ok, err = validate_event(payload)
    assert ok and err is None
