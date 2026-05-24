#!/usr/bin/env bash
# telemetry-lib.sh — shared helpers for the telemetry AWS setup scripts.
#
# Sourced by aws-setup-bucket.sh and aws-setup-lambda.sh so a single fix to the
# atomic config write path propagates to both. Callers must define _CONFIG_FILE
# before sourcing. CONFIG_WRITE_LOG (optional) accumulates "WROTE <key>" lines
# for tests asserting on write ordering — no-op when unset or set to /dev/null.

# ── write_config_key: atomic temp+rename; preserves all other keys ────────────
write_config_key() {
    local key="$1" value="$2"
    local conf_file="$_CONFIG_FILE"
    local tmp_file
    tmp_file="$(mktemp "${conf_file}.XXXXXX")"

    if [[ -f "$conf_file" ]]; then
        if grep -q "^${key}=" "$conf_file" 2>/dev/null; then
            # Replace existing line, preserve all others
            grep -v "^${key}=" "$conf_file" > "$tmp_file" || true
        else
            # Copy existing content
            cp "$conf_file" "$tmp_file"
        fi
    fi

    # Append the key=value line
    echo "${key}=${value}" >> "$tmp_file"

    # Atomic rename
    mv "$tmp_file" "$conf_file"

    # Optional: log the write for ordering assertions (CONFIG_WRITE_LOG env override)
    if [[ -n "${CONFIG_WRITE_LOG:-}" ]] && [[ "${CONFIG_WRITE_LOG}" != "/dev/null" ]]; then
        echo "WROTE ${key}" >> "${CONFIG_WRITE_LOG}"
    fi
}
