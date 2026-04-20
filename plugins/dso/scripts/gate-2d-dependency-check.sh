#!/usr/bin/env bash
# gate-2d-dependency-check.sh
#
# Gate 2d: Dependency Check
# Scans proposed fix files for import/require statements and determines whether
# any new (previously unknown) dependencies are being introduced.
#
# Usage:
#   gate-2d-dependency-check.sh <file1> [file2 ...] --repo-root <path>
#
# Output: JSON conforming to gate-signal-schema.md
#   gate_id:     "2d"
#   triggered:   true if new dependency/import detected
#   signal_type: "primary"
#   evidence:    human-readable explanation
#   confidence:  "high" | "medium" | "low"
#
# Always exits 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────

REPO_ROOT=""
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            REPO_ROOT="$2"
            shift 2
            ;;
        --repo-root=*)
            REPO_ROOT="${1#--repo-root=}"
            shift
            ;;
        -*)
            shift
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

# Default repo root to git toplevel
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
fi

# ── Format check config resolution ───────────────────────────────────────────

_FORMAT_CHECK_EVIDENCE=""
CMD_FORMAT_CHECK=""
_fc_config=""
if [[ -n "${WORKFLOW_CONFIG_FILE:-}" && -f "${WORKFLOW_CONFIG_FILE}" ]]; then
    _fc_config="${WORKFLOW_CONFIG_FILE}"
elif [[ -f "$REPO_ROOT/.claude/dso-config.conf" ]]; then
    _fc_config="$REPO_ROOT/.claude/dso-config.conf"
fi
if [[ -n "$_fc_config" && -f "$SCRIPT_DIR/read-config.sh" ]]; then
    CMD_FORMAT_CHECK=$("$SCRIPT_DIR/read-config.sh" "commands.format_check" "$_fc_config" 2>/dev/null || true)
fi
if [[ -z "$CMD_FORMAT_CHECK" ]]; then
    echo "[DSO WARN] commands.format_check not configured — skipping format check in gate-2d." >&2
else
    _fc_out=$(eval "$CMD_FORMAT_CHECK" 2>&1) && _fc_exit=0 || _fc_exit=$?
    if [[ "$_fc_exit" -ne 0 ]]; then
        _FORMAT_CHECK_EVIDENCE="Format check failed: $_fc_out"
    fi
fi

# ── JSON output helper ────────────────────────────────────────────────────────

emit_signal() {
    local triggered="$1"
    local evidence="$2"
    local confidence="$3"
    # Append format check evidence when non-empty
    if [[ -n "${_FORMAT_CHECK_EVIDENCE:-}" ]]; then
        evidence="${evidence}; ${_FORMAT_CHECK_EVIDENCE}"
    fi
    # Convert bash true/false to Python True/False
    local py_bool="True"
    [[ "$triggered" == "false" ]] && py_bool="False"
    python3 -c "
import json, sys
evidence = sys.argv[1]
confidence = sys.argv[2]
triggered = $py_bool
print(json.dumps({
    'gate_id': '2d',
    'triggered': triggered,
    'signal_type': 'primary',
    'evidence': evidence,
    'confidence': confidence
}))
" "$evidence" "$confidence"
}

# ── Python stdlib set ─────────────────────────────────────────────────────────
# A representative set of Python stdlib module names to avoid false positives.
# These are always considered "known" and never trigger the gate.

python3_stdlib_modules() {
    python3 -c "import sys; import stdlib_list; print('\n'.join(stdlib_list.stdlib_list()))" 2>/dev/null \
    || python3 -c "
import sys
# Use sys.stdlib_module_names (Python 3.10+) or a hardcoded fallback
if hasattr(sys, 'stdlib_module_names'):
    print('\n'.join(sys.stdlib_module_names))
else:
    # Common stdlib modules as fallback
    mods = [
        'abc','ast','asyncio','base64','binascii','bisect','builtins',
        'calendar','cgi','cgitb','chunk','cmath','cmd','code','codecs',
        'codeop','collections','colorsys','compileall','concurrent','configparser',
        'contextlib','contextvars','copy','copyreg','csv','ctypes','curses',
        'dataclasses','datetime','dbm','decimal','difflib','dis','distutils',
        'doctest','email','encodings','enum','errno','faulthandler',
        'fcntl','filecmp','fileinput','fnmatch','fractions','ftplib',
        'functools','gc','getopt','getpass','gettext','glob','grp',
        'gzip','hashlib','heapq','hmac','html','http','idlelib',
        'imaplib','importlib','inspect','io','ipaddress','itertools',
        'json','keyword','lib2to3','linecache','locale','logging',
        'lzma','mailbox','math','mimetypes','mmap','modulefinder',
        'multiprocessing','netrc','nis','nntplib','numbers','operator',
        'optparse','os','ossaudiodev','pathlib','pdb','pickle',
        'pickletools','pipes','pkgutil','platform','plistlib','poplib',
        'posix','posixpath','pprint','profile','pstats','pty','pwd',
        'py_compile','pyclbr','pydoc','queue','quopri','random',
        're','readline','reprlib','resource','rlcompleter','runpy',
        'sched','secrets','select','selectors','shelve','shlex',
        'shutil','signal','site','smtpd','smtplib','sndhdr','socket',
        'socketserver','spwd','sqlite3','sre_compile','sre_constants',
        'sre_parse','ssl','stat','statistics','string','stringprep',
        'struct','subprocess','sunau','symtable','sys','sysconfig',
        'syslog','tabnanny','tarfile','telnetlib','tempfile','termios',
        'test','textwrap','threading','time','timeit','tkinter','token',
        'tokenize','tomllib','trace','traceback','tracemalloc','tty',
        'turtle','turtledemo','types','typing','unicodedata','unittest',
        'urllib','uu','uuid','venv','warnings','wave','weakref',
        'webbrowser','wsgiref','xdrlib','xml','xmlrpc','zipapp',
        'zipfile','zipimport','zlib','zoneinfo','_thread',
        'antigravity','cProfile','this',
    ]
    print('\n'.join(mods))
"
}

# ── Extract Python imports from a file ────────────────────────────────────────

extract_python_imports() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import sys, re, ast

filepath = sys.argv[1]
try:
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        src = f.read()
    # Try AST parse first
    try:
        tree = ast.parse(src)
        packages = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    top = alias.name.split('.')[0]
                    packages.add(top)
            elif isinstance(node, ast.ImportFrom):
                if node.module and node.level == 0:
                    top = node.module.split('.')[0]
                    packages.add(top)
        for p in sorted(packages):
            print(p)
    except SyntaxError:
        # Fallback: regex-based extraction
        for m in re.finditer(r'^\s*import\s+([\w.]+)', src, re.MULTILINE):
            print(m.group(1).split('.')[0])
        for m in re.finditer(r'^\s*from\s+([\w.]+)\s+import', src, re.MULTILINE):
            print(m.group(1).split('.')[0])
except Exception:
    pass
PYEOF
}

# ── Extract Node.js requires from a file ──────────────────────────────────────

extract_node_requires() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import sys, re

filepath = sys.argv[1]
try:
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        src = f.read()
    # Match require('pkg') and require("pkg")
    # Also match ES module: import ... from 'pkg'
    packages = set()
    for m in re.finditer(r"""require\s*\(\s*['"]([^'"./][^'"]*)['"]\s*\)""", src):
        pkg = m.group(1).split('/')[0]  # handle scoped packages like @org/pkg
        if pkg.startswith('@'):
            # scoped package: @org/pkg -> @org/pkg (take first two segments)
            parts = m.group(1).split('/')
            if len(parts) >= 2:
                pkg = parts[0] + '/' + parts[1]
        packages.add(pkg)
    for m in re.finditer(r"""from\s+['"]([^'"./][^'"]*)['"]\s*""", src):
        pkg = m.group(1).split('/')[0]
        if pkg.startswith('@'):
            parts = m.group(1).split('/')
            if len(parts) >= 2:
                pkg = parts[0] + '/' + parts[1]
        packages.add(pkg)
    for p in sorted(packages):
        print(p)
except Exception:
    pass
PYEOF
}

# ── Load Python manifest dependencies ─────────────────────────────────────────

load_pyproject_deps() {
    local pyproject="$1"
    python3 - "$pyproject" <<'PYEOF'
import sys, json, re

filepath = sys.argv[1]
deps = set()

try:
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()

    # Try to use tomllib (Python 3.11+) or tomli
    try:
        import tomllib
        data = tomllib.loads(content)
    except ImportError:
        try:
            import tomli as tomllib
            data = tomllib.loads(content)
        except ImportError:
            data = None

    if data is not None:
        # [project].dependencies (PEP 621)
        project_deps = data.get('project', {}).get('dependencies', [])
        for dep in project_deps:
            # Normalize: extract package name before version specifier
            name = re.split(r'[>=<!;,\[\s]', dep.strip())[0].lower().replace('-', '_').replace('.', '_')
            if name:
                deps.add(name)

        # [tool.poetry.dependencies]
        poetry_deps = data.get('tool', {}).get('poetry', {}).get('dependencies', {})
        for pkg in poetry_deps:
            if pkg.lower() != 'python':
                name = pkg.lower().replace('-', '_').replace('.', '_')
                deps.add(name)
    else:
        # Fallback: regex parse for common patterns
        # [project] dependencies
        in_project_deps = False
        in_poetry_deps = False
        for line in content.splitlines():
            stripped = line.strip()
            if stripped == '[project]':
                in_project_deps = False
                in_poetry_deps = False
            elif stripped == 'dependencies':
                pass
            elif re.match(r'^\[', stripped):
                # Check if this is the dependencies array under [project]
                in_project_deps = False
                in_poetry_deps = False

        # Simple regex for quoted strings in dependencies arrays
        for m in re.finditer(r'["\']([A-Za-z][A-Za-z0-9_.\-]*)', content):
            name = m.group(1).lower().replace('-', '_').replace('.', '_')
            if name and not name.startswith('_'):
                deps.add(name)

except Exception:
    pass

for d in sorted(deps):
    print(d)
PYEOF
}

# ── Load Node.js manifest dependencies ────────────────────────────────────────

load_package_json_deps() {
    local pkg_json="$1"
    python3 - "$pkg_json" <<'PYEOF'
import sys, json

filepath = sys.argv[1]
deps = set()

try:
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        data = json.load(f)

    for section in ('dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies'):
        for pkg in data.get(section, {}):
            deps.add(pkg.lower())
except Exception:
    pass

for d in sorted(deps):
    print(d)
PYEOF
}

# ── Check if an import/package already appears in codebase ────────────────────

import_used_elsewhere() {
    local pkg="$1"
    local repo_root="$2"
    local skip_file="$3"  # relative path to exclude

    # Search for the import pattern in Python and JS files
    # We search for: import <pkg>, from <pkg>, require('<pkg>')
    local found=0

    # Use grep to find usage; exclude the file under analysis
    local abs_skip=""
    if [[ -n "$skip_file" ]]; then
        abs_skip="$repo_root/$skip_file"
    fi

    # Python imports
    while IFS= read -r match_file; do
        local abs_match
        abs_match="$(realpath "$match_file" 2>/dev/null || echo "$match_file")"
        local abs_skip_real=""
        if [[ -n "$abs_skip" ]]; then
            abs_skip_real="$(realpath "$abs_skip" 2>/dev/null || echo "$abs_skip")"
        fi
        if [[ -z "$abs_skip_real" ]] || [[ "$abs_match" != "$abs_skip_real" ]]; then
            found=1
            break
        fi
    done < <(grep -rl --include="*.py" --include="*.js" --include="*.ts" --include="*.jsx" --include="*.tsx" \
        -F -e "import ${pkg}" -e "from ${pkg}" -e "require('${pkg}')" -e "require(\"${pkg}\")" \
        "$repo_root" 2>/dev/null || true)

    return $((found == 0 ? 1 : 0))
}

# ── Main logic ────────────────────────────────────────────────────────────────

main() {
    if [[ ${#FILES[@]} -eq 0 ]]; then
        emit_signal "false" "No files provided for analysis." "low"
        exit 0
    fi

    local pyproject="$REPO_ROOT/pyproject.toml"
    local pkg_json="$REPO_ROOT/package.json"

    local has_pyproject=false
    local has_pkg_json=false
    [[ -f "$pyproject" ]] && has_pyproject=true
    [[ -f "$pkg_json" ]] && has_pkg_json=true

    # Load known dependencies from manifests
    local manifest_deps=()
    if $has_pyproject; then
        while IFS= read -r dep; do
            [[ -n "$dep" ]] && manifest_deps+=("$dep")
        done < <(load_pyproject_deps "$pyproject" 2>/dev/null || true)
    fi
    if $has_pkg_json; then
        while IFS= read -r dep; do
            [[ -n "$dep" ]] && manifest_deps+=("$dep")
        done < <(load_package_json_deps "$pkg_json" 2>/dev/null || true)
    fi

    # Load Python stdlib list
    local stdlib_mods=()
    while IFS= read -r mod; do
        [[ -n "$mod" ]] && stdlib_mods+=("$mod")
    done < <(python3_stdlib_modules 2>/dev/null || true)

    # Helper: check if a name is in an array
    contains_item() {
        local needle="${1,,}"  # lowercase
        local item
        for item in "${@:2}"; do
            if [[ "${item,,}" == "$needle" ]]; then
                return 0
            fi
        done
        return 1
    }

    # Normalize package name for comparison
    normalize_pkg() {
        local name="$1"
        python3 -c "print('${name}'.lower().replace('-','_').replace('.','_'))"
    }

    local new_deps=()
    local all_imports_checked=()
    local checked_in_manifest=false
    $has_pyproject && checked_in_manifest=true
    $has_pkg_json && checked_in_manifest=true

    for rel_file in "${FILES[@]}"; do
        local abs_file="$REPO_ROOT/$rel_file"

        # Skip if file doesn't exist
        [[ -f "$abs_file" ]] || continue

        local ext="${rel_file##*.}"
        local imports=()

        # Extract imports based on file type
        case "$ext" in
            py)
                while IFS= read -r imp; do
                    [[ -n "$imp" ]] && imports+=("$imp")
                done < <(extract_python_imports "$abs_file" 2>/dev/null || true)
                ;;
            js|ts|jsx|tsx|mjs|cjs)
                while IFS= read -r imp; do
                    [[ -n "$imp" ]] && imports+=("$imp")
                done < <(extract_node_requires "$abs_file" 2>/dev/null || true)
                ;;
            *)
                # Try Python extraction as fallback for unknown extensions
                while IFS= read -r imp; do
                    [[ -n "$imp" ]] && imports+=("$imp")
                done < <(extract_python_imports "$abs_file" 2>/dev/null || true)
                ;;
        esac

        for raw_imp in "${imports[@]}"; do
            local norm_imp
            norm_imp="$(normalize_pkg "$raw_imp" 2>/dev/null || echo "${raw_imp,,}")"

            all_imports_checked+=("$raw_imp")

            # Skip stdlib/builtin modules
            if contains_item "$norm_imp" "${stdlib_mods[@]:-}"; then
                continue
            fi

            # Skip common Node.js builtin modules
            case "$norm_imp" in
                fs|path|os|http|https|url|util|events|stream|buffer|process|child_process|\
                crypto|net|dns|tls|readline|cluster|worker_threads|v8|vm|assert|perf_hooks|\
                module|timers|string_decoder|zlib|querystring|domain|repl|console|punycode)
                    continue
                    ;;
            esac

            # Check 1: Is it in a manifest?
            if $has_pyproject || $has_pkg_json; then
                if contains_item "$norm_imp" "${manifest_deps[@]:-}"; then
                    # Known dependency — not new
                    continue
                fi
                # Manifest exists but package not found — potentially new
                # Still check codebase usage before flagging
            fi

            # Check 2: Is this import already used elsewhere in the codebase?
            if import_used_elsewhere "$raw_imp" "$REPO_ROOT" "$rel_file" 2>/dev/null; then
                # Already used elsewhere — not a new dependency
                continue
            fi

            # Neither in manifest nor used elsewhere → new dependency
            new_deps+=("$raw_imp")
        done
    done

    # Determine triggered state
    if [[ ${#new_deps[@]} -gt 0 ]]; then
        local dep_list
        dep_list="$(IFS=', '; echo "${new_deps[*]}")"
        local evidence="New dependency/import detected that is not in the manifest and not used elsewhere in the codebase: ${dep_list}."
        emit_signal "true" "$evidence" "high"
    else
        local evidence_parts=()

        if $has_pyproject || $has_pkg_json; then
            evidence_parts+=("All imports found in manifest")
        fi

        if [[ ${#all_imports_checked[@]} -gt 0 ]]; then
            local checked_list
            checked_list="$(IFS=', '; echo "${all_imports_checked[*]}")"
            evidence_parts+=("Imports checked: ${checked_list}")
        else
            evidence_parts+=("No non-stdlib imports detected in the analyzed files")
        fi

        if ! $has_pyproject && ! $has_pkg_json; then
            evidence_parts+=("No manifest files found; import-only analysis performed")
        fi

        local evidence
        evidence="$(IFS='. '; echo "${evidence_parts[*]}")."

        emit_signal "false" "$evidence" "medium"
    fi
}

main
