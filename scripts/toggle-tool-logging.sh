#!/usr/bin/env bash
set -euo pipefail
# scripts/toggle-tool-logging.sh
# Toggle JSONL tool-use logging on or off.
#
# Usage:
#   toggle-tool-logging.sh          — toggle (enable if off, disable if on)
#   toggle-tool-logging.sh enable   — enable logging
#   toggle-tool-logging.sh disable  — disable logging
#   toggle-tool-logging.sh status   — show current status
#
# Flag file: ~/.claude/tool-logging-enabled
# Log files: ~/.claude/logs/tool-use-YYYY-MM-DD.jsonl
#
# Performance: When logging is disabled (flag absent), the dispatchers
# (pre-all.sh, post-all.sh) skip the tool-logging subprocess entirely,
# avoiding ~10-50ms of overhead per tool call. The flag check is also
# present inside tool-logging.sh as defense-in-depth.

FLAG_FILE="$HOME/.claude/tool-logging-enabled"
LOG_DIR="$HOME/.claude/logs"

is_enabled() {
    test -f "$FLAG_FILE"
}

show_status() {
    if is_enabled; then
        echo "Tool-use logging: ENABLED"
        echo "Flag file: $FLAG_FILE"
        if ls "$LOG_DIR"/tool-use-*.jsonl 2>/dev/null | head -1 | grep -q .; then
            echo "Log files:"
            ls -lh "$LOG_DIR"/tool-use-*.jsonl 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
        else
            echo "Log files: none yet (logs appear in $LOG_DIR/)"
        fi
    else
        echo "Tool-use logging: DISABLED"
        echo "Run '$(basename "$0") enable' or '$(basename "$0")' to enable."
    fi
}

ACTION="${1:-toggle}"

case "$ACTION" in
    enable)
        mkdir -p "$(dirname "$FLAG_FILE")"
        touch "$FLAG_FILE"
        echo "Tool-use logging ENABLED."
        echo "Logs will be written to: $LOG_DIR/tool-use-YYYY-MM-DD.jsonl"
        ;;
    disable)
        rm -f "$FLAG_FILE"
        echo "Tool-use logging DISABLED."
        ;;
    status)
        show_status
        ;;
    toggle)
        if is_enabled; then
            rm -f "$FLAG_FILE"
            echo "Tool-use logging DISABLED (was enabled)."
        else
            mkdir -p "$(dirname "$FLAG_FILE")"
            touch "$FLAG_FILE"
            echo "Tool-use logging ENABLED (was disabled)."
            echo "Logs will be written to: $LOG_DIR/tool-use-YYYY-MM-DD.jsonl"
        fi
        ;;
    *)
        echo "Usage: $(basename "$0") [enable|disable|status|toggle]"
        echo ""
        echo "  toggle   — enable if disabled, disable if enabled (default)"
        echo "  enable   — enable logging"
        echo "  disable  — disable logging"
        echo "  status   — show current status and log file info"
        exit 1
        ;;
esac
