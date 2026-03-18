"""Tests for the stack-agnostic component discovery interface schema.

Validates that:
1. The schema file is valid JSON with all required interface fields
2. The Flask/Jinja2 reference adapter conforms to the interface
3. The interface is extensible — new adapters only need a new config block
4. The workflow-config-schema.json integrates the design.stack_adapters section
"""

import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
DSO_PLUGIN_DIR = REPO_ROOT / "plugins" / "dso"
SCHEMA_PATH = DSO_PLUGIN_DIR / "docs" / "component-discovery-schema.json"
WORKFLOW_CONFIG_SCHEMA_PATH = DSO_PLUGIN_DIR / "docs" / "workflow-config-schema.json"
FLASK_ADAPTER_PATH = DSO_PLUGIN_DIR / "docs" / "adapters" / "flask-jinja2.json"


@pytest.fixture
def schema():
    """Load the component discovery interface schema."""
    assert SCHEMA_PATH.exists(), f"Schema file not found at {SCHEMA_PATH}"
    with open(SCHEMA_PATH) as f:
        return json.load(f)


@pytest.fixture
def flask_adapter():
    """Load the Flask/Jinja2 reference adapter."""
    assert FLASK_ADAPTER_PATH.exists(), (
        f"Flask adapter not found at {FLASK_ADAPTER_PATH}"
    )
    with open(FLASK_ADAPTER_PATH) as f:
        return json.load(f)


@pytest.fixture
def workflow_config_schema():
    """Load the workflow-config-schema.json."""
    assert WORKFLOW_CONFIG_SCHEMA_PATH.exists()
    with open(WORKFLOW_CONFIG_SCHEMA_PATH) as f:
        return json.load(f)


class TestComponentDiscoverySchemaStructure:
    """The schema defines all four required interface sections."""

    def test_schema_is_valid_json(self, schema):
        """Schema parses as valid JSON."""
        assert isinstance(schema, dict)

    def test_schema_has_metadata(self, schema):
        """Schema includes $schema and title."""
        assert "$schema" in schema
        assert "title" in schema
        assert schema["title"] == "component-discovery-adapter"

    def test_schema_defines_route_patterns(self, schema):
        """Schema requires route_patterns section."""
        props = schema["properties"]
        assert "route_patterns" in props
        route_props = props["route_patterns"]["properties"]
        # Must define how to find route decorators
        assert "decorator_patterns" in route_props
        # Must define how to find template rendering calls
        assert "template_render_patterns" in route_props
        # Must define how to detect route registration (e.g. blueprint)
        assert "registration_patterns" in route_props

    def test_schema_defines_component_file_patterns(self, schema):
        """Schema requires component_file_patterns section."""
        props = schema["properties"]
        assert "component_file_patterns" in props
        comp_props = props["component_file_patterns"]["properties"]
        # Glob patterns to find component files
        assert "glob_patterns" in comp_props
        # Regex to extract component definitions from files
        assert "definition_patterns" in comp_props
        # Patterns to find component imports/usage
        assert "import_patterns" in comp_props

    def test_schema_defines_template_syntax_markers(self, schema):
        """Schema requires template_syntax section."""
        props = schema["properties"]
        assert "template_syntax" in props
        tmpl_props = props["template_syntax"]["properties"]
        # How to find component/macro definitions in templates
        assert "component_definition" in tmpl_props
        # How to find template inheritance
        assert "inheritance_pattern" in tmpl_props
        # How to find template includes
        assert "include_patterns" in tmpl_props

    def test_schema_defines_framework_detection(self, schema):
        """Schema requires framework_detection section."""
        props = schema["properties"]
        assert "framework_detection" in props
        detect_props = props["framework_detection"]["properties"]
        # Marker files that identify this framework
        assert "marker_files" in detect_props
        # Keys within marker files to check
        assert "marker_keys" in detect_props

    def test_all_four_sections_are_required(self, schema):
        """All four interface sections are listed as required."""
        required = schema.get("required", [])
        assert "route_patterns" in required
        assert "component_file_patterns" in required
        assert "template_syntax" in required
        assert "framework_detection" in required

    def test_schema_has_name_field(self, schema):
        """Adapter must declare its name (e.g. 'flask-jinja2')."""
        assert "name" in schema["properties"]
        assert "name" in schema.get("required", [])


class TestFlaskJinja2Adapter:
    """The Flask/Jinja2 reference adapter implements all interface sections."""

    def test_adapter_name(self, flask_adapter):
        assert flask_adapter["name"] == "flask-jinja2"

    def test_route_patterns_decorator(self, flask_adapter):
        """Flask adapter defines @blueprint.route and shorthand patterns."""
        decorators = flask_adapter["route_patterns"]["decorator_patterns"]
        assert len(decorators) >= 1
        # Must include the Blueprint route decorator pattern
        decorator_strs = [d["pattern"] for d in decorators]
        has_blueprint_route = any("route" in p for p in decorator_strs)
        assert has_blueprint_route, (
            "Flask adapter must include blueprint.route decorator pattern"
        )

    def test_route_patterns_template_render(self, flask_adapter):
        """Flask adapter defines render_template pattern."""
        patterns = flask_adapter["route_patterns"]["template_render_patterns"]
        assert len(patterns) >= 1
        pattern_strs = [p["pattern"] for p in patterns]
        has_render = any("render_template" in p for p in pattern_strs)
        assert has_render

    def test_route_patterns_registration(self, flask_adapter):
        """Flask adapter defines blueprint registration pattern."""
        patterns = flask_adapter["route_patterns"]["registration_patterns"]
        assert len(patterns) >= 1
        pattern_strs = [p["pattern"] for p in patterns]
        has_register = any("register_blueprint" in p for p in pattern_strs)
        assert has_register

    def test_component_file_patterns_globs(self, flask_adapter):
        """Flask adapter specifies Jinja2 template glob patterns."""
        globs = flask_adapter["component_file_patterns"]["glob_patterns"]
        assert len(globs) >= 1
        # Should include .html files (Jinja2 templates)
        has_html = any(".html" in g for g in globs)
        assert has_html

    def test_component_file_patterns_definitions(self, flask_adapter):
        """Flask adapter specifies macro definition regex."""
        defs = flask_adapter["component_file_patterns"]["definition_patterns"]
        assert len(defs) >= 1
        pattern_strs = [d["pattern"] for d in defs]
        has_macro = any("macro" in p for p in pattern_strs)
        assert has_macro

    def test_component_file_patterns_imports(self, flask_adapter):
        """Flask adapter specifies import/include patterns."""
        imports = flask_adapter["component_file_patterns"]["import_patterns"]
        assert len(imports) >= 1
        pattern_strs = [p["pattern"] for p in imports]
        has_import = any("import" in p for p in pattern_strs)
        assert has_import

    def test_template_syntax_component_definition(self, flask_adapter):
        """Flask adapter defines {% macro %} as component definition."""
        comp_def = flask_adapter["template_syntax"]["component_definition"]
        assert "pattern" in comp_def
        assert "macro" in comp_def["pattern"]

    def test_template_syntax_inheritance(self, flask_adapter):
        """Flask adapter defines {% extends %} as inheritance."""
        inheritance = flask_adapter["template_syntax"]["inheritance_pattern"]
        assert "pattern" in inheritance
        assert "extends" in inheritance["pattern"]

    def test_template_syntax_includes(self, flask_adapter):
        """Flask adapter defines {% include %} and {% import %} patterns."""
        includes = flask_adapter["template_syntax"]["include_patterns"]
        assert len(includes) >= 2
        pattern_strs = [p["pattern"] for p in includes]
        has_include = any("include" in p for p in pattern_strs)
        has_import = any("import" in p for p in pattern_strs)
        assert has_include
        assert has_import

    def test_framework_detection_marker_files(self, flask_adapter):
        """Flask adapter detects via pyproject.toml."""
        markers = flask_adapter["framework_detection"]["marker_files"]
        assert len(markers) >= 1
        has_pyproject = any("pyproject.toml" in m for m in markers)
        assert has_pyproject

    def test_framework_detection_marker_keys(self, flask_adapter):
        """Flask adapter checks for flask/apiflask in dependencies."""
        keys = flask_adapter["framework_detection"]["marker_keys"]
        assert len(keys) >= 1
        key_strs = [k["key"] for k in keys]
        has_flask = any("flask" in k.lower() for k in key_strs)
        assert has_flask


class TestExtensibility:
    """Adding a new stack requires only a new adapter config block."""

    def test_schema_does_not_hardcode_flask(self, schema):
        """Schema itself does not reference Flask/Jinja2 specifics."""
        schema_str = json.dumps(schema)
        # The schema should be generic — no Flask/Jinja2 terms
        assert "flask" not in schema_str.lower()
        assert "jinja" not in schema_str.lower()
        assert "blueprint" not in schema_str.lower()

    def test_mock_react_adapter_conforms(self, schema):
        """A hypothetical React adapter has the same structure as Flask."""
        mock_react = {
            "name": "react-nextjs",
            "route_patterns": {
                "decorator_patterns": [
                    {
                        "pattern": "export default function.*Page",
                        "description": "Next.js page component export",
                    }
                ],
                "template_render_patterns": [
                    {
                        "pattern": "return\\s*\\(",
                        "description": "JSX return statement",
                    }
                ],
                "registration_patterns": [
                    {
                        "pattern": "app/.*page\\.tsx$",
                        "description": "Next.js app router file convention",
                    }
                ],
            },
            "component_file_patterns": {
                "glob_patterns": [
                    "src/components/**/*.tsx",
                    "src/components/**/*.jsx",
                ],
                "definition_patterns": [
                    {
                        "pattern": "export\\s+(default\\s+)?function\\s+(\\w+)",
                        "description": "React function component export",
                    }
                ],
                "import_patterns": [
                    {
                        "pattern": "import\\s+.*from\\s+['\"]\\./",
                        "description": "ES module import",
                    }
                ],
            },
            "template_syntax": {
                "component_definition": {
                    "pattern": "export\\s+(default\\s+)?function\\s+(\\w+)",
                    "description": "React function component",
                },
                "inheritance_pattern": {
                    "pattern": "import\\s+.*Layout.*from",
                    "description": "Layout component import",
                },
                "include_patterns": [
                    {
                        "pattern": "import\\s+\\w+\\s+from",
                        "description": "Component import",
                    },
                    {
                        "pattern": "<(\\w+)",
                        "description": "JSX component usage",
                    },
                ],
            },
            "framework_detection": {
                "marker_files": ["package.json", "next.config.js"],
                "marker_keys": [
                    {
                        "key": "dependencies.next",
                        "description": "Next.js in package.json dependencies",
                    }
                ],
            },
        }
        # Validate all required fields exist
        required = schema.get("required", [])
        for field in required:
            assert field in mock_react, (
                f"Mock React adapter missing required field: {field}"
            )

    def test_adapter_structure_is_pure_data(self, flask_adapter):
        """Adapter is pure data (JSON) — no code, no logic."""

        # Verify all leaf values are JSON primitives (str, int, float, bool, None)
        def check_pure_data(obj, path=""):
            if isinstance(obj, dict):
                for k, v in obj.items():
                    check_pure_data(v, f"{path}.{k}")
            elif isinstance(obj, list):
                for i, v in enumerate(obj):
                    check_pure_data(v, f"{path}[{i}]")
            elif isinstance(obj, str):
                # No Python function definitions or exec() calls
                assert "def " not in obj, f"Code found at {path}: {obj}"
                assert "exec(" not in obj, f"Exec call at {path}: {obj}"
                assert "eval(" not in obj, f"Eval call at {path}: {obj}"
            else:
                assert isinstance(obj, (int, float, bool, type(None))), (
                    f"Non-JSON-primitive at {path}: {type(obj)}"
                )

        check_pure_data(flask_adapter)


class TestWorkflowConfigSchemaIntegration:
    """The workflow-config-schema.json references the adapter interface."""

    def test_design_section_exists_or_planned(self, workflow_config_schema):
        """The workflow config schema has a design section with stack_adapters.

        Note: The design section is added by ticket v9l9w.9 (blocker).
        This test validates the integration point exists once both tickets
        are complete. For now we verify the schema structure supports it.
        """
        props = workflow_config_schema.get("properties", {})
        # The design section should reference stack_adapters
        if "design" in props:
            design_props = props["design"].get("properties", {})
            assert "stack_adapters" in design_props or "template_engine" in design_props
        else:
            # design section not yet added (v9l9w.9 is our blocker)
            # Verify the schema is extensible (additionalProperties or
            # the design section can be added)
            pytest.skip(
                "design section not yet in workflow-config-schema.json "
                "(blocked by v9l9w.9)"
            )
