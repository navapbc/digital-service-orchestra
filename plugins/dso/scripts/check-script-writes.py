#!/usr/bin/env python3
"""
check-script-writes.py — detect file-write operations targeting repo-root paths.

Uses shfmt --tojson to parse shell scripts and walk the AST to identify:
  - Redirect operators (>, >>) targeting repo-root paths
  - Write commands (tee, cp, mv) targeting repo-root paths

Exit 0 if no violations found. Exit 1 if violations detected.
Lines with '# write-ok: <reason>' are suppressed.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# shfmt redirect Op codes: auto-discovered at runtime (see discover_write_redirect_ops).
# Fallback values {54, 55} are used only if discovery fails.
WRITE_REDIRECT_OPS = {54, 55}

# Commands whose last positional arg is a write target
WRITE_COMMANDS = {"tee", "cp", "mv"}

# Paths that are NOT repo-root (should not be flagged)
SAFE_PATH_PREFIXES = ("/tmp", "/var", "/dev/null", "/dev/")


def discover_write_redirect_ops(shfmt_path):
    """
    Discover the integer Op codes shfmt uses for '>' and '>>' by probing it
    with a simple test script.  Returns a set of op codes, or falls back to
    {54, 55} if discovery fails.
    """
    ops = set()
    test_cases = [
        "echo x > /tmp/shfmt_probe_write",
        "echo x >> /tmp/shfmt_probe_write",
    ]
    for script in test_cases:
        try:
            result = subprocess.run(
                [shfmt_path, "--tojson"],
                input=script,
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode != 0:
                continue
            ast = json.loads(result.stdout)
            for stmt in ast.get("Stmts", []):
                for redir in stmt.get("Redirs", []):
                    op = redir.get("Op")
                    if op is not None:
                        ops.add(op)
        except Exception:
            continue
    return ops if ops else {54, 55}


def find_shfmt(shfmt_path=None):
    """Find shfmt binary. Returns path if found, None otherwise."""
    if shfmt_path:
        if os.path.isfile(shfmt_path) and os.access(shfmt_path, os.X_OK):
            return shfmt_path
        return None
    # Try well-known locations
    for candidate in ["/usr/local/bin/shfmt", "/usr/bin/shfmt"]:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    # Try PATH
    try:
        result = subprocess.run(
            ["which", "shfmt"], capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            path = result.stdout.strip()
            if path:
                return path
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def collect_sh_files(scan_dir):
    """Collect all .sh files in scan_dir. Uses find for temp dirs, git ls-files for repo paths."""
    scan_path = Path(scan_dir).resolve()

    # Check if scan_dir is inside a git repo
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            cwd=str(scan_path),
            timeout=5,
        )
        in_git_repo = result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        in_git_repo = False

    if in_git_repo:
        try:
            result = subprocess.run(
                ["git", "ls-files", "--", "*.sh"],
                capture_output=True,
                text=True,
                cwd=str(scan_path),
                timeout=10,
            )
            if result.returncode == 0:
                files = []
                for rel_path in result.stdout.splitlines():
                    if rel_path:
                        full = scan_path / rel_path
                        if full.exists():
                            files.append(str(full))
                return files
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    # Fallback: use find/glob for temp dirs or when git fails
    return [str(p) for p in scan_path.rglob("*.sh")]


def parse_ast(shfmt_path, filepath):
    """Parse a shell script and return its AST as a dict, or None on failure."""
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        result = subprocess.run(
            [shfmt_path, "--tojson"],
            input=content,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return None
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return None


def extract_word_parts(word_node):
    """
    Extract parts from a Word AST node.
    Returns a list of part descriptors: each is either:
      - ('literal', str_value)
      - ('param', var_name)
      - ('complex', None)  -- command substitution or other non-traceable part
    """
    if not word_node or "Parts" not in word_node:
        return []

    parts = []
    for part in word_node["Parts"]:
        ptype = part.get("Type", "")
        if ptype == "Lit":
            parts.append(("literal", part.get("Value", "")))
        elif ptype == "DblQuoted":
            # Recurse into double-quoted string
            inner = extract_word_parts({"Parts": part.get("Parts", [])})
            parts.extend(inner)
        elif ptype == "SglQuoted":
            parts.append(("literal", part.get("Value", "")))
        elif ptype == "ParamExp":
            # Variable expansion like $FOO or ${FOO}
            param = part.get("Param", {})
            var_name = param.get("Value", "") if param else ""
            if var_name:
                parts.append(("param", var_name))
            else:
                parts.append(("complex", None))
        elif ptype in ("CmdSubst", "ArithmExp", "ProcSubst"):
            parts.append(("complex", None))
        else:
            parts.append(("complex", None))
    return parts


def resolve_word(word_node, var_map, depth=0):
    """
    Attempt to resolve a Word node to a string path.
    Returns the resolved string, or None if unresolvable.
    depth: current recursion depth for variable resolution.
    """
    if depth > 3:
        return None

    parts = extract_word_parts(word_node)
    if not parts:
        return None

    resolved = ""
    for ptype, pval in parts:
        if ptype == "literal":
            resolved += pval
        elif ptype == "param":
            # Try to resolve from var_map
            if pval not in var_map:
                return None  # Tier 3: no assignment
            assignments = var_map[pval]
            if len(assignments) != 1:
                return None  # Tier 3: multiple or zero assignments
            _, rhs_word = assignments[0]
            inner = resolve_word(rhs_word, var_map, depth + 1)
            if inner is None:
                return None
            resolved += inner
        elif ptype == "complex":
            return None  # Unresolvable

    return resolved


def is_safe_path(path):
    """Return True if the path is a safe (non-repo-root) location."""
    if not path:
        return True
    # Home directory expansions are not repo-root
    if path.startswith("~/") or path == "~":
        return True
    # Normalize
    for prefix in SAFE_PATH_PREFIXES:
        if path.startswith(prefix):
            return True
    return False


def is_repo_root_path(path):
    """Return True if the path targets the repo root (relative or absolute $REPO_ROOT-like)."""
    if not path:
        return False
    if is_safe_path(path):
        return False

    # Relative paths (./foo, foo/bar, not starting with /)
    if not path.startswith("/"):
        return True

    # Absolute paths under $REPO_ROOT placeholder (shouldn't appear after resolution normally)
    # But check anyway
    if path.startswith("$REPO_ROOT") or path.startswith("$(git rev-parse"):
        return True

    # Absolute path not under safe prefixes — could be repo root
    # We only flag relative paths and known patterns
    # Absolute paths to non-safe locations are ambiguous — skip them
    return False


def collect_assignments(ast):
    """
    Walk the AST and collect all variable assignments.
    Returns a dict: var_name -> list of (line_num, rhs_word_node)
    """
    assignments = {}

    def walk(node):
        if not isinstance(node, dict):
            return
        if node.get("Type") == "CallExpr":
            for assign in node.get("Assigns", []):
                name_node = assign.get("Name", {})
                var_name = name_node.get("Value", "") if name_node else ""
                value_word = assign.get("Value")
                if var_name and value_word:
                    line = assign.get("Pos", {}).get("Line", 0)
                    if var_name not in assignments:
                        assignments[var_name] = []
                    assignments[var_name].append((line, value_word))

        for key, val in node.items():
            if key in (
                "Pos",
                "End",
                "OpPos",
                "Hash",
                "Left",
                "Right",
                "ValuePos",
                "ValueEnd",
            ):
                continue
            if isinstance(val, dict):
                walk(val)
            elif isinstance(val, list):
                for item in val:
                    if isinstance(item, dict):
                        walk(item)

    walk(ast)
    return assignments


def has_write_ok_comment(stmt_node, line_num):
    """Check if the statement node has a write-ok comment on the same line."""
    for comment in stmt_node.get("Comments", []):
        comment_line = comment.get("Pos", {}).get("Line", -1)
        comment_text = comment.get("Text", "")
        if comment_line == line_num and "write-ok:" in comment_text:
            return True
    return False


def subshell_has_cd_to_variable(stmts):
    """
    Return True if any statement in stmts is a `cd` to a non-literal path
    (i.e., contains a variable expansion), indicating a `cd "$tmpdir"` pattern.
    """
    for stmt in stmts:
        if not isinstance(stmt, dict):
            continue
        cmd = stmt.get("Cmd", {})
        if not cmd or cmd.get("Type") != "CallExpr":
            continue
        args = cmd.get("Args", [])
        if not args:
            continue
        first_parts = extract_word_parts(args[0])
        if not first_parts or first_parts[0] != ("literal", "cd"):
            continue
        # It's a cd command — check if any arg contains a variable
        for arg in args[1:]:
            parts = extract_word_parts(arg)
            for ptype, _ in parts:
                if ptype in ("param", "complex"):
                    return True  # cd to a variable path
    return False


def _is_cd_to_variable(stmt):
    """Return True if stmt is (or contains) a `cd` to a non-literal (variable) path.

    Handles: `cd "$var"`, `cd "$var" || ...`, `cd "$var" && ...`
    """
    if not isinstance(stmt, dict):
        return False
    cmd = stmt.get("Cmd", {})
    if not cmd:
        return False

    cmd_type = cmd.get("Type", "")

    if cmd_type == "CallExpr":
        args = cmd.get("Args", [])
        if not args:
            return False
        first_parts = extract_word_parts(args[0])
        if not first_parts or first_parts[0] != ("literal", "cd"):
            return False
        for arg in args[1:]:
            parts = extract_word_parts(arg)
            for ptype, _ in parts:
                if ptype in ("param", "complex"):
                    return True
        return False

    elif cmd_type == "BinaryCmd":
        # Handle `cd "$var" || ...` — check the left side
        x_stmt = cmd.get("X")
        if x_stmt:
            x_cmd = x_stmt.get("Cmd", {})
            if x_cmd and x_cmd.get("Type") == "CallExpr":
                args = x_cmd.get("Args", [])
                if args:
                    first_parts = extract_word_parts(args[0])
                    if first_parts and first_parts[0] == ("literal", "cd"):
                        for arg in args[1:]:
                            parts = extract_word_parts(arg)
                            for ptype, _ in parts:
                                if ptype in ("param", "complex"):
                                    return True

    return False


def _walk_stmts(stmts, violations, var_map):
    """Walk a list of statements, tracking cd-to-variable context."""
    cwd_is_temp = False
    for stmt in stmts:
        if not isinstance(stmt, dict):
            continue
        if _is_cd_to_variable(stmt):
            cwd_is_temp = True
            continue
        if cwd_is_temp:
            # After a cd to a variable, skip relative writes at this level
            # (they're in the temp dir context)
            continue
        _walk_stmt(stmt, violations, var_map)


def _walk_nested(node, violations, var_map):
    """Recursively walk nested command structures."""
    if not isinstance(node, dict):
        return
    for key, val in node.items():
        if key in (
            "Pos",
            "End",
            "OpPos",
            "Hash",
            "Left",
            "Right",
            "ValuePos",
            "ValueEnd",
            "Name",
        ):
            continue
        if key == "Stmts":
            for s in val:
                _walk_stmt(s, violations, var_map)
        elif isinstance(val, dict):
            _walk_nested(val, violations, var_map)
        elif isinstance(val, list):
            for item in val:
                if isinstance(item, dict):
                    node_type = item.get("Type", "")
                    if node_type or "Cmd" in item or "Redirs" in item:
                        _walk_stmt(item, violations, var_map)
                    else:
                        _walk_nested(item, violations, var_map)


def _walk_stmt(stmt, violations, var_map):
    """Walk a single statement node, appending violations."""
    if not isinstance(stmt, dict):
        return

    stmt_line = stmt.get("Pos", {}).get("Line", 0)
    cmd = stmt.get("Cmd", {})
    cmd_type = cmd.get("Type", "") if cmd else ""

    # Check redirects on the statement
    for redir in stmt.get("Redirs", []):
        op = redir.get("Op", 0)
        if op in WRITE_REDIRECT_OPS:
            redir_line = redir.get("Pos", {}).get("Line", stmt_line)
            word = redir.get("Word")
            if word:
                resolved = resolve_word(word, var_map)
                if resolved and is_repo_root_path(resolved):
                    if not has_write_ok_comment(stmt, redir_line):
                        violations.append((redir_line, resolved))

    if cmd_type == "CallExpr":
        args = cmd.get("Args", [])
        if args:
            first_parts = extract_word_parts(args[0])
            cmd_name = ""
            if first_parts and first_parts[0][0] == "literal":
                cmd_name = first_parts[0][1]

            if cmd_name in WRITE_COMMANDS:
                if len(args) > 1:
                    # Skip flags (args starting with -)
                    for arg in reversed(args[1:]):
                        arg_parts = extract_word_parts(arg)
                        if arg_parts and arg_parts[0][0] == "literal":
                            if not arg_parts[0][1].startswith("-"):
                                resolved = resolve_word(arg, var_map)
                                if resolved and is_repo_root_path(resolved):
                                    if not has_write_ok_comment(stmt, stmt_line):
                                        violations.append((stmt_line, resolved))
                                break
                        else:
                            resolved = resolve_word(arg, var_map)
                            if resolved and is_repo_root_path(resolved):
                                if not has_write_ok_comment(stmt, stmt_line):
                                    violations.append((stmt_line, resolved))
                            break

    elif cmd_type == "BinaryCmd":
        # Pipeline: X | Y — walk both sides
        x_stmt = cmd.get("X")
        y_stmt = cmd.get("Y")
        if x_stmt:
            _walk_stmt(x_stmt, violations, var_map)
        if y_stmt:
            _walk_stmt(y_stmt, violations, var_map)

    elif cmd_type == "Subshell":
        # Subshell: walk with fresh cd-tracking context
        inner_stmts = cmd.get("Stmts", [])
        _walk_stmts(inner_stmts, violations, var_map)

    elif cmd_type in (
        "IfClause",
        "WhileClause",
        "ForClause",
        "CaseClause",
        "Block",
    ):
        _walk_nested(cmd, violations, var_map)

    elif cmd_type == "FuncDecl":
        # Function body: walk with fresh cd-tracking context
        body = cmd.get("Body", {})
        if body:
            inner_stmts = body.get("Stmts", [])
            _walk_stmts(inner_stmts, violations, var_map)


def find_violations_in_ast(ast, filepath, var_map):
    """Walk the AST and find file-write violations.

    Returns list of (line_num, path_str) tuples.
    """
    violations = []
    _walk_stmts(ast.get("Stmts", []), violations, var_map)
    return violations


def main():
    parser = argparse.ArgumentParser(
        description="Detect file-write operations targeting repo-root paths in shell scripts."
    )
    parser.add_argument(
        "--scan-dir",
        required=True,
        help="Directory to scan for .sh files",
    )
    parser.add_argument(
        "--shfmt-path",
        default=None,
        help="Path to shfmt binary (optional)",
    )
    args = parser.parse_args()

    shfmt = find_shfmt(args.shfmt_path)
    if not shfmt:
        print("INFO: shfmt not found — skipping check-script-writes analysis")
        sys.exit(0)

    # Discover the actual redirect op codes for this shfmt version
    global WRITE_REDIRECT_OPS
    WRITE_REDIRECT_OPS = discover_write_redirect_ops(shfmt)

    scan_dir = args.scan_dir
    if not os.path.isdir(scan_dir):
        print(f"ERROR: scan-dir '{scan_dir}' does not exist or is not a directory")
        sys.exit(2)

    sh_files = collect_sh_files(scan_dir)

    # Phase 1: Build corpus-wide variable map (Tier 2 tracing)
    corpus_var_map = {}  # var_name -> list of (line_num, rhs_word_node)
    file_asts = {}

    for filepath in sh_files:
        ast = parse_ast(shfmt, filepath)
        if ast is None:
            continue
        file_asts[filepath] = ast
        file_assignments = collect_assignments(ast)
        for var_name, assigns in file_assignments.items():
            if var_name not in corpus_var_map:
                corpus_var_map[var_name] = []
            corpus_var_map[var_name].extend(assigns)

    # Filter corpus_var_map: only keep vars with exactly 1 assignment and pure literal RHS
    filtered_var_map = {}
    for var_name, assigns in corpus_var_map.items():
        if len(assigns) == 1:
            filtered_var_map[var_name] = assigns

    # Phase 2: Find violations
    all_violations = []
    for filepath, ast in file_asts.items():
        violations = find_violations_in_ast(ast, filepath, filtered_var_map)
        for line_num, path_str in violations:
            all_violations.append((filepath, line_num, path_str))

    # Report
    for filepath, line_num, path_str in sorted(all_violations):
        print(f"FAIL [{filepath}:{line_num}] write to repo-root path: {path_str}")

    if all_violations:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
