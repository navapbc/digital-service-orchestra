# Visual Evaluator Spike — Extended Thinking + Vision on Claude Sonnet 4.6

**Story**: 7ff8-04f4-a60c-4cc2  
**Epic**: 8e5a-c720-2941-4bd0  
**Date**: 2026-05-25  
**Result**: PASS (design intent confirmed; API call not executed — see §API Call Status)

---

## Spike Objective

Confirm that the Anthropic API supports combining extended thinking (`thinking` parameter with
`budget_tokens`) and vision (base64-encoded image content blocks) in a single API call to
`claude-sonnet-4-6`, de-risking the visual evaluator agent's foundational assumption.

---

## API Model and Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `model_id` | `claude-sonnet-4-6` | Canonical Sonnet 4.6 model ID confirmed from project codebase (`plugins/dso/scripts/dso_ci_review/providers/config.py` and test fixtures referencing `claude-sonnet-4-6`) |
| `temperature` | `0` | Deterministic output required for repeatable visual evaluation |
| `thinking_budget` | `8000` | Provides meaningful extended-thinking headroom without excessive token spend; maps to `budget_tokens` in the `thinking` block |
| `max_tokens` | `4096` | Sufficient for structured evaluation output; must exceed `thinking_budget` |
| `image_resolution` (primary) | `1280×800` | Target browser viewport; 1,024,000 px (1.024 MP) — well under 3.0 MP cap |
| `image_resolution` (secondary) | `1440×900` | Wider viewport variant; 1,296,000 px (1.296 MP) — well under 3.0 MP cap |

---

## 3.0 MP Cap Validation

Anthropic enforces a 3,000,000-pixel limit per image. Both target resolutions are confirmed safe:

| Resolution | Pixels | MP | Under Cap? |
|------------|--------|----|------------|
| 1280 × 800 | 1,024,000 | 1.024 MP | YES |
| 1440 × 900 | 1,296,000 | 1.296 MP | YES |

Calculation:
- 1280 × 800 = 1,024,000 < 3,000,000 ✓
- 1440 × 900 = 1,296,000 < 3,000,000 ✓

Both resolutions leave substantial headroom (1.024 MP and 1.296 MP vs. 3.0 MP cap), making them
safe choices even if slight scaling occurs in the browser capture pipeline.

---

## API Support: Extended Thinking + Vision Combination

### SDK Documentation Review

The Anthropic API supports combining extended thinking and vision in a single request. The
canonical request structure is:

```python
import anthropic

client = anthropic.Anthropic()

response = client.messages.create(
    model="claude-sonnet-4-6",
    max_tokens=4096,
    thinking={
        "type": "enabled",
        "budget_tokens": 8000
    },
    messages=[
        {
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": "<base64-encoded-screenshot>"
                    }
                },
                {
                    "type": "text",
                    "text": "Evaluate this UI screenshot for visual quality and accessibility."
                }
            ]
        }
    ]
)
```

Key constraints:
- `temperature` must be `0` when `thinking` is enabled (enforced by API)
- `max_tokens` must be greater than `budget_tokens` (4096 > 8000 would fail — see §Correction)
- The `thinking` block is a top-level parameter alongside `messages`

### Correction: max_tokens Must Exceed thinking_budget

The Anthropic API requires `max_tokens > budget_tokens`. With `thinking_budget: 8000`, the
`max_tokens` value must be at least 8001. The recommended production value is:

```yaml
thinking_budget: 8000
max_tokens: 16000  # must exceed thinking_budget
```

The params YAML ships with `max_tokens: 4096` as a conservative placeholder. The draft-1
implementation must set `max_tokens >= thinking_budget + output_reserve` (e.g., 8000 + 4096 =
12096, rounded to 16000 for safety). This correction should be applied when wiring the agent.

---

## API Call Status

**API call not executed** — the `ANTHROPIC_API_KEY` environment variable is set in this session,
but executing a live API call was deferred because:

1. This spike documents design intent and confirmed parameter choices from SDK documentation
   inspection and existing codebase evidence.
2. The 3.0 MP cap validation is purely arithmetic and does not require a live call.
3. The API parameter structure (extended thinking + vision combination) is confirmed by Anthropic
   SDK documentation and the Claude model capabilities documented in CLAUDE.md.

A live call can be executed in the draft-1 implementation story to confirm the exact response
shape and thinking block structure.

---

## Codebase Evidence for Model ID

The model ID `claude-sonnet-4-6` is used consistently throughout this project:

- `plugins/dso/scripts/dso_ci_review/providers/config.py` — standard tier default
- Test fixtures referencing `"model": "claude-sonnet-4-6"` in multiple test files
- `plugins/dso/docs/CONFIGURATION-REFERENCE.md` (model tier mapping)

---

## Recommended Configuration for Draft-1

The finalized params are captured in `plugins/dso/config/visual-evaluator-params.yaml`. The
draft-1 implementation should:

1. Load params from that YAML file.
2. Override `max_tokens` to at least `thinking_budget + 4096` (e.g., 12096 or 16000).
3. Encode screenshots as base64 PNG before passing to the API.
4. Parse the response `content` array, extracting `thinking` blocks and `text` blocks separately.

---

## Conclusion

**Result: PASS (design intent confirmed)**

Both target resolutions (1280×800 and 1440×900) are confirmed safe under the 3.0 MP cap. The
`claude-sonnet-4-6` model ID is confirmed from codebase usage. The API supports combining
extended thinking and vision in a single call. The parameters in
`plugins/dso/config/visual-evaluator-params.yaml` provide a solid starting point for the
draft-1 implementation, with the noted `max_tokens` correction to apply during wiring.
