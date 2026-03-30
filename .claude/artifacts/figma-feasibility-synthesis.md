# Figma Integration Feasibility Synthesis

Research completed 2026-03-30. Consolidates findings from 5 parallel research agents investigating push/pull mechanisms after the `generate_figma_design` blocker was discovered.

---

## The Feasibility Map

### PUSH: Getting Designs INTO Figma

| Method | Autonomous? | Browser Required? | Auth | Fidelity | Status |
|--------|------------|-------------------|------|----------|--------|
| `use_figma` (MCP remote) | **Yes** | No | OAuth (one-time browser) | Native Figma elements | Beta, 20KB/call, no images |
| `generate_figma_design` (MCP) | **No** | Yes + human click | OAuth | Pixel-perfect capture | Interactive only — NOT viable |
| Plugin API via WebSocket bridge | Semi | Figma Desktop open | Plugin auth (6-char code) | Full Plugin API | Mature (figma-console-mcp, 91+ tools) |
| Generate .sketch file → user imports | No (user step) | No | None | Good (styles lost) | Fully programmatic, well-documented format |
| Generate SVG → user imports | No (user step) | No | None | Good for wireframes | Groups/IDs preserved on import |
| Generate HTML → html.to.design plugin | No (user step) | Yes (Chrome ext) | None | Good (auto-layout detected) | Popular plugin, proven pattern |
| REST API | N/A | N/A | N/A | N/A | **Cannot write design nodes — hard limit** |

### PULL: Getting Designs OUT OF Figma

| Method | Autonomous? | Auth | Data Quality | Rate Limits |
|--------|------------|------|-------------|-------------|
| REST API `GET /v1/files/:key` | **Yes** | PAT (simple) | Full JSON node tree: positions, sizes, fills, strokes, text, components, hierarchy | 10-20/min Dev/Full |
| REST API `GET /v1/images/:key` | **Yes** | PAT | PNG/SVG/PDF export of any node | 10-20/min Dev/Full |
| MCP `get_design_context` | Yes | OAuth (problematic) | React+Tailwind structured code output | Tier 1 limits |
| MCP `get_metadata` | Yes | OAuth (problematic) | Sparse XML: IDs, names, types, positions | Tier 1 limits |
| MCP `get_variable_defs` | Yes | OAuth (problematic) | Design tokens (colors, spacing, typography) | Tier 1 limits |
| Framelink community MCP | **Yes** | PAT (simple) | Simplified layout/styling JSON for AI consumption | REST API limits |
| Figma export plugins (user-initiated) | No (user step) | None | JSON, W3C design tokens, PNG/SVG | None |

### AUTH: The Two Worlds

| Mechanism | Supports PAT? | Headless? | Token TTL | Refresh Works? |
|-----------|--------------|-----------|-----------|----------------|
| Official MCP remote server | **No** — OAuth only | No (one-time browser) | 90 days | **Broken** in Claude Code (#21333) |
| REST API | **Yes** | **Yes** | Configurable (max 90 days) | N/A (PAT is static) |
| Framelink community MCP | **Yes** (REST API backend) | **Yes** | Same as REST API PAT | N/A |
| Plugin bridge (figma-console-mcp) | 6-char code | No (Figma Desktop required) | Session-length | N/A |

---

## Key Conclusions

### 1. `use_figma` is the viable autonomous push path

Unlike `generate_figma_design` (which requires a human clicking a capture toolbar in a browser), `use_figma` writes native Figma structure via the MCP remote server with **no browser required** after initial OAuth setup. It can create frames, components, text, auto-layout, variables, and styles programmatically.

**Limitations:** 20KB response limit per call, no image/asset support, custom fonts unsupported, beta quality. The 20KB limit means complex designs may need multiple `use_figma` calls to build incrementally.

### 2. REST API with PAT is the strongest pull path

The REST API returns a complete JSON document tree (`GET /v1/files/:key`) with every node's properties: positions, sizes, fills, strokes, text content, component hierarchy, auto-layout, and variables. It authenticates via simple PAT (no OAuth complexity), works fully headless, and has reasonable rate limits for Dev/Full seats.

This avoids the OAuth/MCP auth issues entirely for the pull side.

### 3. The auth split: OAuth for push, PAT for pull

The cleanest architecture uses TWO auth mechanisms:
- **Push:** Official MCP server with OAuth (one-time browser auth, 90-day token — user re-auths when it expires)
- **Pull:** REST API with PAT (configured in dso-config.conf, fully headless, no refresh issues)

This is viable because push is user-triggered (the user is present to handle OAuth) and pull is the automated re-sync step (needs to work headlessly).

### 4. Fallback push paths exist for restricted environments

If OAuth/MCP is not available (air-gapped, no Full seat, etc.):
- **Tier 2 push:** Agent generates a .sketch file (via `sketch-constructor`) or structured SVG; user imports into Figma manually
- **Tier 3 push:** Agent generates HTML wireframe; user runs html.to.design Figma plugin

These require a user step but need zero API tokens or MCP configuration.

### 5. The .sketch file path is surprisingly strong

The Sketch format is fully documented (JSON in a ZIP), has official libraries (`sketch-constructor` by Amazon, `@sketch-hq/sketch-file-format`), and Figma imports .sketch natively. An agent can generate a .sketch file programmatically with component hierarchy, text, colors, auto-layout — and the user drags it into Figma. No API tokens, no OAuth, no rate limits. Styles are lost on import but structure is preserved.

---

## Revised Approach Options

### Option A: MCP Push (`use_figma`) + REST API Pull (Recommended)

```
PUSH: Agent → use_figma (MCP, OAuth) → native Figma elements
PULL: Agent → REST API GET /v1/files/:key (PAT) → full JSON node tree
VALIDATE: REST API GET /v1/images/:key (PAT) → PNG + Playwright → perceptual diff
```

- Fully autonomous after one-time OAuth setup
- Strongest pull fidelity (complete JSON tree)
- No browser needed during workflow (only for initial OAuth)
- Auth split: OAuth for MCP push, PAT for REST pull/validate

### Option B: Artifact Exchange (No API Required)

```
PUSH: Agent → generates .sketch file or structured SVG → user imports to Figma
PULL: User → exports JSON via Figma plugin (or REST API with PAT) → agent reads
VALIDATE: REST API GET /v1/images/:key (PAT) → PNG + Playwright → perceptual diff
```

- Works in air-gapped/restricted environments
- No MCP server, no OAuth, no Full seat requirement
- Requires user step for push (drag file into Figma)
- .sketch format preserves component hierarchy; SVG preserves groups/IDs

### Option C: Hybrid (MCP with Artifact Fallback)

```
IF MCP available:
  PUSH: use_figma (MCP, OAuth)
  PULL: REST API (PAT)
ELSE:
  PUSH: generate .sketch or SVG → user imports
  PULL: REST API (PAT) or user exports JSON
VALIDATE: REST API + Playwright (always uses PAT)
```

- Adapter pattern: config flag selects push mechanism
- Degrades gracefully when MCP is unavailable
- REST API pull works in both modes (always available with PAT)
