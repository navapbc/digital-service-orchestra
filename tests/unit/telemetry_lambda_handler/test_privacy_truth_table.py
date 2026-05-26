from privacy import apply_server_side_privacy

BASE = {"event_id": "e1", "client_id": "other", "cited_excerpt": "secret"}


def test_dso_self_preserves_excerpt():
    result = apply_server_side_privacy({**BASE, "client_id": "dso-self"})
    assert result["cited_excerpt"] == "secret"


def test_emit_excerpts_true_override_preserves():
    result = apply_server_side_privacy({**BASE, "emit_excerpts": True})
    assert result["cited_excerpt"] == "secret"


def test_non_dso_self_strips_excerpt_to_null():
    result = apply_server_side_privacy(BASE)
    assert result["cited_excerpt"] is None


def test_emit_excerpts_false_does_not_override():
    result = apply_server_side_privacy({**BASE, "emit_excerpts": False})
    assert result["cited_excerpt"] is None


def test_emit_excerpts_none_does_not_override():
    result = apply_server_side_privacy({**BASE, "emit_excerpts": None})
    assert result["cited_excerpt"] is None


def test_emit_excerpts_int_1_does_not_override():
    # int 1 is truthy but not True by identity — must NOT preserve
    result = apply_server_side_privacy({**BASE, "emit_excerpts": 1})
    assert result["cited_excerpt"] is None


def test_emit_excerpts_string_true_does_not_override():
    result = apply_server_side_privacy({**BASE, "emit_excerpts": "true"})
    assert result["cited_excerpt"] is None


def test_does_not_mutate_input():
    original = {**BASE}
    apply_server_side_privacy(original)
    assert original["cited_excerpt"] == "secret"
