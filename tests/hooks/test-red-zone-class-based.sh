#!/usr/bin/env bash
set -euo pipefail
# tests/hooks/test-red-zone-class-based.sh
# Tests for class-based pytest marker handling in plugins/dso/hooks/lib/red-zone.sh
#
# Covers:
#   get_red_zone_line_number() with Class::method marker format
#   get_test_line_number() with class-based test method names

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PLUGIN_ROOT/tests/lib"

source "$LIB_DIR/assert.sh"
source "$PLUGIN_ROOT/plugins/dso/hooks/lib/red-zone.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

make_temp_file() {
    mktemp "${TMPDIR:-/tmp}/test-red-zone-class-XXXXXX"
}

make_temp_dir() {
    mktemp -d "${TMPDIR:-/tmp}/test-red-zone-class-dir-XXXXXX"
}

# ============================================================
# get_red_zone_line_number — Class::method marker tests
# ============================================================
echo ""
echo "=== get_red_zone_line_number (class-based markers) ==="

# Test: Class::method marker finds the method definition inside the class
# .test-index entry: tests/test_things.py [TestClass::test_red_method]
# The test file defines:
#   class TestClass:
#       def test_green_method(self): ...
#       def test_red_method(self): ...
_tf1=$(make_temp_file)
cat > "$_tf1" <<'EOF'
import pytest

class TestThings:
    def test_green_method(self):
        assert True

    def test_red_method(self):
        assert False
EOF
_repo1=$(make_temp_dir)
mkdir -p "$_repo1/tests"
_rel1="tests/test_things.py"
cp "$_tf1" "$_repo1/$_rel1"
# Marker uses Class::method format — function should find test_red_method line
_line1=$(REPO_ROOT="$_repo1" get_red_zone_line_number "$_rel1" "TestThings::test_red_method")
assert_eq "Class::method marker finds method def on correct line" "7" "$_line1"
rm -rf "$_repo1" "$_tf1"

# Test: Class::method marker where method appears early but class appears later
# Ensures we're matching the method inside the right class scope
_tf2=$(make_temp_file)
cat > "$_tf2" <<'EOF'
import pytest

def test_red_method():
    # standalone function with same name — should NOT be the marker target
    pass

class TestThings:
    def test_green_method(self):
        assert True

    def test_red_method(self):
        assert False
EOF
_repo2=$(make_temp_dir)
mkdir -p "$_repo2/tests"
_rel2="tests/test_things.py"
cp "$_tf2" "$_repo2/$_rel2"
# When marker is Class::method, it should find the method inside the class
# The class definition starts at line 7; the method is at line 11
_line2=$(REPO_ROOT="$_repo2" get_red_zone_line_number "$_rel2" "TestThings::test_red_method")
assert_eq "Class::method marker finds method inside class, not standalone function" "11" "$_line2"
rm -rf "$_repo2" "$_tf2"

# Test: plain method marker (no :: separator) still works as before
_tf3=$(make_temp_file)
cat > "$_tf3" <<'EOF'
import pytest

class TestThings:
    def test_green_method(self):
        assert True

    def test_red_method(self):
        assert False
EOF
_repo3=$(make_temp_dir)
mkdir -p "$_repo3/tests"
_rel3="tests/test_things.py"
cp "$_tf3" "$_repo3/$_rel3"
_line3=$(REPO_ROOT="$_repo3" get_red_zone_line_number "$_rel3" "test_red_method")
assert_eq "plain method marker (no ::) still finds method def" "7" "$_line3"
rm -rf "$_repo3" "$_tf3"

# Test: Class::method marker where the class does not exist → returns -1
_tf4=$(make_temp_file)
cat > "$_tf4" <<'EOF'
import pytest

class TestOther:
    def test_red_method(self):
        assert False
EOF
_repo4=$(make_temp_dir)
mkdir -p "$_repo4/tests"
_rel4="tests/test_things.py"
cp "$_tf4" "$_repo4/$_rel4"
_line4=$(REPO_ROOT="$_repo4" get_red_zone_line_number "$_rel4" "TestThings::test_red_method" 2>/dev/null)
assert_eq "Class::method where class not found returns -1" "-1" "$_line4"
rm -rf "$_repo4" "$_tf4"

# Test: Class::method marker where method does not exist in class → returns -1
_tf5=$(make_temp_file)
cat > "$_tf5" <<'EOF'
import pytest

class TestThings:
    def test_green_method(self):
        assert True
EOF
_repo5=$(make_temp_dir)
mkdir -p "$_repo5/tests"
_rel5="tests/test_things.py"
cp "$_tf5" "$_repo5/$_rel5"
_line5=$(REPO_ROOT="$_repo5" get_red_zone_line_number "$_rel5" "TestThings::test_nonexistent" 2>/dev/null)
assert_eq "Class::method where method not in class returns -1" "-1" "$_line5"
rm -rf "$_repo5" "$_tf5"

# ============================================================
# parse_failing_tests_from_output — class-based pytest output
# ============================================================
echo ""
echo "=== parse_failing_tests_from_output (class-based pytest output) ==="

# Test: pytest output with Class::method format extracts just the method name
_out6=$(make_temp_file)
cat > "$_out6" <<'EOF'
FAILED tests/test_things.py::TestThings::test_red_method
PASSED tests/test_things.py::TestThings::test_green_method
FAILED tests/test_things.py::TestOther::test_another_bad
EOF
_failing6=$(parse_failing_tests_from_output "$_out6" | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "pytest Class::method FAILED output extracts method names" "test_another_bad,test_red_method" "$_failing6"
rm -f "$_out6"

# ============================================================
print_summary
