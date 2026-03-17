"""Tests for the Flask/Jinja2 YAML stack adapter config.

Validates that:
1. The YAML adapter file exists and parses correctly
2. It contains all required fields matching the component discovery schema
3. Its content matches the reference JSON adapter (single source of truth)
4. The adapter selection metadata maps correctly (stack + template_engine)
"""

import json
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
YAML_ADAPTER_PATH = (
    REPO_ROOT / "config" / "stack-adapters" / "flask-jinja2.yaml"
)
JSON_ADAPTER_PATH = REPO_ROOT / "docs" / "adapters" / "flask-jinja2.json"
SCHEMA_PATH = REPO_ROOT / "docs" / "component-discovery-schema.json"


@pytest.fixture
def yaml_adapter():
    """Load the Flask/Jinja2 YAML adapter config."""
    assert YAML_ADAPTER_PATH.exists(), f"YAML adapter not found at {YAML_ADAPTER_PATH}"
    with open(YAML_ADAPTER_PATH) as f:
        return yaml.safe_load(f)


@pytest.fixture
def json_adapter():
    """Load the Flask/Jinja2 JSON reference adapter."""
    assert JSON_ADAPTER_PATH.exists(), f"JSON adapter not found at {JSON_ADAPTER_PATH}"
    with open(JSON_ADAPTER_PATH) as f:
        return json.load(f)


@pytest.fixture
def schema():
    """Load the component discovery schema."""
    assert SCHEMA_PATH.exists(), f"Schema not found at {SCHEMA_PATH}"
    with open(SCHEMA_PATH) as f:
        return json.load(f)


class TestYamlAdapterExists:
    """The YAML adapter file exists and is valid YAML."""

    def test_file_exists(self):
        assert YAML_ADAPTER_PATH.exists()

    def test_parses_as_yaml(self, yaml_adapter):
        assert isinstance(yaml_adapter, dict)


class TestYamlAdapterSelectionMetadata:
    """The adapter includes selection metadata for config-driven dispatch."""

    def test_has_selector_section(self, yaml_adapter):
        """Adapter defines its selection criteria."""
        assert "selector" in yaml_adapter

    def test_selector_has_stack(self, yaml_adapter):
        """Selector declares which stack value triggers this adapter."""
        selector = yaml_adapter["selector"]
        assert "stack" in selector
        assert selector["stack"] == "python-poetry"

    def test_selector_has_template_engine(self, yaml_adapter):
        """Selector declares which template_engine value triggers this adapter."""
        selector = yaml_adapter["selector"]
        assert "template_engine" in selector
        assert selector["template_engine"] == "jinja2"


class TestYamlAdapterSchemaConformance:
    """The YAML adapter has all fields required by the component discovery schema."""

    def test_has_name(self, yaml_adapter):
        assert yaml_adapter["name"] == "flask-jinja2"

    def test_has_route_patterns(self, yaml_adapter):
        rp = yaml_adapter["route_patterns"]
        assert "decorator_patterns" in rp
        assert "template_render_patterns" in rp
        assert "registration_patterns" in rp

    def test_has_component_file_patterns(self, yaml_adapter):
        cfp = yaml_adapter["component_file_patterns"]
        assert "glob_patterns" in cfp
        assert "definition_patterns" in cfp
        assert "import_patterns" in cfp

    def test_has_template_syntax(self, yaml_adapter):
        ts = yaml_adapter["template_syntax"]
        assert "component_definition" in ts
        assert "inheritance_pattern" in ts
        assert "include_patterns" in ts

    def test_has_framework_detection(self, yaml_adapter):
        fd = yaml_adapter["framework_detection"]
        assert "marker_files" in fd
        assert "marker_keys" in fd

    def test_all_required_fields_present(self, yaml_adapter, schema):
        """Every required field from the schema exists in the adapter."""
        for field in schema.get("required", []):
            assert field in yaml_adapter, f"Missing required field: {field}"


class TestYamlAdapterContentMatchesJson:
    """The YAML adapter content matches the reference JSON adapter."""

    def test_route_decorator_patterns_match(self, yaml_adapter, json_adapter):
        """Route decorator patterns are identical."""
        yaml_decorators = yaml_adapter["route_patterns"]["decorator_patterns"]
        json_decorators = json_adapter["route_patterns"]["decorator_patterns"]
        assert len(yaml_decorators) == len(json_decorators)
        for y, j in zip(yaml_decorators, json_decorators):
            assert y["pattern"] == j["pattern"]

    def test_component_glob_patterns_match(self, yaml_adapter, json_adapter):
        """Component glob patterns are identical."""
        yaml_globs = yaml_adapter["component_file_patterns"]["glob_patterns"]
        json_globs = json_adapter["component_file_patterns"]["glob_patterns"]
        assert set(yaml_globs) == set(json_globs)

    def test_template_markers_match(self, yaml_adapter, json_adapter):
        """Template syntax markers are identical."""
        yaml_cd = yaml_adapter["template_syntax"]["component_definition"]["pattern"]
        json_cd = json_adapter["template_syntax"]["component_definition"]["pattern"]
        assert yaml_cd == json_cd

    def test_framework_detection_matches(self, yaml_adapter, json_adapter):
        """Framework detection config is identical."""
        yaml_fd = yaml_adapter["framework_detection"]
        json_fd = json_adapter["framework_detection"]
        assert yaml_fd["marker_files"] == json_fd["marker_files"]
        yaml_keys = [k["key"] for k in yaml_fd["marker_keys"]]
        json_keys = [k["key"] for k in json_fd["marker_keys"]]
        assert yaml_keys == json_keys


class TestYamlAdapterAcceptanceCriteria:
    """Verify acceptance criteria from the ticket."""

    def test_ac_route_patterns(self, yaml_adapter):
        """AC: route pattern includes @blueprint.route and @app.route."""
        patterns = [p["pattern"] for p in yaml_adapter["route_patterns"]["decorator_patterns"]]
        has_blueprint = any("route" in p and "\\w+" in p for p in patterns)
        has_app = any("app" in p and "route" in p for p in patterns)
        assert has_blueprint, "Must include @blueprint.route pattern"
        assert has_app, "Must include @app.route pattern"

    def test_ac_component_globs(self, yaml_adapter):
        """AC: component globs include **/templates/**/*.html."""
        globs = yaml_adapter["component_file_patterns"]["glob_patterns"]
        assert "**/templates/**/*.html" in globs

    def test_ac_template_markers(self, yaml_adapter):
        """AC: template markers include {% macro %}, {% extends %}, {% block %}."""
        ts = yaml_adapter["template_syntax"]
        assert "macro" in ts["component_definition"]["pattern"]
        assert "extends" in ts["inheritance_pattern"]["pattern"]
        block_patterns = ts.get("block_patterns", [])
        assert any("block" in p["pattern"] for p in block_patterns)

    def test_ac_framework_detection(self, yaml_adapter):
        """AC: framework detection checks for flask or apiflask in pyproject.toml."""
        fd = yaml_adapter["framework_detection"]
        assert "pyproject.toml" in fd["marker_files"]
        keys = [k["key"] for k in fd["marker_keys"]]
        has_flask = any("flask" in k.lower() for k in keys)
        assert has_flask

    def test_ac_file_location(self):
        """AC: adapter lives in lockpick-workflow/config/stack-adapters/."""
        assert YAML_ADAPTER_PATH.exists()
        assert str(YAML_ADAPTER_PATH).endswith(
            "config/stack-adapters/flask-jinja2.yaml"
        )

    def test_ac_selectable_via_config(self, yaml_adapter):
        """AC: selectable via stack: python-poetry + design.template_engine: jinja2."""
        selector = yaml_adapter["selector"]
        assert selector["stack"] == "python-poetry"
        assert selector["template_engine"] == "jinja2"
