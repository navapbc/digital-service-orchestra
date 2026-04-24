#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../..}"
# parse-template-registry.sh
# Parse the template registry YAML file and output tab-separated rows.
#
# Usage: parse-template-registry.sh [registry-file]
#
# Default registry file: ${CLAUDE_PLUGIN_ROOT}/config/template-registry.yaml
#
# Output format (one line per valid template, tab-separated):
#   name\trepo_url\tinstall_method\tframework_type\tdata_flags
#   data_flags: required_data_flags list as comma-joined string (empty string if [])
#
# Exit codes:
#   0 — success, missing file, or malformed YAML
#   1 — validation failure (missing required field, invalid install_method)

set -uo pipefail

# Resolve registry file path
REPO_ROOT="$(git rev-parse --show-toplevel)"
DEFAULT_REGISTRY="${_PLUGIN_ROOT}/config/template-registry.yaml"
REGISTRY_FILE="${1:-$DEFAULT_REGISTRY}"

# Missing file: exit 0 with warning to stderr
if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "WARNING: registry file not found: $REGISTRY_FILE" >&2
    exit 0
fi

python3 - "$REGISTRY_FILE" <<'PYEOF'
import sys

REGISTRY_FILE = sys.argv[1]

REQUIRED_FIELDS = ["name", "repo_url", "install_method", "framework_type"]
ALLOWED_INSTALL_METHODS = {"nava-platform", "git-clone"}
KNOWN_KEYS = {"name", "repo_url", "description", "install_method", "framework_type", "required_data_flags"}


def load_registry(filepath):
    """Load and parse the registry YAML file. Returns list of template dicts.

    Uses yaml.safe_load (PyYAML) when available for robust YAML parsing.
    Falls back to a minimal regex parser for environments without PyYAML.
    """
    try:
        import yaml
        with open(filepath) as f:
            data = yaml.safe_load(f)
        if not isinstance(data, dict) or 'templates' not in data:
            return []
        templates = data.get('templates', [])
        if not isinstance(templates, list):
            return []
        # Normalize: yaml.safe_load returns native Python types, convert
        # required_data_flags to list of strings for consistent handling
        for tmpl in templates:
            if not isinstance(tmpl, dict):
                continue
            flags = tmpl.get('required_data_flags', [])
            if flags is None:
                tmpl['required_data_flags'] = []
            elif not isinstance(flags, list):
                tmpl['required_data_flags'] = [str(flags)]
        return [t for t in templates if isinstance(t, dict)]
    except ImportError:
        pass  # Fall through to regex parser
    except Exception as e:
        print(f"WARNING: malformed YAML in {filepath}: {e}", file=sys.stderr)
        sys.exit(0)

    # Fallback: minimal regex parser for environments without PyYAML
    import re
    templates = []
    current = None
    in_templates = False
    in_flags = False

    with open(filepath) as f:
        lines = f.readlines()

    for line in lines:
        stripped = line.rstrip()
        if not stripped or stripped.lstrip().startswith('#'):
            continue

        if re.match(r'^templates\s*:', stripped):
            in_templates = True
            continue

        if not in_templates:
            continue

        # Handle block list items under required_data_flags BEFORE template-item detection
        # (both match ^\s+-\s+, so in_flags must be checked first)
        if in_flags and re.match(r'^\s+-\s+', stripped):
            m_item = re.match(r'^\s+-\s+(.*)', stripped)
            if m_item and current is not None:
                item = m_item.group(1).strip().strip('"').strip("'")
                if isinstance(current.get('required_data_flags'), list):
                    current['required_data_flags'].append(item)
            continue

        if re.match(r'^\s+-\s+', stripped):
            if current is not None:
                templates.append(current)
            current = {}
            in_flags = False
            m = re.match(r'^\s+-\s+([^:]+?):\s*(.*)', stripped)
            if m:
                key = m.group(1).strip()
                value = m.group(2).strip()
                if value:
                    if (value.startswith('"') and value.endswith('"')) or \
                       (value.startswith("'") and value.endswith("'")):
                        value = value[1:-1]
                    current[key] = value
                else:
                    current[key] = None
            continue

        if current is None:
            continue

        m_flags_inline = re.match(r'^\s+required_data_flags\s*:\s*\[(.*)\]', stripped)
        if m_flags_inline:
            content = m_flags_inline.group(1).strip()
            if content:
                flags = [f.strip().strip('"').strip("'") for f in content.split(',')]
                flags = [f for f in flags if f]
            else:
                flags = []
            current['required_data_flags'] = flags
            in_flags = False
            continue

        m_flags_block = re.match(r'^\s+required_data_flags\s*:\s*$', stripped)
        if m_flags_block:
            current['required_data_flags'] = []
            in_flags = True
            continue

        m = re.match(r'^\s+([^:]+?):\s*(.*)', stripped)
        if m:
            in_flags = False
            key = m.group(1).strip()
            value = m.group(2).strip()
            if value:
                if (value.startswith('"') and value.endswith('"')) or \
                   (value.startswith("'") and value.endswith("'")):
                    value = value[1:-1]
                current[key] = value
            else:
                current[key] = None

    if current is not None:
        templates.append(current)

    return templates


try:
    templates = load_registry(REGISTRY_FILE)
except Exception as e:
    print(f"WARNING: failed to parse registry {REGISTRY_FILE}: {e}", file=sys.stderr)
    sys.exit(0)

exit_code = 0
output_rows = []

for tmpl in templates:
    name_for_err = tmpl.get('name', '<unknown>')

    # Detect unknown keys — warn to stderr
    for k in tmpl:
        if k not in KNOWN_KEYS:
            print(f"WARNING: unknown key '{k}' in template '{name_for_err}'", file=sys.stderr)

    # Validate required fields
    missing = [f for f in REQUIRED_FIELDS if not tmpl.get(f)]
    if missing:
        print(f"ERROR: missing required field '{missing[0]}' in template '{name_for_err}'", file=sys.stderr)
        exit_code = 1
        continue

    # Validate install_method allowlist
    install_method = tmpl['install_method']
    if install_method not in ALLOWED_INSTALL_METHODS:
        print(f"ERROR: invalid install_method '{install_method}' in template '{name_for_err}' "
              f"(allowed: {', '.join(sorted(ALLOWED_INSTALL_METHODS))})", file=sys.stderr)
        exit_code = 1
        continue

    # Serialize data_flags
    flags = tmpl.get('required_data_flags', [])
    if isinstance(flags, list):
        data_flags = ','.join(flags)
    else:
        data_flags = str(flags) if flags else ''

    output_rows.append(f"{tmpl['name']}\t{tmpl['repo_url']}\t{tmpl['install_method']}\t{tmpl['framework_type']}\t{data_flags}")

for row in output_rows:
    print(row)

sys.exit(exit_code)
PYEOF
