#!/usr/bin/env bash
# acli-version-resolver.sh
#
# Spike PoC: resolves the current ACLI (Atlassian CLI) version and computes
# its SHA-256 checksum for use in reproducible installs (e.g. Homebrew formulae).
#
# ── Version string format ─────────────────────────────────────────────────────
# ACLI reports its version via: acli --version
# Output format:  acli version <semver>[-tag]
# Example:        acli version 1.3.5-stable
# The version token is everything after "acli version " (space-trimmed).
# The -stable suffix (or similar channel suffix) is preserved verbatim.
#
# ── Download URL patterns ─────────────────────────────────────────────────────
# Latest binary (platform-detect bootstrap):
#   https://acli.atlassian.com/{platform}/latest/acli_{platform}_{arch}
#   Example: https://acli.atlassian.com/darwin/latest/acli_darwin_arm64
#
# Versioned tarball (used for SHA-256 pinning):
#   https://acli.atlassian.com/{platform}/{version}/acli_{version}_{platform}_{arch}.tar.gz
#   Example: https://acli.atlassian.com/darwin/1.3.5-stable/acli_1.3.5-stable_darwin_arm64.tar.gz
#
# ── Supported platform / arch values ─────────────────────────────────────────
# Platform: darwin, linux  (auto-detected from `uname -s`)
# Arch:     amd64, arm64  (auto-detected from `uname -m`; x86_64 → amd64, arm64/aarch64 → arm64)
#
# ── Output format ─────────────────────────────────────────────────────────────
# On success two lines are printed to stdout:
#   ACLI_VERSION=<version>
#   ACLI_SHA256=<hex-hash>
#
# ── Manually validated versions ───────────────────────────────────────────────
# Validated: v1.3.4-stable SHA256=<run manually to obtain>
# Validated: v1.3.5-stable SHA256=<run manually to obtain>
#
# ── Usage ─────────────────────────────────────────────────────────────────────
# acli-version-resolver.sh [--platform darwin|linux] [--arch amd64|arm64]
#
# Exit 0 on success; non-zero with a descriptive error message on stderr on failure.

set -uo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
PLATFORM=""
ARCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Platform / arch detection ─────────────────────────────────────────────────
if [[ -z "$PLATFORM" ]]; then
    raw_os="$(uname -s 2>/dev/null || true)"
    case "${raw_os,,}" in
        darwin) PLATFORM="darwin" ;;
        linux)  PLATFORM="linux"  ;;
        *)
            echo "ERROR: unsupported OS '${raw_os}'; pass --platform darwin|linux" >&2
            exit 1
            ;;
    esac
fi

if [[ -z "$ARCH" ]]; then
    raw_arch="$(uname -m 2>/dev/null || true)"
    case "$raw_arch" in
        x86_64)         ARCH="amd64" ;;
        arm64|aarch64)  ARCH="arm64" ;;
        *)
            echo "ERROR: unsupported arch '${raw_arch}'; pass --arch amd64|arm64" >&2
            exit 1
            ;;
    esac
fi

# ── Locate acli (use PATH if available, otherwise download latest bootstrap) ──
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

if command -v acli &>/dev/null; then
    ACLI_BIN="$(command -v acli)"
else
    # Download the latest acli binary for bootstrap
    LATEST_URL="https://acli.atlassian.com/${PLATFORM}/latest/acli_${PLATFORM}_${ARCH}"
    ACLI_BIN="$TMPDIR_WORK/acli"
    if ! curl -fsSL -o "$ACLI_BIN" "$LATEST_URL"; then
        echo "ERROR: failed to download acli from ${LATEST_URL}" >&2
        exit 1
    fi
    chmod +x "$ACLI_BIN"
fi

# ── Run acli --version and parse the version string ──────────────────────────
version_output="$("$ACLI_BIN" --version 2>&1 || true)"

# Expected format: "acli version <version>"
# Extract the version token (third word)
version_token=""
if [[ "$version_output" =~ ^acli[[:space:]]+version[[:space:]]+([^[:space:]]+) ]]; then
    version_token="${BASH_REMATCH[1]}"
fi

if [[ -z "$version_token" ]]; then
    echo "ERROR: could not parse version from acli output: ${version_output}" >&2
    exit 1
fi

# ── Construct the versioned tarball URL ───────────────────────────────────────
TARBALL_URL="https://acli.atlassian.com/${PLATFORM}/${version_token}/acli_${version_token}_${PLATFORM}_${ARCH}.tar.gz"

# ── Download the versioned tarball ───────────────────────────────────────────
TARBALL_PATH="$TMPDIR_WORK/acli_${version_token}_${PLATFORM}_${ARCH}.tar.gz"
if ! curl -fsSL -o "$TARBALL_PATH" "$TARBALL_URL"; then
    echo "ERROR: failed to download versioned tarball from ${TARBALL_URL}" >&2
    exit 1
fi

# ── Compute SHA-256 ───────────────────────────────────────────────────────────
sha256=""
if command -v sha256sum &>/dev/null; then
    sha256="$(sha256sum "$TARBALL_PATH" | awk '{print $1}')"
elif command -v shasum &>/dev/null; then
    sha256="$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')"
else
    echo "ERROR: no sha256sum or shasum found in PATH" >&2
    exit 1
fi

# ── Output ────────────────────────────────────────────────────────────────────
echo "ACLI_VERSION=${version_token}"
echo "ACLI_URL=${TARBALL_URL}"
echo "ACLI_SHA256=${sha256}"
