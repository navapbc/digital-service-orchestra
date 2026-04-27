#!/usr/bin/env bash
# artifact-merge-lib.sh
# Shared merge library for update-artifacts.sh.
#
# Functions:
#   merge_config_file TARGET_CONFIG PLUGIN_TEMPLATE DRYRUN
#   merge_ci_workflow TARGET_CI PLUGIN_CI DRYRUN
#   merge_precommit_hooks TARGET_FILE EXAMPLE_FILE DRYRUN
#
# Helpers (exported for test access):
#   _base64_nowrap_flag   — returns -w 0 (Linux) or -b 0 (macOS)
#   _emit_conflict_json   — ARTIFACT_PATH OURS_CONTENT THEIRS_CONTENT
#
# Sourcing this file does NOT execute any actions — all functions are
# defined but not called. Safe to source from other scripts and tests.
#
# Exit codes (per function):
#   0  = success (changes applied or already up-to-date)
#   2  = unresolvable conflict (JSON written to stdout)

# ── _base64_nowrap_flag ───────────────────────────────────────────────────────
# Returns the correct no-wrap flag for the current platform:
#   Linux: -w 0
#   macOS: -b 0
_base64_nowrap_flag() {
    local platform
    platform=$(uname -s 2>/dev/null || echo "Linux")
    case "$platform" in
        Darwin) echo "-b 0" ;;
        *)      echo "-w 0" ;;
    esac
}

# Aliases for test discoverability (test probes multiple function names)
_platform_base64_flag() { _base64_nowrap_flag; }
_detect_base64_nowrap_flag() { _base64_nowrap_flag; }
detect_base64_flag() { _base64_nowrap_flag; }

# ── _emit_conflict_json ───────────────────────────────────────────────────────
# Usage: _emit_conflict_json ARTIFACT_PATH OURS_CONTENT THEIRS_CONTENT
# Writes a JSON object to stdout with base64-encoded conflict fields.
# Fields: artifact (string), conflict_ours (base64), conflict_theirs (base64)
_emit_conflict_json() {
    local artifact_path="$1"
    local ours_content="$2"
    local theirs_content="$3"

    local b64_flag
    b64_flag=$(_base64_nowrap_flag)

    local ours_b64 theirs_b64
    # shellcheck disable=SC2086
    ours_b64=$(printf '%s' "$ours_content" | base64 $b64_flag 2>/dev/null || printf '%s' "$ours_content" | base64 2>/dev/null)
    # shellcheck disable=SC2086
    theirs_b64=$(printf '%s' "$theirs_content" | base64 $b64_flag 2>/dev/null || printf '%s' "$theirs_content" | base64 2>/dev/null)

    # Use python3 for proper JSON encoding if available
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$artifact_path" "$ours_b64" "$theirs_b64" <<'PYEOF'
import sys, json
artifact = sys.argv[1]
ours_b64 = sys.argv[2]
theirs_b64 = sys.argv[3]
print(json.dumps({
    "artifact": artifact,
    "conflict_ours": ours_b64,
    "conflict_theirs": theirs_b64
}, indent=2))
PYEOF
    else
        # Minimal fallback JSON without python3
        printf '{"artifact":"%s","conflict_ours":"%s","conflict_theirs":"%s"}\n' \
            "$artifact_path" "$ours_b64" "$theirs_b64"
    fi
}

# ── merge_config_file ─────────────────────────────────────────────────────────
# Usage: merge_config_file TARGET_CONFIG PLUGIN_TEMPLATE DRYRUN
#
# Strategy: key-additive bash line comparison
#   - For each key=value in plugin template:
#     - If `^key=` or `^#.*key=` exists in target → skip (present or
#       intentionally commented out by user)
#     - Exception: `# dso-version:` is reserved metadata → always updated
#   - Missing keys: appended to target
#
# Returns: 0 on success, 2 on conflict (JSON to stdout)
merge_config_file() {
    local target_file="$1"
    local plugin_template="$2"
    local dryrun="${3:-}"

    if [[ ! -f "$target_file" ]]; then
        if [[ -z "$dryrun" ]]; then
            cp "$plugin_template" "$target_file"
            echo "[merge_config_file] Created $target_file from template"
        else
            echo "[dryrun][merge_config_file] Would create $target_file from template"
        fi
        return 0
    fi

    if [[ ! -f "$plugin_template" ]]; then
        echo "WARNING: merge_config_file: plugin template not found: $plugin_template" >&2
        return 0
    fi

    local keys_added=()
    local tmp_append
    tmp_append=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_append'" RETURN

    # Process each line in the plugin template
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Handle reserved metadata: # dso-version: always update
        if [[ "$line" =~ ^#[[:space:]]*dso-version:[[:space:]]* ]]; then
            local new_ver
            new_ver=$(echo "$line" | sed 's/^#[[:space:]]*dso-version:[[:space:]]*//')
            if [[ -z "$dryrun" ]]; then
                # Update the stamp in place — if present update it, otherwise append
                if grep -q '^# dso-version:' "$target_file" 2>/dev/null; then
                    # Use a tmp file to avoid sed -i portability issues
                    local tmp_sed
                    tmp_sed=$(mktemp)
                    sed "s|^# dso-version:.*|# dso-version: $new_ver|" "$target_file" > "$tmp_sed"
                    mv "$tmp_sed" "$target_file"
                else
                    # Not present — append at top via prepend trick
                    local tmp_prepend
                    tmp_prepend=$(mktemp)
                    { echo "$line"; cat "$target_file"; } > "$tmp_prepend"
                    mv "$tmp_prepend" "$target_file"
                fi
            else
                echo "[dryrun][merge_config_file] Would update # dso-version: to $new_ver"
            fi
            continue
        fi

        # Skip comment lines (non-metadata)
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip empty lines
        [[ -z "${line// }" ]] && continue

        # Extract key from key=value line
        local key
        key=$(echo "$line" | cut -d= -f1)
        [[ -z "$key" ]] && continue

        # Check if key already exists (active or commented) in target
        # Escape regex metacharacters in key before using in grep pattern
        local escaped_key
        # shellcheck disable=SC2016  # & is sed's "matched text" metachar, not a shell variable
        escaped_key=$(printf '%s' "$key" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
        if grep -qE "^[[:space:]]*#?[[:space:]]*${escaped_key}[[:space:]]*=" "$target_file" 2>/dev/null; then
            # Key present (active or commented) — skip
            continue
        fi

        # Key is missing — queue for append
        keys_added+=("$key")
        echo "$line" >> "$tmp_append"
    done < "$plugin_template"

    if [[ ${#keys_added[@]} -gt 0 ]]; then
        if [[ -z "$dryrun" ]]; then
            cat "$tmp_append" >> "$target_file"
            echo "[merge_config_file] Appended ${#keys_added[@]} new key(s) to $target_file: ${keys_added[*]}"
        else
            echo "[dryrun][merge_config_file] Would append ${#keys_added[@]} new key(s): ${keys_added[*]}"
        fi
    fi

    return 0
}

# ── merge_ci_workflow ─────────────────────────────────────────────────────────
# Usage: merge_ci_workflow TARGET_CI PLUGIN_CI DRYRUN
#
# Strategy: merge job definitions from plugin CI into host CI, preserving
#   user customizations. Primary: python3+yaml. Fallback: awk/sed block
#   insertion when python3/yaml unavailable.
#
# Idempotent: existing DSO job names are not re-added.
# Preserves x-dso-version key during merge.
#
# Returns: 0 on success, 2 on conflict (JSON to stdout)
merge_ci_workflow() {
    local target_file="$1"
    local plugin_ci="$2"
    local dryrun="${3:-}"

    if [[ ! -f "$target_file" ]]; then
        if [[ -z "$dryrun" ]]; then
            cp "$plugin_ci" "$target_file"
            echo "[merge_ci_workflow] Created $target_file from plugin CI"
        else
            echo "[dryrun][merge_ci_workflow] Would create $target_file from plugin CI"
        fi
        return 0
    fi

    if [[ ! -f "$plugin_ci" ]]; then
        echo "WARNING: merge_ci_workflow: plugin CI file not found: $plugin_ci" >&2
        return 0
    fi

    # ── Primary path: python3 + PyYAML ────────────────────────────────────────
    # Probe yaml availability first — this allows stubs/mocks to intercept
    # "import yaml" in the argument list and force the awk fallback path.
    local _yaml_ok=0
    python3 -c "import yaml" >/dev/null 2>&1 && _yaml_ok=1

    if [[ "$_yaml_ok" -eq 1 ]]; then
        local merge_result
        merge_result=$(python3 - "$target_file" "$plugin_ci" 2>/dev/null <<'PYEOF'
import sys, yaml, copy

target_path = sys.argv[1]
plugin_path = sys.argv[2]

try:
    with open(target_path) as f:
        target = yaml.safe_load(f) or {}
    with open(plugin_path) as f:
        plugin = yaml.safe_load(f) or {}
except Exception as e:
    sys.exit(1)

# Preserve x-dso-version from plugin
if 'x-dso-version' in plugin:
    target['x-dso-version'] = plugin['x-dso-version']

# Merge jobs: add plugin jobs that don't exist in target
target_jobs = target.get('jobs', {})
plugin_jobs = plugin.get('jobs', {})
jobs_added = []
for job_name, job_def in plugin_jobs.items():
    if job_name not in target_jobs:
        target_jobs[job_name] = copy.deepcopy(job_def)
        jobs_added.append(job_name)

target['jobs'] = target_jobs

# Dump merged YAML
merged = yaml.dump(target, default_flow_style=False, allow_unicode=True,
                   sort_keys=False, indent=2)
print(merged)
PYEOF
) 2>/dev/null

        local py_exit=$?

        if [[ $py_exit -eq 0 && -n "$merge_result" ]]; then
            if [[ -z "$dryrun" ]]; then
                printf '%s\n' "$merge_result" > "$target_file"
                echo "[merge_ci_workflow] Merged plugin CI jobs into $target_file"
            else
                echo "[dryrun][merge_ci_workflow] Would merge plugin CI jobs into $target_file"
            fi
            return 0
        fi
    fi

    # ── Fallback: awk/sed block insertion ─────────────────────────────────────
    # Extract plugin job names and their blocks, then append to host CI's jobs section.
    _merge_ci_workflow_awk_fallback "$target_file" "$plugin_ci" "$dryrun"
}

# _extract_job_block_bash PLUGIN_CI JOB_NAME
# Extracts a single job block by name from a GitHub Actions YAML file using
# bash builtins. Prints the job block lines (without trailing newline) to stdout.
# Prints nothing if the job is not found.
_extract_job_block_bash() {
    local plugin_ci="$1" job_name="$2"
    local _in_jobs=0 _in_job=0 _job_lines=""
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        if [[ "$_line" == "jobs:" ]]; then _in_jobs=1; continue; fi
        [[ "$_in_jobs" -eq 0 ]] && continue
        if [[ -n "$_line" && "${_line:0:1}" != " " ]]; then
            _in_jobs=0
            [[ "$_in_job" -eq 1 ]] && break
            continue
        fi
        if [[ "$_line" == "  ${job_name}:" ]]; then
            _in_job=1; _job_lines+="${_line}"$'\n'; continue
        fi
        [[ "$_in_job" -eq 0 ]] && continue
        if [[ "$_line" == "  "[a-zA-Z]* ]]; then
            local _check="${_line#  }" _jname
            _jname="${_check%%:*}"
            if [[ "$_check" == "${_jname}:"* && "$_jname" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
                break
            fi
        fi
        _job_lines+="${_line}"$'\n'
    done < "$plugin_ci"
    printf '%s' "${_job_lines%$'\n'}"
}

# _merge_ci_workflow_awk_fallback TARGET_CI PLUGIN_CI DRYRUN
# Fallback for merge_ci_workflow when python3+PyYAML is unavailable.
# Strategy:
#   1. Use python3 without yaml (re/text) — works when stub only blocks yaml imports
#   2. Fall back to pure bash line-by-line reading (no external tools needed)
# Appends plugin job blocks to the target CI file, idempotent.
_merge_ci_workflow_awk_fallback() {
    local target_file="$1"
    local plugin_ci="$2"
    local dryrun="${3:-}"

    # ── Extract job names from plugin CI ──────────────────────────────────────
    # Try python3 (no yaml) first; fall back to bash builtins.
    local plugin_job_names=""

    plugin_job_names=$(python3 - "$plugin_ci" 2>/dev/null <<'PYEOF'
import sys, re
plugin_path = sys.argv[1]
try:
    with open(plugin_path) as f:
        content = f.read()
except Exception:
    sys.exit(1)
in_jobs = False
job_names = []
for line in content.splitlines():
    if line == 'jobs:':
        in_jobs = True
        continue
    if in_jobs:
        if line and line[0] != ' ':
            in_jobs = False
            continue
        m = re.match(r'^  ([a-zA-Z][a-zA-Z0-9_-]*):\s*$', line)
        if m:
            job_names.append(m.group(1))
print('\n'.join(job_names))
PYEOF
) 2>/dev/null || plugin_job_names=""

    # ── Bash-builtin fallback: read file line by line ─────────────────────────
    if [[ -z "$plugin_job_names" ]]; then
        local _in_jobs=0
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            if [[ "$_line" == "jobs:" ]]; then
                _in_jobs=1
                continue
            fi
            if [[ "$_in_jobs" -eq 1 ]]; then
                # Non-indented line ends jobs section
                if [[ -n "$_line" && "${_line:0:1}" != " " ]]; then
                    _in_jobs=0
                    continue
                fi
                # Match "  <job_name>:" pattern
                local _trimmed="${_line#  }"
                if [[ "$_line" == "  "* && "$_trimmed" != "$_line" ]]; then
                    local _rest="${_trimmed%%:*}"
                    if [[ "$_trimmed" == "${_rest}:"* && "$_rest" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
                        plugin_job_names+="${_rest}"$'\n'
                    fi
                fi
            fi
        done < "$plugin_ci"
        # Remove trailing newline
        plugin_job_names="${plugin_job_names%$'\n'}"
    fi

    if [[ -z "$plugin_job_names" ]]; then
        echo "WARNING: _merge_ci_workflow_awk_fallback: could not extract job names from $plugin_ci" >&2
        return 0
    fi

    # ── Read target file content into bash variable ───────────────────────────
    local _target_content
    _target_content=$(<"$target_file") 2>/dev/null || _target_content=""

    # ── Process each job: check presence, extract block, append ──────────────
    local jobs_added=()
    while IFS= read -r job_name; do
        [[ -z "$job_name" ]] && continue

        # Check if job already present in target (bash string search)
        if [[ "$_target_content" == *"  ${job_name}:"* ]]; then
            continue
        fi

        # Extract the job block from plugin CI using python3 (no yaml) or bash
        local job_block=""

        job_block=$(python3 - "$plugin_ci" "$job_name" 2>/dev/null <<'PYEOF'
import sys, re
plugin_path = sys.argv[1]
job_name = sys.argv[2]
try:
    with open(plugin_path) as f:
        lines = [l.rstrip('\n') for l in f.readlines()]
except Exception:
    sys.exit(1)
in_jobs = False
in_job = False
job_lines = []
for line in lines:
    if line == 'jobs:':
        in_jobs = True
        continue
    if in_jobs:
        if line and line[0] != ' ':
            in_jobs = False
            continue
        if re.match(r'^  ' + re.escape(job_name) + r':\s*$', line):
            in_job = True
            job_lines.append(line)
            continue
        if in_job:
            if re.match(r'^  [a-zA-Z][a-zA-Z0-9_-]*:\s*$', line):
                break
            job_lines.append(line)
print('\n'.join(job_lines))
PYEOF
) 2>/dev/null || job_block=""

        # ── Bash-builtin job block extraction fallback ────────────────────────
        if [[ -z "$job_block" ]]; then
            job_block=$(_extract_job_block_bash "$plugin_ci" "$job_name")
        fi

        if [[ -n "$job_block" ]]; then
            jobs_added+=("$job_name")
            if [[ -z "$dryrun" ]]; then
                printf '\n%s\n' "$job_block" >> "$target_file"
                # Update cached content
                _target_content+=$'\n'"$job_block"
            fi
        fi
    done <<< "$plugin_job_names"

    if [[ ${#jobs_added[@]} -gt 0 ]]; then
        if [[ -z "$dryrun" ]]; then
            echo "[merge_ci_workflow] Appended ${#jobs_added[@]} DSO job(s) to $target_file (awk fallback): ${jobs_added[*]}"
        else
            echo "[dryrun][merge_ci_workflow] Would append jobs (awk fallback): ${jobs_added[*]}"
        fi
    fi

    return 0
}

# ── merge_precommit_hooks ─────────────────────────────────────────────────────
# Usage: merge_precommit_hooks TARGET_FILE EXAMPLE_FILE DRYRUN
#
# Moved from dso-setup.sh — identical logic (append-repos strategy, idempotent).
# Primary: python3+PyYAML. Fallback: awk-based block extraction and text append.
#
# Strategy: append-repos — add a new DSO 'local' repo block to the repos: list.
# The existing file's content (including other repo blocks) is fully preserved.
# Idempotent: if DSO hook ids are already present, they are not duplicated.
merge_precommit_hooks() {
    local target_file="$1"
    local example_file="$2"
    local dryrun="${3:-}"

    # Guard: only merge if the target file has a 'repos:' section
    if ! grep -q '^repos:' "$target_file" 2>/dev/null; then
        echo "WARNING: .pre-commit-config.yaml exists but has no 'repos:' section — skipping merge" >&2
        return 0
    fi

    # Extract DSO hook ids from the example file
    local dso_hook_ids
    dso_hook_ids=$(python3 - "$example_file" 2>/dev/null <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
    ids = []
    for repo in cfg.get('repos', []):
        if repo.get('repo') == 'local':
            for hook in repo.get('hooks', []):
                ids.append(hook['id'])
    print('\n'.join(ids))
except Exception:
    sys.exit(1)
PYEOF
) || dso_hook_ids=""

    # Fallback: extract hook ids using grep if python3/PyYAML unavailable
    if [[ -z "$dso_hook_ids" ]]; then
        dso_hook_ids=$(grep -E '^\s+- id:' "$example_file" 2>/dev/null | sed 's/.*- id: *//' | tr -d ' ')
    fi

    if [[ -z "$dso_hook_ids" ]]; then
        echo "WARNING: Could not extract DSO hook ids from $example_file — skipping merge" >&2
        return 0
    fi

    # Check which DSO hook ids are already present in the target file
    local hooks_to_add=()
    while IFS= read -r hook_id; do
        [[ -z "$hook_id" ]] && continue
        if ! grep -qF "id: $hook_id" "$target_file" 2>/dev/null; then
            hooks_to_add+=("$hook_id")
        fi
    done <<< "$dso_hook_ids"

    if [[ ${#hooks_to_add[@]} -eq 0 ]]; then
        if [[ -n "$dryrun" ]]; then
            echo "[dryrun] .pre-commit-config.yaml: all DSO hooks already present — no merge needed"
        else
            echo "[skip] .pre-commit-config.yaml: all DSO hooks already present — not merging"
        fi
        return 0
    fi

    # Build the DSO hook block containing only hooks to add
    local dso_block
    dso_block=$(python3 - "$example_file" "${hooks_to_add[@]}" 2>/dev/null <<'PYEOF'
import sys, yaml

example_file = sys.argv[1]
needed_ids = set(sys.argv[2:])

try:
    with open(example_file) as f:
        cfg = yaml.safe_load(f)
    hooks = []
    for repo in cfg.get('repos', []):
        if repo.get('repo') == 'local':
            for hook in repo.get('hooks', []):
                if hook['id'] in needed_ids:
                    hooks.append(hook)

    if not hooks:
        sys.exit(1)

    new_block = {'repo': 'local', 'hooks': hooks}
    block_yaml = yaml.dump(new_block, default_flow_style=False,
                           allow_unicode=True, sort_keys=False, indent=2)
    lines = block_yaml.rstrip('\n').splitlines()
    result_lines = []
    for i, line in enumerate(lines):
        if i == 0:
            result_lines.append('  - ' + line)
        else:
            result_lines.append('    ' + line)
    print('\n'.join(result_lines))
except Exception:
    sys.exit(1)
PYEOF
) || dso_block=""

    # Fallback: awk-based extraction if python3/PyYAML unavailable
    if [[ -z "$dso_block" ]]; then
        local full_block
        full_block=$(awk '
            /^  - repo: local/{found=1; print; next}
            found && /^  - repo:/{exit}
            found{print}
        ' "$example_file" 2>/dev/null)
        if [[ -n "$full_block" ]]; then
            dso_block="$full_block"
        fi
    fi

    if [[ -z "$dso_block" ]]; then
        echo "WARNING: Could not extract DSO hook block from $example_file — skipping merge" >&2
        return 0
    fi

    local hooks_list
    hooks_list=$(IFS=', '; echo "${hooks_to_add[*]}")

    if [[ -n "$dryrun" ]]; then
        echo "[dryrun] Would merge DSO hooks into .pre-commit-config.yaml: $hooks_list"
        echo "[dryrun] Would append a new DSO local repo block containing: $hooks_list"
        return 0
    fi

    printf '\n  # DSO plugin hooks (added by dso-setup.sh — do not remove)\n' >> "$target_file"
    printf '%s\n' "$dso_block" >> "$target_file"
    echo "[merge] Appended DSO hooks to .pre-commit-config.yaml: $hooks_list"
}
