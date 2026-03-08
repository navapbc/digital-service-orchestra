#!/usr/bin/env bash
# lockpick-workflow/scripts/worktree-port.sh
#
# Compute deterministic DB_PORT and APP_PORT for a given worktree name.
#
# This is the single source of truth for worktree port allocation.
# All callers (Makefile, run-changed-tests.sh, conftest.py) delegate here.
#
# Base ports are read from workflow-config.yaml via read-config.sh:
#   database.base_port           (default: 5432)
#   infrastructure.app_base_port (default: 3000)
#
# Usage:
#   worktree-port.sh <worktree-name>        -> DB_PORT=N\nAPP_PORT=N (sourceable)
#   worktree-port.sh <worktree-name> db     -> just the DB port number
#   worktree-port.sh <worktree-name> app    -> just the APP port number

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKTREE_NAME="$1"
PORT_TYPE="${2:-}"

# Read base ports from config, falling back to defaults on any failure
DB_BASE_PORT=$(bash "$SCRIPT_DIR/read-config.sh" database.base_port 2>/dev/null || true)
DB_BASE_PORT="${DB_BASE_PORT:-5432}"

APP_BASE_PORT=$(bash "$SCRIPT_DIR/read-config.sh" infrastructure.app_base_port 2>/dev/null || true)
APP_BASE_PORT="${APP_BASE_PORT:-3000}"

HASH_NUM=$(printf '%s' "$WORKTREE_NAME" | cksum | cut -d' ' -f1)
PORT_OFFSET=$(( HASH_NUM % 100 + 1 ))
DB_PORT=$(( DB_BASE_PORT + PORT_OFFSET ))
APP_PORT=$(( APP_BASE_PORT + PORT_OFFSET ))

case "$PORT_TYPE" in
  db)  echo "$DB_PORT" ;;
  app) echo "$APP_PORT" ;;
  *)   echo "DB_PORT=$DB_PORT"; echo "APP_PORT=$APP_PORT" ;;
esac
