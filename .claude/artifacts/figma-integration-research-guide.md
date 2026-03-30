# Figma Integration Research Guide

Research compiled 2026-03-29 for epic dso-v558 (Figma integration for human design input).

---

## Part 1: Figma MCP Server & REST API

### 1.1 Figma MCP Server

The official Figma MCP server provides both **read and write** access to Figma designs via the Model Context Protocol.

| Aspect | Remote Server (Recommended) | Desktop Server |
|--------|----------------------------|----------------|
| URL | `https://mcp.figma.com/mcp` | `http://127.0.0.1:3845/mcp` |
| Write to canvas | **Yes** | No |
| Requires Figma Desktop | No | Yes (Dev Mode) |
| Plans | All seats and plans | Dev/Full seat, paid only |

**Sources:**
- [Official developer docs](https://developers.figma.com/docs/figma-mcp-server/)
- [GitHub guide repo](https://github.com/figma/mcp-server-guide) (793 stars)
- [Tools and prompts reference](https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/)
- [Remote server installation](https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/)
- [Blog announcement](https://www.figma.com/blog/introducing-figma-mcp-server/)

**Authentication:** Remote server uses OAuth (no API token needed -- prompts for sign-in on first connection). Desktop server uses local Figma app session.

**Claude Code configuration:**
```bash
# Plugin install (recommended)
claude plugin install figma@claude-plugins-official

# Manual (remote)
claude mcp add --transport http figma https://mcp.figma.com/mcp

# User-scope (project-independent)
claude mcp add --scope user --transport http figma https://mcp.figma.com/mcp
```

#### MCP Read Tools

| Tool | Description |
|------|-------------|
| `get_design_context` | Design context for a selection; generates code (React+Tailwind default, configurable to Vue, HTML+CSS, iOS SwiftUI, etc.) |
| `get_variable_defs` | Variables and styles (colors, spacing, typography tokens) |
| `get_code_connect_map` | Mappings between Figma node IDs and code components |
| `get_screenshot` | Screenshot of the current selection |
| `get_metadata` | Sparse XML of selection (IDs, names, types, positions, sizes) |
| `get_figjam` | FigJam diagrams as XML metadata with screenshots |
| `whoami` | Authenticated user identity, plan, seat type (remote only) |
| `get_code_connect_suggestions` | Detects Figma-to-code component mapping suggestions |
| `search_design_system` | Searches connected design libraries for components, variables, styles |

#### MCP Write Tools

| Tool | Description | Availability |
|------|-------------|-------------|
| `use_figma` | General-purpose: create/edit/delete pages, frames, components, variants, variables, styles, text, images | **Remote only, beta** |
| `generate_figma_design` | Captures live web UI and sends to Figma as editable design layers | Remote only, beta |
| `create_new_file` | Creates blank Figma Design or FigJam file in user's drafts | Remote only |
| `generate_diagram` | Generates FigJam diagrams from Mermaid syntax | Both |
| `add_code_connect_map` | Creates mappings between Figma elements and code components | Both |

**Key insight:** `use_figma` accepts **natural language instructions**, not structured API calls. This is the primary programmatic write path. `generate_figma_design` can capture a running web page and convert it to editable Figma layers.

#### MCP Rate Limits

- Starter/View/Collab seats: **6 tool calls per month** (Tier 1)
- Dev/Full seats on Professional+ plans: per-minute limits matching REST API Tier 1
- Write operations: **currently exempt during beta** (usage-based pricing planned)

### 1.2 Figma REST API

**Base URL:** `https://api.figma.com`
**Auth:** Personal Access Token via `X-Figma-Token` header, or OAuth 2.0 via `Authorization: Bearer`

**Sources:**
- [REST API introduction](https://developers.figma.com/docs/rest-api/)
- [Authentication](https://developers.figma.com/docs/rest-api/authentication/)
- [Rate limits](https://developers.figma.com/docs/rest-api/rate-limits/)
- [API comparison chart](https://developers.figma.com/compare-apis/)
- [OpenAPI spec + TypeScript types](https://github.com/figma/rest-api-spec)

#### Key Read Endpoints

| Endpoint | Description | Tier |
|----------|-------------|------|
| `GET /v1/files/:key` | Full file JSON (all nodes, components, styles) | 1 |
| `GET /v1/files/:key/nodes` | Specific nodes by IDs | 1 |
| `GET /v1/images/:key` | **Render nodes as PNG/JPG/SVG/PDF** | 1 |
| `GET /v1/files/:key/images` | Download URLs for image fills | 2 |
| `GET /v1/files/:key/components` | Published components in a file | 3 |
| `GET /v1/files/:key/variables/local` | Local and used remote variables | 2 |

**Image export example (critical for visual comparison):**
```bash
curl -H "X-Figma-Token: YOUR_TOKEN" \
  "https://api.figma.com/v1/images/FILE_KEY?ids=NODE_ID&format=png&scale=2"
# Response: {"images": {"NODE_ID": "https://figma-alpha-api.s3.us-west-2.amazonaws.com/images/..."}}
```

Parameters: `ids` (required, comma-separated), `scale` (0.01-4), `format` (jpg/png/svg/pdf), `contents_only`, `use_absolute_bounds`.

**Sources:**
- [File endpoints](https://developers.figma.com/docs/rest-api/file-endpoints/)
- [Component endpoints](https://developers.figma.com/docs/rest-api/component-endpoints/)
- [Variables endpoints](https://developers.figma.com/docs/rest-api/variables-endpoints/)
- [Comments endpoints](https://developers.figma.com/docs/rest-api/comments-endpoints/)

#### Write Endpoints (Limited)

The REST API **cannot create or modify design nodes** (frames, shapes, text). Writes are limited to:

| Endpoint | Description | Requirement |
|----------|-------------|-------------|
| `POST /v1/files/:key/variables` | Create/update/delete variables and collections | **Enterprise only** |
| `POST /v1/files/:key/comments` | Post comments on designs | Any plan |
| `POST /v1/dev_resources` | Link code artifacts to Figma nodes | Any plan |
| `POST /v2/webhooks` | Create webhooks for change notifications | Any plan |

**Sources:**
- [Dev resources endpoints](https://developers.figma.com/docs/rest-api/dev-resources-endpoints/)
- [Webhooks endpoints](https://developers.figma.com/docs/rest-api/webhooks-endpoints/)

#### REST API Rate Limits (leaky bucket)

| Tier | Dev/Full (Starter) | Dev/Full (Professional) | Dev/Full (Organization) | View/Collab |
|------|-------------------|------------------------|------------------------|-------------|
| 1 | 10/min | 15/min | 20/min | 6/month |
| 2 | 25/min | 50/min | 100/min | 5/min |
| 3 | 50/min | 100/min | 150/min | 10/min |

### 1.3 API Comparison

| Capability | Plugin API | REST API | MCP Server |
|-----------|-----------|----------|------------|
| Create/modify canvas nodes | **Yes (full)** | No | **Yes (`use_figma`, beta)** |
| Read file data | Current file only | Any file | Any file |
| Requires Figma open | Yes | No | No (remote) |
| Write variables | Yes | Enterprise only | Yes (`use_figma`) |
| Write comments | No | Yes | No |
| Webhooks | No | Yes | No |

**Key insight:** The MCP `use_figma` tool is the only **remote, headless** write path for canvas content. The Plugin API requires Figma Desktop running. The REST API cannot write canvas content at all.

---

## Part 2: GitHub Integration Patterns

### 2.1 Push: Code to Figma

| Project | Stars | API Used | Pattern | Status |
|---------|-------|----------|---------|--------|
| [react-figma](https://github.com/react-figma/react-figma) | 2.7k | Plugin API | React renderer for Figma -- write React, renders as Figma nodes | Active, requires Figma Desktop |
| [figma-mcp-write-server](https://github.com/oO/figma-mcp-write-server) | 21 | Plugin API via WebSocket | MCP server with full write via plugin bridge | Active, requires Figma Desktop |
| [Figma Official MCP](https://github.com/figma/mcp-server-guide) | 793 | MCP remote | `use_figma` + `generate_figma_design` write tools | **Beta, remote/headless** |
| [BuilderIO/figma-html](https://github.com/BuilderIO/figma-html) | 3.6k | Plugin API | HTML/website to Figma design conversion | Deprecated, moved to proprietary |

### 2.2 Pull: Figma to Code

| Project | Stars | API Used | Pattern | Status |
|---------|-------|----------|---------|--------|
| [Figma-Context-MCP (Framelink)](https://github.com/GLips/Figma-Context-MCP) | 14k | REST API | Simplifies Figma API responses for AI code gen | Active, read-only |
| [FigmaToCode](https://github.com/bernaferrari/FigmaToCode) | 4.8k | Plugin API | Generates React/Svelte/Flutter/SwiftUI from Figma | Active |
| [figma/code-connect](https://github.com/figma/code-connect) | 1.4k | GitHub + Dev Mode | Maps Figma components to code implementations | Official, active |

### 2.3 Bidirectional: Design Tokens

| Project | Stars | API Used | Pattern | Status |
|---------|-------|----------|---------|--------|
| [Tokens Studio](https://github.com/tokens-studio/figma-plugin) | 1.6k | Plugin API + GitHub | Token JSON in GitHub, push/pull PRs, bidirectional sync | Very active (v2.11.3, Mar 2026) |
| [figma/variables-github-action-example](https://github.com/figma/variables-github-action-example) | 187 | Variables REST API | GitHub Actions workflows for Figma Variables sync | Official, **Enterprise only** |
| [lukasoppermann/design-tokens](https://github.com/lukasoppermann/design-tokens) | 1.1k | Plugin API | Export tokens to JSON (Style Dictionary / W3C format) | Maintained, bugfixes only |

### 2.4 Visual Regression: Figma vs Implementation

| Project | Stars | Pattern | Status |
|---------|-------|---------|--------|
| [uimatch](https://github.com/kosaki08/uimatch) | 4 | Figma frame PNG + Playwright screenshot + pixelmatch + deltaE2000 color + Design Fidelity Score (0-100) | **Experimental but architecturally relevant** |
| [Chromatic](https://www.chromatic.com/) | N/A | Storybook screenshot comparison, Figma plugin for side-by-side | Commercial, mature |

**uimatch architecture (relevant to our validation step):**
1. Fetches Figma frame as PNG via REST API `GET /v1/images/:key`
2. Screenshots implementation via Playwright
3. Runs content-aware pixelmatch + deltaE2000 color analysis + structural scoring
4. Produces Design Fidelity Score (0-100)
5. CLI tool that can gate CI pipelines
6. Uses "selector-anchors" for refactor-resistant element targeting

### 2.5 Key Architectural Takeaways

1. **The REST API cannot write design nodes.** Every "push to Figma" solution uses either the Plugin API (requires Figma Desktop) or the MCP server (remote, beta).
2. **The MCP server is the inflection point.** The `use_figma` write tool (launched March 2026) is the first remote write path without Figma Desktop.
3. **Design tokens have the most mature bidirectional story.** Tokens Studio + GitHub sync provides well-tested push/pull for tokens specifically.
4. **Visual regression against Figma is nascent.** uimatch is the only dedicated open-source tool; most teams use Chromatic/Percy without direct Figma comparison.

---

## Part 3: Alternatives to Figma

### 3.1 Penpot (Strongest Alternative)

- **URL:** https://penpot.app / https://github.com/penpot/penpot (39k+ stars)
- **License:** AGPL-3.0, self-hostable, free cloud tier
- **MCP Servers:**
  - [Official](https://github.com/penpot/penpot-mcp): WebSocket bridge between MCP server and Penpot plugin
  - [Community (zcube)](https://github.com/zcube/penpot-mcp-server): **76+ tools** across 11 categories (shape creation, component system, export, search, etc.)
- **Push/Pull:** AI creates via MCP, human edits in browser, AI reads back via MCP
- **Export:** SVG, PNG, JPG, PDF
- **Pros:** Open-source, self-hosted, web standards (SVG/CSS/HTML), no per-seat licensing, no vendor lock-in
- **Cons:** REST API is immature/poorly documented; MCP is the practical path. Smaller ecosystem than Figma.
- **Cost:** Self-hosted free. Cloud enterprise $950/month (no seat limits).

**Sources:**
- [Penpot Plugin API](https://help.penpot.app/plugins/api/)
- [Penpot MCP experimentation (Smashing Magazine)](https://www.smashingmagazine.com/2026/01/penpot-experimenting-mcp-servers-ai-powered-design-workflows/)

### 3.2 OpenPencil (Emerging -- Watch)

- **URL:** https://openpencil.dev / https://github.com/open-pencil/open-pencil (3.6k stars)
- **License:** Open source (MIT-friendly)
- **MCP:** 90 tools (87 core + 3 file management), stdio and HTTP transports
- **Headless CLI:** `open-pencil tree | find | export | analyze | eval` -- fully autonomous AI workflows
- **Figma compatibility:** Reads/writes `.fig` files natively (194 schema definitions)
- **Pros:** Headless CLI, 90-tool MCP, Figma file compat, P2P collab via WebRTC
- **Cons:** **"Not ready for production use"** per project disclaimer. Very new (early 2026).

### 3.3 Sketch

- **URL:** https://www.sketch.com / https://developer.sketch.com
- **MCP:** Official -- `get_selection_as_image` + `run_code` (full SketchAPI access)
- **Pros:** Mature, JSON file format, full write via MCP `run_code`
- **Cons:** **macOS only** for editing. Closed source. No self-hosting.
- **Cost:** $10-12/editor/month

**Source:** [Sketch MCP Server docs](https://www.sketch.com/docs/mcp-server/)

### 3.4 Framer

- **URL:** https://www.framer.com / https://www.framer.com/developers/
- **Server API:** WebSocket-based, truly headless (no GUI needed for writes). Creates frames, text, components, SVG, images.
- **MCP:** Official plugin in Framer Marketplace
- **Pros:** Headless Server API, React code export, free during beta
- **Cons:** **Website builder, not general UI design tool.** Not for mobile apps or complex application UIs.
- **Cost:** Free plan (limited). Paid $5-25/month per site.

**Source:** [Framer Server API](https://www.framer.com/updates/server-api)

### 3.5 Complementary Tools (Not Replacements)

| Tool | Role | Why Relevant |
|------|------|-------------|
| [Storybook MCP](https://storybook.js.org/addons/@storybook/addon-mcp) | Implementation review surface | Component metadata + self-healing iteration loop. Verifies AI code matches designs. |
| [Excalidraw](https://github.com/excalidraw/excalidraw) (80k+ stars) | Quick wireframes/diagrams | Hand-drawn aesthetic, not for high-fidelity UI. Multiple MCP servers available. |

### 3.6 Not Recommended

| Tool | Reason |
|------|--------|
| Adobe XD | Discontinued (maintenance mode only). Adobe directing users to Figma. |
| Plasmic | Write API is **enterprise-only** -- blocks core push workflow. |
| Builder.io | Visual CMS, not a design tool. |

### 3.7 Comparison Matrix

| Tool | Programmatic Write | Human Edit | Programmatic Read | Image Export | MCP Server | Self-Host | Open Source |
|---|---|---|---|---|---|---|---|
| **Figma** | Yes (MCP `use_figma`, beta) | Yes (browser) | Yes (MCP + REST) | Yes (REST API) | Official | No | No |
| **Penpot** | Yes (MCP 76+ tools) | Yes (browser) | Yes (MCP) | Yes (PNG/JPG/SVG/PDF) | Official + Community | **Yes** | **AGPL-3.0** |
| **OpenPencil** | Yes (MCP 90 tools + CLI) | Yes (browser) | Yes (MCP + CLI) | Yes (PNG/JPG/SVG/JSX) | Built-in | **Yes** | **Open source** |
| **Sketch** | Yes (MCP `run_code`) | macOS only | Yes (MCP + JSON) | Yes (SVG/PNG) | Official | No | No |
| **Framer** | Yes (Server API + MCP) | Yes (browser) | Yes (API) | Limited | Official | No | No |

---

## Part 4: Recommended Integration Architecture

Based on this research, the recommended approach for DSO's push/pull workflow:

### Primary Path: Figma MCP (Remote Server)

```
DSO design-wireframe produces spatial-layout.json + SVG + tokens.md
    |
    v
MCP `use_figma` — push design to Figma as editable frames/components
    |
    v
Human designer reviews and revises in Figma (browser)
    |
    v
MCP `get_design_context` + `get_metadata` — pull revised design back
    |
    v
DSO updates planning/implementation tasks with revised design
    |
    v
DSO implements the design autonomously
    |
    v
Playwright captures implementation screenshots
REST API `GET /v1/images/:key` exports Figma frames as PNG
Perceptual diff (pixelmatch / deltaE2000) produces Design Fidelity Score
    |
    v
Gate: score >= threshold → pass; below → flag for review
```

### Fallback Consideration: Penpot

If Figma MCP write-to-canvas exits beta with restrictive pricing, or if projects need self-hosted/open-source design tooling, Penpot's community MCP server (76+ tools) provides the same push/pull workflow without vendor lock-in.

### Design-Tool-Agnostic Architecture

The DSO integration should be designed as an **adapter layer** so the specific design tool is swappable:

```
DSO Skills (design-wireframe, design-review)
    |
    v
Design Tool Adapter Interface
    |-- FigmaMCPAdapter (use_figma, get_design_context, REST image export)
    |-- PenpotMCPAdapter (zcube MCP tools, export)
    |-- (future adapters)
    |
    v
Config: design.tool=figma | design.tool=penpot (in dso-config.conf)
```
