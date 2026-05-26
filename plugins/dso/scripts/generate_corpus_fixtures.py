"""Generate calibration corpus fixture directories."""

from __future__ import annotations
import json
import struct
import zlib
from pathlib import Path

CORPUS_ROOT = Path(__file__).resolve().parent.parent / "data" / "visual-eval-corpus"
ATTRIBUTION_CLASSES = ["implementation_drift", "design_flaw", "mixed", "uncertain"]
FIXTURES_PER_CLASS = 12  # 12 x 4 = 48 total (> 40 required)


def minimal_png(
    width: int = 8, height: int = 8, color: tuple = (200, 200, 200)
) -> bytes:
    """Generate a minimal valid PNG for fixture use."""
    r, g, b = color
    raw_row = b"\x00" + bytes([r, g, b] * width)
    raw_data = raw_row * height
    compressed = zlib.compress(raw_data)

    def chunk(name: bytes, data: bytes) -> bytes:
        c = name + data
        return (
            struct.pack(">I", len(data))
            + c
            + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", compressed)
    png += chunk(b"IEND", b"")
    return png


def make_fixture(fixture_dir: Path, attribution_class: str, idx: int) -> None:
    fixture_dir.mkdir(parents=True, exist_ok=True)
    (fixture_dir / "labels").mkdir(exist_ok=True)

    colors = {
        "implementation_drift": (220, 100, 100),
        "design_flaw": (100, 100, 220),
        "mixed": (100, 220, 100),
        "uncertain": (200, 200, 100),
    }
    (fixture_dir / "screenshot.png").write_bytes(
        minimal_png(color=colors.get(attribution_class, (200, 200, 200)))
    )

    manifest = {
        "fixture_id": fixture_dir.name,
        "attribution_class": attribution_class,
        "attribution_confidence": "medium",
        "description": f"Fixture {idx} for {attribution_class} classification",
        "scores": {
            "whitespace_balance": 3,
            "element_density": 3,
            "visual_hierarchy_legibility": 3,
            "alignment_grid_adherence": 3,
            "intent_match": 3,
        },
        "provenance": "generated",
    }
    (fixture_dir / "design_manifest.json").write_text(json.dumps(manifest, indent=2))


def main() -> None:
    CORPUS_ROOT.mkdir(parents=True, exist_ok=True)
    total = 0
    for cls in ATTRIBUTION_CLASSES:
        for i in range(1, FIXTURES_PER_CLASS + 1):
            fixture_id = f"{cls.replace('_', '-')}-{i:03d}"
            make_fixture(CORPUS_ROOT / fixture_id, cls, i)
            total += 1
    print(
        f"Generated {total} fixtures ({FIXTURES_PER_CLASS} per class × {len(ATTRIBUTION_CLASSES)} classes)"
    )


if __name__ == "__main__":
    main()
