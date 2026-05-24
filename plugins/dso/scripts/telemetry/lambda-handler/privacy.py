def apply_server_side_privacy(event: dict) -> dict:
    result = dict(event)
    if event.get("client_id") == "dso-self":
        return result                         # dd-4: preserve
    if event.get("emit_excerpts") is True:    # boolean identity — not truthiness
        return result                         # dd-5: preserve
    result["cited_excerpt"] = None            # dd-3: strip
    return result
