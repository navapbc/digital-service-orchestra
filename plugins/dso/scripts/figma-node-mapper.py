#!/usr/bin/env python3
"""Thin wrapper — delegates to figma_node_mapper (underscore module name).

The canonical implementation is figma_node_mapper.py. This file exists for
scripts that call 'python3 figma-node-mapper.py ...' (dash naming convention).
"""

import sys
from pathlib import Path

# Add scripts directory to path so the underscore-named module is importable
sys.path.insert(0, str(Path(__file__).parent))

from figma_node_mapper import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
