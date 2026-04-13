# Scale Inference

A deterministic protocol for inferring the expected scale (volume, load, throughput) of a feature before making architecture and implementation decisions. Consumed by brainstorm and implementation-plan workflows.

## Scale Signal Sources

Check these artifacts before performing a web search or asking the user:

| Artifact | What to Look For |
|----------|------------------|
| `.claude/design-notes.md` | Explicit volume statements, domain context, deployment scope |
| `dso-config.conf` | Config keys implying scale (max_agents, rate limits, queue sizes, TTLs) |
| `workflow-config.yaml` / `pyproject.toml` | Dependency choices that imply scale (caching libs, async frameworks) |
| Project README or docs | Stated user population, record counts, request rates |

## Inference Protocol

Execute the following steps in order. Do not skip steps or jump ahead.

**Step 1: Check artifacts.** Read all artifacts listed in the Scale Signal Sources table above. Extract any numeric volume signal or explicit scope statement (e.g., "internal tool, ~20 users", "processes 50K records/day", "single-tenant deployment").

**Step 2: Domain web search.** If Step 1 yields no usable estimate, perform a web search using domain terms from the ticket description and design-notes.md. For example: "NJ unemployment claims annual volume", "US federal agency employee headcount", "average municipal permitting requests per year". Prefer primary sources (agency annual reports, government statistics, official documentation).

**Step 3: Ask the user.** If Step 2 yields no usable estimate, ask the user one targeted, specific question: "What is the expected [metric] volume for this feature?" (e.g., "What is the expected number of permit applications per month?"). Do not ask vague questions like "What scale are you expecting?"

## Usable Estimate Definition

A usable estimate is:

- A numeric order-of-magnitude value (e.g., "~10K records/day", "millions of requests/hour", "fewer than 100 concurrent users"), OR
- An explicit statement that volume is negligible or unbounded (e.g., "config file read once at startup", "internal tool, 5–10 users", "no throughput constraints for this batch job")

If neither condition is satisfied after completing Steps 1 and 2, proceed to Step 3. An ambiguous statement such as "large scale" or "high volume" is not a usable estimate — it requires a numeric qualifier or explicit scope.

## Default Assumption

When no usable estimate is available and the user is not reachable (non-interactive mode): **assume small scale unless evidence found**. Do not apply performance optimizations, caching layers, or high-throughput architectures without a scale estimate. Default to the simplest correct implementation.

This default exists to prevent speculative over-engineering. It is not a license to skip the Inference Protocol — always attempt Steps 1 and 2 before falling back to this assumption.

## Prohibition on Upward Interpolation

Never assume a higher scale than the evidence supports. If the only evidence is "this is a government portal", do not extrapolate to "millions of users" — look up the specific agency's reported statistics (Step 2) or ask (Step 3). Upward interpolation without evidence is prohibited regardless of the domain's apparent size.

Examples of prohibited reasoning:
- "Government portals typically handle millions of requests" → NOT a usable estimate; find the specific agency's data.
- "This is an e-commerce platform so it must handle high traffic" → NOT a usable estimate; find actual or projected transaction volume.
- "Healthcare systems deal with sensitive data so they need enterprise-scale infrastructure" → scale and sensitivity are orthogonal; sensitivity does not imply volume.
