# UI Discovery Cache — Format Reference

This document defines the JSON schemas for every file in the `.ui-discovery-cache/`
directory. Both the `ui-discover` skill (writes) and the `ui-designer` agent
(reads) depend on these contracts.

---

## Directory Structure

```
.ui-discovery-cache/
├── manifest.json
├── validate-ui-cache.sh
├── global/
│   ├── app-shell.json
│   ├── design-tokens.json
│   └── route-map.json
├── components/
│   ├── _index.json
│   ├── Button.json
│   ├── SearchInput.json
│   └── ...
├── routes/
│   ├── _root.json
│   ├── settings.json
│   ├── users_[id].json
│   └── ...
└── screenshots/
    ├── _root.png
    ├── settings.png
    └── ...
```

### Route Slug Convention

| Route path | Slug |
|------------|------|
| `/` | `_root` |
| `/settings` | `settings` |
| `/users/:id` | `users_[id]` |
| `/dashboard/analytics` | `dashboard_analytics` |

Rule: strip leading `/`, replace `/` with `_`, replace `:param` with `[param]`.
The root path `/` becomes `_root`.

---

## 1. manifest.json — Master Index

The manifest tracks cache metadata, file hashes for invalidation, and a dependency
graph mapping each cache entry to the source files it was derived from.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["version", "generatedAt", "gitCommit", "playwrightUsed", "uiFileHashes", "entries"],
  "properties": {
    "version": {
      "type": "integer",
      "const": 1,
      "description": "Cache format version. Increment on breaking schema changes."
    },
    "generatedAt": {
      "type": "string",
      "format": "date-time",
      "description": "ISO 8601 timestamp of last full or partial generation."
    },
    "gitCommit": {
      "type": "string",
      "description": "Short SHA of the git commit at cache generation time."
    },
    "appUrl": {
      "type": "string",
      "format": "uri",
      "description": "Base URL of the running application when cache was generated. Null if app was not running."
    },
    "playwrightUsed": {
      "type": "boolean",
      "description": "Whether Playwright was available and used for route crawling."
    },
    "uiFileHashes": {
      "type": "object",
      "description": "Map of tracked UI file path to SHA-256 hash at cache generation time.",
      "additionalProperties": {
        "type": "string",
        "pattern": "^sha256:[a-f0-9]{64}$"
      }
    },
    "entries": {
      "type": "object",
      "description": "Map of cache entry key (e.g. 'components/Button', 'routes/settings') to its metadata.",
      "additionalProperties": {
        "$ref": "#/definitions/cacheEntry"
      }
    }
  },
  "definitions": {
    "cacheEntry": {
      "type": "object",
      "required": ["valid", "dependsOn"],
      "properties": {
        "valid": {
          "type": "boolean",
          "description": "Whether this entry is current. Set to false by validation when dependent files change."
        },
        "dependsOn": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Source file paths this entry was derived from. A change to any triggers invalidation."
        },
        "usesComponents": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Component names used by this entry (route entries only). For reverse lookup."
        }
      }
    }
  }
}
```

---

## 2. global/app-shell.json — Application Shell

Describes the persistent layout and navigation structure shared across all pages.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["layoutPattern", "navigation", "sourceFiles"],
  "properties": {
    "layoutPattern": {
      "type": "string",
      "description": "Top-level layout pattern name, e.g. 'TopNav-Sidebar-Main', 'StickyHeader-Main-Footer'."
    },
    "navigation": {
      "type": "object",
      "required": ["type", "items"],
      "properties": {
        "type": {
          "type": "string",
          "enum": ["top-nav", "sidebar", "bottom-tabs", "hamburger", "breadcrumb", "mixed"],
          "description": "Primary navigation pattern."
        },
        "items": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["label", "href"],
            "properties": {
              "label": { "type": "string" },
              "href": { "type": "string" },
              "icon": { "type": "string" },
              "children": {
                "type": "array",
                "items": { "$ref": "#/properties/navigation/properties/items/items" }
              }
            }
          }
        }
      }
    },
    "sharedChrome": {
      "type": "object",
      "description": "Persistent UI elements present on every page.",
      "properties": {
        "header": { "type": "string", "description": "Description of the persistent header." },
        "footer": { "type": "string", "description": "Description of the persistent footer." },
        "sidebar": { "type": "string", "description": "Description of the persistent sidebar, if any." }
      }
    },
    "sourceFiles": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Source files that define the app shell (root layout, nav component, etc.)."
    }
  }
}
```

---

## 3. global/design-tokens.json — Resolved Design Tokens

All theme values resolved to concrete units. Wireframe agents use these directly
without needing to read theme configuration files.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["colors"],
  "properties": {
    "colors": {
      "type": "object",
      "description": "Map of color token name to resolved hex value.",
      "additionalProperties": {
        "type": "string",
        "pattern": "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$"
      }
    },
    "spacing": {
      "type": "object",
      "description": "Map of spacing token name to resolved px value.",
      "additionalProperties": { "type": "string" }
    },
    "typography": {
      "type": "object",
      "description": "Map of typography token name to resolved value (size/line-height, weight).",
      "additionalProperties": { "type": "string" }
    },
    "shadows": {
      "type": "object",
      "description": "Map of shadow token name to resolved CSS box-shadow value.",
      "additionalProperties": { "type": "string" }
    },
    "radii": {
      "type": "object",
      "description": "Map of border-radius token name to resolved px value.",
      "additionalProperties": { "type": "string" }
    }
  }
}
```

---

## 4. global/route-map.json — Route-to-File Mapping

Maps every discovered route to its source file and the components it uses.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["framework", "routes"],
  "properties": {
    "framework": {
      "type": "string",
      "description": "Detected routing framework, e.g. 'next-app-router', 'next-pages', 'sveltekit', 'react-router', 'vue-router'."
    },
    "routes": {
      "type": "object",
      "description": "Map of route path to its source info.",
      "additionalProperties": {
        "type": "object",
        "required": ["sourceFile"],
        "properties": {
          "sourceFile": {
            "type": "string",
            "description": "Path to the page/route source file."
          },
          "components": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Component names imported by this route (direct + 1-2 levels transitive)."
          }
        }
      }
    }
  }
}
```

---

## 5. components/_index.json — Quick Lookup Table

A flat array for fast scanning when an agent needs to answer "do we have a
component for X?".

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "array",
  "items": {
    "type": "object",
    "required": ["name", "path", "purpose"],
    "properties": {
      "name": {
        "type": "string",
        "description": "Component export name."
      },
      "path": {
        "type": "string",
        "description": "Relative file path from project root."
      },
      "variants": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Available variants (from union-type props like 'variant')."
      },
      "purpose": {
        "type": "string",
        "description": "One-line description of what this component does."
      }
    }
  }
}
```

---

## 6. components/\<Name\>.json — Full Component Detail

Deep detail for reuse decisions. One file per component.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["name", "path", "exportType", "props", "purpose"],
  "properties": {
    "name": {
      "type": "string",
      "description": "Component export name."
    },
    "path": {
      "type": "string",
      "description": "Relative file path from project root."
    },
    "exportType": {
      "type": "string",
      "enum": ["named", "default"],
      "description": "Whether the component uses named or default export."
    },
    "props": {
      "type": "object",
      "description": "Map of prop name to its type definition.",
      "additionalProperties": {
        "type": "object",
        "required": ["type"],
        "properties": {
          "type": {
            "type": "string",
            "description": "TypeScript type or description, e.g. \"'primary' | 'secondary'\", \"boolean\", \"ReactNode\"."
          },
          "required": {
            "type": "boolean",
            "default": false
          },
          "default": {
            "type": "string",
            "description": "Default value if any, as a string representation."
          }
        }
      }
    },
    "purpose": {
      "type": "string",
      "description": "One-line description of the component's purpose."
    },
    "usedInRoutes": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Route paths where this component is used."
    },
    "sourceExcerpt": {
      "type": "string",
      "description": "The component's export/function signature line for quick reference."
    },
    "relatedComponents": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Names of closely related components (compositions, extensions, siblings)."
    },
    "designSystemRef": {
      "type": "string",
      "description": "Path in the design system hierarchy, e.g. 'Components/Actions/Button'."
    }
  }
}
```

Schema alignment with the Spatial Layout Tree (`output-format-reference.md`):
- `name` corresponds to the `type` field on component nodes
- `designSystemRef` corresponds to `design_system_ref`
- `props` keys and types match what appears in component node `props` objects

---

## 7. routes/\<slug\>.json — Denormalized Route Snapshot

Self-contained snapshot of a route. A wireframe agent loads a single route file
and has everything it needs about that page — component details are inlined,
not referenced.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["route", "sourceFile", "capturedAt"],
  "properties": {
    "route": {
      "type": "string",
      "description": "The route path, e.g. '/settings'."
    },
    "sourceFile": {
      "type": "string",
      "description": "Path to the page source file."
    },
    "capturedAt": {
      "type": "string",
      "format": "date-time",
      "description": "ISO 8601 timestamp of when this snapshot was captured."
    },
    "playwrightCrawled": {
      "type": "boolean",
      "default": true,
      "description": "Whether Playwright was used to capture live DOM/screenshot for this route."
    },
    "screenshot": {
      "type": "string",
      "description": "Relative path to the screenshot image, e.g. 'screenshots/settings.png'. Null if not captured."
    },
    "layout": {
      "type": "object",
      "properties": {
        "pattern": {
          "type": "string",
          "description": "Layout pattern name, e.g. 'Sidebar-Content', 'Stack'."
        },
        "description": {
          "type": "string",
          "description": "Human-readable layout description with dimensions."
        }
      }
    },
    "dom": {
      "type": "object",
      "description": "DOM summary from Playwright crawl. Null if Playwright was not used.",
      "properties": {
        "summary": {
          "type": "string",
          "description": "Human-readable summary of the page's DOM structure."
        },
        "structure": {
          "type": "array",
          "description": "Top 3 levels of DOM nesting with tags, classes, IDs, ARIA, and text.",
          "items": { "$ref": "#/definitions/domNode" }
        }
      }
    },
    "componentsUsed": {
      "type": "array",
      "description": "Full inline detail for every component used on this route.",
      "items": { "$ref": "#/definitions/routeComponent" }
    },
    "patterns": {
      "type": "object",
      "description": "Observed UI patterns on this route.",
      "properties": {
        "spacing": { "type": "string" },
        "alignment": { "type": "string" },
        "interactiveElements": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    }
  },
  "definitions": {
    "domNode": {
      "type": "object",
      "required": ["tag"],
      "properties": {
        "tag": { "type": "string" },
        "classes": { "type": "array", "items": { "type": "string" } },
        "id": { "type": "string" },
        "ariaRole": { "type": "string" },
        "dataAttributes": { "type": "object", "additionalProperties": { "type": "string" } },
        "text": { "type": "string", "description": "Text content, truncated to 100 chars." },
        "href": { "type": "string" },
        "children": { "type": "array", "items": { "$ref": "#/definitions/domNode" } }
      }
    },
    "routeComponent": {
      "type": "object",
      "required": ["name", "path"],
      "properties": {
        "name": { "type": "string" },
        "path": { "type": "string" },
        "instanceCount": { "type": "integer", "description": "Number of times this component appears on the route." },
        "propsObserved": {
          "type": "object",
          "description": "Prop values observed in the live DOM (from Playwright). Null if static-only.",
          "additionalProperties": { "type": "string" }
        },
        "variants": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Variants observed in use on this route."
        },
        "availableProps": {
          "type": "object",
          "description": "Full prop type map (same as components/<Name>.json props).",
          "additionalProperties": { "type": "string" }
        },
        "purpose": { "type": "string" },
        "designSystemRef": { "type": "string" }
      }
    }
  }
}
```
