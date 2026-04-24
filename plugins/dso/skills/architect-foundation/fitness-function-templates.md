# Fitness Function Templates (Architect-Foundation)

Concrete enforcement templates per AP code and per stack. Referenced from `/dso:architect-foundation` Phase 3 Step 1. Load only when generating enforcement artifacts.

Each template includes: (a) the test/check file to write, (b) the anti-pattern it targets, (c) the wiring step that registers it.

## AP-3: Variant registry completeness

### Python (pytest)

```python
# tests/architecture/test_variant_registry.py
from myapp.handlers import OutputFormat, HANDLERS

def test_every_format_has_a_handler():
    missing = set(OutputFormat) - set(HANDLERS.keys())
    assert not missing, f"OutputFormat values without handlers: {missing}"
```

### Node (jest)

```javascript
// tests/architecture/variant-registry.test.js
import { OutputFormat, HANDLERS } from '../../src/handlers';

test('every OutputFormat has a handler', () => {
  const missing = Object.values(OutputFormat).filter(v => !(v in HANDLERS));
  expect(missing).toEqual([]);
});
```

**Wiring**: Test runs on every CI invocation of the test suite. No extra hook needed.

---

## AP-5: Config bypass (no raw env reads outside config module)

### Python

```python
# tests/architecture/test_config_boundary.py
import subprocess, pathlib

def test_no_raw_env_reads_outside_config_module():
    root = pathlib.Path(__file__).resolve().parents[2]
    result = subprocess.run(
        ["grep", "-rn", "--include=*.py",
         "-e", r"os\.getenv", "-e", r"os\.environ\[",
         str(root / "src")],
        capture_output=True, text=True,
    )
    offenders = [
        line for line in result.stdout.splitlines()
        if "/config/" not in line and "/tests/" not in line
    ]
    assert not offenders, "Raw env reads outside config module:\n" + "\n".join(offenders)
```

### Node

```javascript
// tests/architecture/config-boundary.test.js
import { execSync } from 'child_process';

test('no raw process.env reads outside src/config/', () => {
  const out = execSync(
    "grep -rn --include='*.{js,ts}' -e 'process\\.env' src/ || true",
    { encoding: 'utf8' }
  );
  const offenders = out.split('\n').filter(l => l && !l.includes('src/config/'));
  expect(offenders).toEqual([]);
});
```

**Wiring**: Runs in the normal test suite. Add the `src/config/` allowlist path if the project uses a different location.

---

## AP-1: State immutability (Python example)

```python
# src/pipeline/state.py — replace a mutable dict with a frozen dataclass
from dataclasses import dataclass, replace

@dataclass(frozen=True)
class PipelineState:
    inputs: tuple
    outputs: tuple = ()

    def with_outputs(self, outputs):
        return replace(self, outputs=tuple(outputs))
```

```python
# tests/architecture/test_state_immutability.py
import pytest
from myapp.pipeline.state import PipelineState

def test_state_is_frozen():
    s = PipelineState(inputs=("a",))
    with pytest.raises(Exception):  # FrozenInstanceError
        s.inputs = ("b",)
```

**Wiring**: Architectural code change plus the test above. The test itself is the fitness function.

---

## AP-4: Parallel inheritance (Cartesian-product completeness)

When a variant set grows along two axes (e.g., `{CSV, JSON, XML} × {stream, batch}`), composition-over-inheritance factors the cross-cutting axis into a strategy object. The fitness function asserts the Cartesian product is complete.

### Python (pytest)

```python
# tests/architecture/test_cartesian_completeness.py
from myapp.handlers import OutputFormat, Mode, HANDLERS

def test_every_format_x_mode_has_a_handler():
    missing = [
        (fmt, mode)
        for fmt in OutputFormat
        for mode in Mode
        if (fmt, mode) not in HANDLERS
    ]
    assert not missing, f"Missing (format, mode) handlers: {missing}"
```

### Node (jest)

```javascript
// tests/architecture/cartesian-completeness.test.js
import { OutputFormat, Mode, HANDLERS } from '../../src/handlers';

test('every (format, mode) pair has a handler', () => {
  const missing = [];
  for (const fmt of Object.values(OutputFormat)) {
    for (const mode of Object.values(Mode)) {
      if (!HANDLERS.has(`${fmt}:${mode}`)) missing.push([fmt, mode]);
    }
  }
  expect(missing).toEqual([]);
});
```

**Wiring**: Same as AP-3 — runs in the normal test suite. No extra hook.

---

## AP-2: Abstract error hierarchy

```python
# src/providers/errors.py
class ProviderError(Exception): ...
class RetryableError(ProviderError): ...
class RateLimitedError(RetryableError): ...
class AuthenticationError(ProviderError): ...
class PermanentError(ProviderError): ...
```

```python
# tests/architecture/test_error_hierarchy.py
import inspect, importlib
from myapp.providers import errors

def test_no_sdk_types_leak_through_interface():
    iface = importlib.import_module("myapp.providers.interface")
    src = inspect.getsource(iface)
    # SDK-specific exception types must not appear in the interface layer.
    assert "openai.APIError" not in src
    assert "anthropic.APIError" not in src
```

**Wiring**: The assertion list must be updated when new providers are added. Track additions as a checklist item in `ARCH_ENFORCEMENT.md`.

---

## Layer registration cheat-sheet

| Layer | Where it runs | Registration |
|-------|---------------|--------------|
| Edit-time | IDE / type checker / linter | `ruff.toml`, `eslint.config.js`, `mypy.ini` |
| Test-time | Test suite (fitness functions above) | Files under `tests/architecture/` are picked up by the normal test runner |
| CI-time | Pre-merge gate | `.pre-commit-config.yaml` entry or GitHub Actions step that runs `pytest tests/architecture/` before merge |
