"""Unit tests for plugins/dso/scripts/figma_node_mapper.py (RED phase).

Tests cover:
  - NM-1: FRAME node bounding-box → spatial_hint on output component
  - NM-2: TEXT node with characters → text field on output component
  - NM-3: RECTANGLE node with fills → props.fills on output component
  - NM-4: COMPONENT node with componentId → componentId preserved
  - NM-5: INSTANCE node → type indicates instance
  - NM-6: Depth-limited traversal — nodes beyond depth_limit are not visited
  - NM-7: Name-based component linking — node name matching a component id links them
  - NM-8: CLI accepts --figma-response / --manifest-dir / --output flags (argparse interface)

All tests are expected to FAIL (ImportError / ModuleNotFoundError) because
figma_node_mapper.py does not exist yet (RED phase of TDD).
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "figma_node_mapper.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("figma_node_mapper", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def mapper() -> ModuleType:
    """Return the figma_node_mapper module; fail all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"figma_node_mapper.py not found at {SCRIPT_PATH} — "
            "module must be created before these tests can pass (expected RED failure)"
        )
    return _load_module()


# ---------------------------------------------------------------------------
# NM-1: FRAME node → spatial_hint from absoluteBoundingBox
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestFrameNodeBoundingBox:
    """NM-1: FRAME node with absoluteBoundingBox maps to a component with spatial_hint."""

    def test_frame_node_produces_component_with_spatial_hint(
        self, mapper: ModuleType
    ) -> None:
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "1:1",
                        "name": "Frame",
                        "type": "FRAME",
                        "absoluteBoundingBox": {
                            "x": 0,
                            "y": 0,
                            "width": 1440,
                            "height": 900,
                        },
                        "children": [],
                    }
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        assert len(result) >= 1, "Expected at least one component in output"
        component = result[0]
        assert "spatial_hint" in component, "Component must have a spatial_hint field"
        hint = component["spatial_hint"]
        assert hint["x"] == 0
        assert hint["y"] == 0
        assert hint["width"] == 1440
        assert hint["height"] == 900

    def test_frame_node_spatial_hint_reflects_non_zero_origin(
        self, mapper: ModuleType
    ) -> None:
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "1:2",
                        "name": "Offset Frame",
                        "type": "FRAME",
                        "absoluteBoundingBox": {
                            "x": 100,
                            "y": 200,
                            "width": 800,
                            "height": 600,
                        },
                        "children": [],
                    }
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        assert len(result) >= 1
        hint = result[0]["spatial_hint"]
        assert hint["x"] == 100
        assert hint["y"] == 200
        assert hint["width"] == 800
        assert hint["height"] == 600


# ---------------------------------------------------------------------------
# NM-2: TEXT node with characters → text field
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestTextNodeCharacters:
    """NM-2: TEXT node with characters field maps to component with text field."""

    def test_text_node_produces_component_with_text(self, mapper: ModuleType) -> None:
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "2:1",
                        "name": "Label",
                        "type": "TEXT",
                        "characters": "Hello World",
                        "children": [],
                    }
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        assert len(result) >= 1
        component = result[0]
        assert "text" in component, "TEXT node component must have a text field"
        assert component["text"] == "Hello World"

    def test_text_node_preserves_empty_string(self, mapper: ModuleType) -> None:
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "2:2",
                        "name": "Empty",
                        "type": "TEXT",
                        "characters": "",
                        "children": [],
                    }
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        assert len(result) >= 1
        assert result[0]["text"] == ""


# ---------------------------------------------------------------------------
# NM-3: RECTANGLE node with fills → props.fills
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestRectangleNodeFills:
    """NM-3: RECTANGLE node with fills maps to component with props.fills."""

    def test_rectangle_node_produces_component_with_fills(
        self, mapper: ModuleType
    ) -> None:
        fill = {"r": 0.9, "g": 0.9, "b": 0.9, "a": 1}
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "3:1",
                        "name": "Rect",
                        "type": "RECTANGLE",
                        "fills": [fill],
                        "children": [],
                    }
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        assert len(result) >= 1
        component = result[0]
        assert "props" in component, "RECTANGLE component must have a props field"
        assert "fills" in component["props"], "props must contain a fills key"
        assert len(component["props"]["fills"]) == 1
        assert component["props"]["fills"][0]["r"] == pytest.approx(0.9)
        assert component["props"]["fills"][0]["g"] == pytest.approx(0.9)
        assert component["props"]["fills"][0]["b"] == pytest.approx(0.9)
        assert component["props"]["fills"][0]["a"] == pytest.approx(1.0)

    def test_rectangle_node_multiple_fills_all_preserved(
        self, mapper: ModuleType
    ) -> None:
        fills = [
            {"r": 0.1, "g": 0.2, "b": 0.3, "a": 1},
            {"r": 0.4, "g": 0.5, "b": 0.6, "a": 0.5},
        ]
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "3:2",
                        "name": "MultiRect",
                        "type": "RECTANGLE",
                        "fills": fills,
                        "children": [],
                    }
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        assert len(result) >= 1
        assert len(result[0]["props"]["fills"]) == 2


# ---------------------------------------------------------------------------
# NM-4: COMPONENT node with componentId → componentId preserved
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestComponentNodeId:
    """NM-4: COMPONENT node with componentId keeps it in output."""

    def test_component_id_preserved_in_output(self, mapper: ModuleType) -> None:
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "4:1",
                        "name": "PrimaryButton",
                        "type": "COMPONENT",
                        "componentId": "component:primary-button-v1",
                        "children": [],
                    }
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        assert len(result) >= 1
        component = result[0]
        assert "componentId" in component, "COMPONENT output must have componentId"
        assert component["componentId"] == "component:primary-button-v1"


# ---------------------------------------------------------------------------
# NM-5: INSTANCE node → type indicates instance
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestInstanceNodeType:
    """NM-5: INSTANCE node output type clearly indicates it is an instance."""

    def test_instance_node_type_is_marked(self, mapper: ModuleType) -> None:
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "5:1",
                        "name": "Button Instance",
                        "type": "INSTANCE",
                        "componentId": "component:primary-button-v1",
                        "children": [],
                    }
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        assert len(result) >= 1
        component = result[0]
        # The output should either have a 'type' of 'instance' or an 'is_instance' flag
        is_instance = (
            component.get("type") == "instance"
            or component.get("is_instance") is True
            or component.get("node_type") == "INSTANCE"
        )
        assert is_instance, (
            f"INSTANCE node output must indicate it is an instance. Got: {component}"
        )


# ---------------------------------------------------------------------------
# NM-6: Depth-limit traversal — nodes beyond depth_limit not traversed
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestDepthLimitedTraversal:
    """NM-6: Nodes deeper than depth_limit are not traversed."""

    def _build_deep_tree(self, levels: int) -> dict:
        """Build a nested FRAME tree `levels` deep."""
        node: dict = {
            "id": f"6:{levels}",
            "name": f"Level-{levels}",
            "type": "FRAME",
            "absoluteBoundingBox": {"x": 0, "y": 0, "width": 100, "height": 100},
            "children": [],
        }
        for i in range(levels - 1, 0, -1):
            node = {
                "id": f"6:{i}",
                "name": f"Level-{i}",
                "type": "FRAME",
                "absoluteBoundingBox": {"x": 0, "y": 0, "width": 100, "height": 100},
                "children": [node],
            }
        return {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [node],
            }
        }

    def test_nodes_beyond_depth_limit_not_in_output(self, mapper: ModuleType) -> None:
        """A 30-level tree with depth_limit=20 must not include nodes at levels 21-30."""
        figma_json = self._build_deep_tree(30)
        result = mapper.map_nodes(figma_json, depth_limit=20)

        # Collect all node names to verify deep nodes are absent
        names = {c.get("name", "") for c in result}
        for level in range(21, 31):
            assert f"Level-{level}" not in names, (
                f"Level-{level} node should not appear when depth_limit=20"
            )

    def test_nodes_within_depth_limit_are_in_output(self, mapper: ModuleType) -> None:
        """Nodes at or within depth_limit must appear in output."""
        figma_json = self._build_deep_tree(30)
        result = mapper.map_nodes(figma_json, depth_limit=20)

        names = {c.get("name", "") for c in result}
        assert "Level-1" in names, "Root-level node must appear in output"

    def test_default_traversal_includes_shallow_tree(self, mapper: ModuleType) -> None:
        """A 5-level tree without depth_limit (or large limit) includes all nodes."""
        figma_json = self._build_deep_tree(5)
        result = mapper.map_nodes(figma_json)

        names = {c.get("name", "") for c in result}
        for level in range(1, 6):
            assert f"Level-{level}" in names, (
                f"Level-{level} must appear in output when no depth_limit is set"
            )


# ---------------------------------------------------------------------------
# NM-7: Name-based component linking
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestNameBasedComponentLinking:
    """NM-7: A node whose name matches an existing component id links to it."""

    def test_node_name_matching_component_id_is_linked(
        self, mapper: ModuleType
    ) -> None:
        """When a node's name equals a component id present in the graph,
        the output component should carry a link_to / linked_component field."""
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "7:1",
                        "name": "primary-button",
                        "type": "COMPONENT",
                        "componentId": "primary-button",
                        "children": [],
                    },
                    {
                        "id": "7:2",
                        "name": "primary-button",  # name matches component id above
                        "type": "FRAME",
                        "absoluteBoundingBox": {
                            "x": 0,
                            "y": 0,
                            "width": 200,
                            "height": 50,
                        },
                        "children": [],
                    },
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        # The FRAME node whose name matches the COMPONENT's id should be linked
        # Fallback: look for any non-component output that carries a link field
        linked = [
            c
            for c in result
            if c.get("link_to") == "primary-button"
            or c.get("linked_component") == "primary-button"
        ]
        assert len(linked) >= 1, (
            "At least one output component should be linked to 'primary-button' "
            f"because its name matches that component id. Got: {result}"
        )

    def test_node_name_not_matching_any_component_id_has_no_link(
        self, mapper: ModuleType
    ) -> None:
        """A node whose name does not match any component id must have no link field."""
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "7:3",
                        "name": "unique-unnamed-frame",
                        "type": "FRAME",
                        "absoluteBoundingBox": {
                            "x": 0,
                            "y": 0,
                            "width": 100,
                            "height": 100,
                        },
                        "children": [],
                    }
                ],
            }
        }

        result = mapper.map_nodes(figma_json)

        for component in result:
            assert "link_to" not in component or component["link_to"] is None, (
                "Component with unmatched name should not have a link_to field"
            )
            assert (
                "linked_component" not in component
                or component["linked_component"] is None
            )


# ---------------------------------------------------------------------------
# NM-8: CLI accepts --figma-response / --manifest-dir / --output flags
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestArgparseCLIInterface:
    """NM-8: figma_node_mapper.py CLI accepts flag-based arguments used by figma_resync.py.

    figma_resync.py._run_pull() invokes figma-node-mapper.py with:
        --figma-response <raw.json>
        --manifest-dir   <dir>
        --output         <revised-spatial.json>

    The script must accept these flags (in addition to the legacy positional form).
    """

    def _make_figma_json(self) -> dict:
        return {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "8:1",
                        "name": "TestFrame",
                        "type": "FRAME",
                        "absoluteBoundingBox": {
                            "x": 0,
                            "y": 0,
                            "width": 320,
                            "height": 240,
                        },
                        "children": [],
                    }
                ],
            }
        }

    def test_NM8_flag_based_invocation_exits_0(self) -> None:
        """NM-8a: --figma-response / --manifest-dir / --output flags → exit code 0."""
        with tempfile.TemporaryDirectory() as tmpdir:
            input_path = Path(tmpdir) / "figma-raw.json"
            output_path = Path(tmpdir) / "figma-revised-spatial.json"
            manifest_dir = tmpdir

            input_path.write_text(json.dumps(self._make_figma_json()))

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--figma-response",
                    str(input_path),
                    "--manifest-dir",
                    manifest_dir,
                    "--output",
                    str(output_path),
                ],
                capture_output=True,
                text=True,
            )

            assert result.returncode == 0, (
                f"Expected exit 0 for flag-based invocation. stderr: {result.stderr!r}"
            )

    def test_NM8_flag_based_invocation_writes_output_file(self) -> None:
        """NM-8b: Flag-based invocation writes the output JSON with a 'components' key."""
        with tempfile.TemporaryDirectory() as tmpdir:
            input_path = Path(tmpdir) / "figma-raw.json"
            output_path = Path(tmpdir) / "figma-revised-spatial.json"
            manifest_dir = tmpdir

            input_path.write_text(json.dumps(self._make_figma_json()))

            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--figma-response",
                    str(input_path),
                    "--manifest-dir",
                    manifest_dir,
                    "--output",
                    str(output_path),
                ],
                capture_output=True,
                text=True,
            )

            assert output_path.exists(), (
                "Output file must be created by flag-based invocation"
            )
            output_data = json.loads(output_path.read_text())
            assert "components" in output_data, (
                "Output JSON must contain 'components' key"
            )


# ---------------------------------------------------------------------------
# NM-9b: CLI --story-id/--design-id/--layout flags produce schema fields
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestSchemaFieldCLIFlags:
    """NM-9b: CLI flags --story-id, --design-id, --layout write schema-required top-level fields."""

    def _make_figma_json(self) -> dict:
        return {
            "document": {
                "id": "0:0",
                "name": "Doc",
                "type": "DOCUMENT",
                "children": [],
            }
        }

    def test_NM9b_story_id_flag_appears_in_output(self) -> None:
        """NM-9b-1: --story-id flag writes storyId to the output JSON."""
        with tempfile.TemporaryDirectory() as tmpdir:
            input_path = Path(tmpdir) / "figma.json"
            output_path = Path(tmpdir) / "out.json"
            input_path.write_text(json.dumps(self._make_figma_json()))

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--figma-response",
                    str(input_path),
                    "--manifest-dir",
                    tmpdir,
                    "--output",
                    str(output_path),
                    "--story-id",
                    "test-story-abc",
                ],
                capture_output=True,
                text=True,
            )
            assert result.returncode == 0, f"Expected exit 0. stderr: {result.stderr!r}"
            data = json.loads(output_path.read_text())
            assert data.get("storyId") == "test-story-abc", (
                f"Expected storyId='test-story-abc', got: {data.get('storyId')!r}"
            )

    def test_NM9b_design_id_flag_appears_in_output(self) -> None:
        """NM-9b-2: --design-id flag writes designId to the output JSON."""
        with tempfile.TemporaryDirectory() as tmpdir:
            input_path = Path(tmpdir) / "figma.json"
            output_path = Path(tmpdir) / "out.json"
            input_path.write_text(json.dumps(self._make_figma_json()))

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--figma-response",
                    str(input_path),
                    "--manifest-dir",
                    tmpdir,
                    "--output",
                    str(output_path),
                    "--design-id",
                    "d1234-5678",
                ],
                capture_output=True,
                text=True,
            )
            assert result.returncode == 0, f"Expected exit 0. stderr: {result.stderr!r}"
            data = json.loads(output_path.read_text())
            assert data.get("designId") == "d1234-5678", (
                f"Expected designId='d1234-5678', got: {data.get('designId')!r}"
            )

    def test_NM9b_layout_flag_appears_in_output(self) -> None:
        """NM-9b-3: --layout flag writes layout to the output JSON."""
        with tempfile.TemporaryDirectory() as tmpdir:
            input_path = Path(tmpdir) / "figma.json"
            output_path = Path(tmpdir) / "out.json"
            input_path.write_text(json.dumps(self._make_figma_json()))

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--figma-response",
                    str(input_path),
                    "--manifest-dir",
                    tmpdir,
                    "--output",
                    str(output_path),
                    "--layout",
                    "StickyHeader-Main-Footer",
                ],
                capture_output=True,
                text=True,
            )
            assert result.returncode == 0, f"Expected exit 0. stderr: {result.stderr!r}"
            data = json.loads(output_path.read_text())
            assert data.get("layout") == "StickyHeader-Main-Footer", (
                f"Expected layout='StickyHeader-Main-Footer', got: {data.get('layout')!r}"
            )


# ---------------------------------------------------------------------------
# NM-9: FRAME node with effects → props.effects on output component
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestEffectsFieldMapping:
    """NM-9: FRAME node with effects array maps effects to props.effects."""

    def test_NM9_frame_node_with_effects_maps_to_props_effects(
        self, mapper: ModuleType
    ) -> None:
        """NM-9: effects array from Figma node is mapped to component props.effects."""
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "1:1",
                        "name": "Frame",
                        "type": "FRAME",
                        "effects": [
                            {
                                "type": "DROP_SHADOW",
                                "color": {"r": 0, "g": 0, "b": 0, "a": 0.25},
                                "offset": {"x": 0, "y": 2},
                                "radius": 4,
                                "visible": True,
                            }
                        ],
                    }
                ],
            }
        }
        components = mapper.map_nodes(figma_json)
        assert len(components) == 1
        component = components[0]
        assert "props" in component, (
            "FRAME node with effects must have 'props' key in output"
        )
        assert "effects" in component["props"], (
            "props.effects must be present when node has effects array"
        )
        assert len(component["props"]["effects"]) == 1
        assert component["props"]["effects"][0]["type"] == "DROP_SHADOW"


# ---------------------------------------------------------------------------
# NM-10: FRAME node with layoutMode → props.responsive_hints
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestLayoutModeMapping:
    """NM-10: FRAME node with layoutMode maps to props.responsive_hints."""

    def test_NM10_frame_node_with_layout_mode_maps_to_responsive_hints(
        self, mapper: ModuleType
    ) -> None:
        """NM-10: layoutMode field from FRAME node is mapped to props.responsive_hints."""
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "1:1",
                        "name": "AutoLayoutFrame",
                        "type": "FRAME",
                        "layoutMode": "HORIZONTAL",
                    }
                ],
            }
        }
        components = mapper.map_nodes(figma_json)
        assert len(components) == 1
        component = components[0]
        assert "props" in component, (
            "FRAME node with layoutMode must have 'props' key in output"
        )
        assert "responsive_hints" in component["props"], (
            "props.responsive_hints must be present when node has layoutMode"
        )
        assert component["props"]["responsive_hints"] == "HORIZONTAL", (
            "responsive_hints must contain the layoutMode value"
        )

    def test_NM10b_frame_node_with_both_effects_and_layout_mode(
        self, mapper: ModuleType
    ) -> None:
        """NM-10b: FRAME node with both effects and layoutMode produces both in props."""
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "1:1",
                        "name": "AutoLayoutWithShadow",
                        "type": "FRAME",
                        "effects": [{"type": "DROP_SHADOW", "visible": True}],
                        "layoutMode": "VERTICAL",
                    }
                ],
            }
        }
        components = mapper.map_nodes(figma_json)
        assert len(components) == 1
        component = components[0]
        assert "props" in component
        assert "effects" in component["props"], (
            "props.effects must be present when node has effects"
        )
        assert "responsive_hints" in component["props"], (
            "props.responsive_hints must be present when node has layoutMode"
        )
        assert component["props"]["effects"][0]["type"] == "DROP_SHADOW"
        assert component["props"]["responsive_hints"] == "VERTICAL"

    def test_NM10c_frame_node_with_empty_effects_still_maps_prop(
        self, mapper: ModuleType
    ) -> None:
        """NM-10c: FRAME node with empty effects list still produces props.effects=[]."""
        figma_json = {
            "document": {
                "id": "0:0",
                "name": "Document",
                "type": "DOCUMENT",
                "children": [
                    {
                        "id": "1:1",
                        "name": "FrameEmptyEffects",
                        "type": "FRAME",
                        "effects": [],
                    }
                ],
            }
        }
        components = mapper.map_nodes(figma_json)
        assert len(components) == 1
        component = components[0]
        # 'effects' key present but empty list → props.effects = []
        assert "props" in component, (
            "FRAME node with empty effects must still have 'props' key"
        )
        assert "effects" in component["props"], (
            "props.effects must be present even when effects list is empty"
        )
        assert component["props"]["effects"] == []
