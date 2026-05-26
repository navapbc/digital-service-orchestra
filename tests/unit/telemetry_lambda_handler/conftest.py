import sys
import pathlib

# Source package lives under plugins/dso/scripts/telemetry/lambda-handler.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(_REPO_ROOT / "plugins" / "dso" / "scripts" / "telemetry" / "lambda-handler"))
