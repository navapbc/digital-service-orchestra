---
id: w21-zbx7
status: open
deps: [w21-99wp]
links: []
created: 2026-03-22T01:00:04Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-gykt
---
# Create inbound-bridge.yml GitHub Actions scheduled workflow

Create .github/workflows/inbound-bridge.yml that runs bridge-inbound.py on a configurable schedule to pull Jira changes into the local ticket system.

FILE: .github/workflows/inbound-bridge.yml (new file)

REQUIREMENTS based on epic SC1, SC2, SC9 and the outbound-bridge.yml pattern:

Trigger:
  schedule: - cron: '${{ vars.INBOUND_BRIDGE_CRON || "*/15 * * * *" }}'  # default every 15 min
  workflow_dispatch: {}  # manual trigger for testing

Concurrency:
  group: jira-bridge  # SAME group as outbound-bridge — serializes all bridge runs
  cancel-in-progress: false

Jobs:
  bridge:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - Checkout (fetch-depth: 1)
      - Set up Python 3.x
      - Cache ACLI jar (same pattern as outbound-bridge.yml: key acli-${{ runner.os }}-${{ vars.ACLI_VERSION }})
      - Validate ACLI version before download (reject unset or latest — same guard as outbound)
      - Download ACLI (same dual-URL pattern)
      - Verify ACLI checksum (same SHA256 guard)
      - Extract ACLI zip (same pattern)
      - Add ACLI to PATH (same wrapper script)
      - Run inbound bridge:
          run: python3 plugins/dso/scripts/bridge-inbound.py
          env:
            JIRA_URL, JIRA_USER, JIRA_API_TOKEN (from secrets)
            BRIDGE_ENV_ID (from vars)
            GH_RUN_ID: ${{ github.run_id }}
            INBOUND_CHECKPOINT_PATH: .tickets-tracker/.inbound-checkpoint.json
            INBOUND_OVERLAP_BUFFER_MINUTES: ${{ vars.INBOUND_OVERLAP_BUFFER_MINUTES || 15 }}
            INBOUND_STATUS_MAPPING: ${{ vars.INBOUND_STATUS_MAPPING || '{}' }}
            INBOUND_TYPE_MAPPING: ${{ vars.INBOUND_TYPE_MAPPING || '{}' }}
      - Commit inbound events + checkpoint to tickets branch:
          Check if any changes in .tickets-tracker/; if so, configure bridge bot identity and commit
          git commit -m 'chore: inbound sync from Jira [run ${{ github.run_id }}]'
          git push origin HEAD:tickets
      - Job timing report (always step)

SECURITY: Same ACLI version-pinning and SHA256 verification as outbound-bridge.yml.

DOCUMENTATION: Update .claude/dso-config.conf comments or plugins/dso/docs/CONFIG-RESOLUTION.md to document the new vars:
  INBOUND_BRIDGE_CRON, INBOUND_OVERLAP_BUFFER_MINUTES, INBOUND_STATUS_MAPPING, INBOUND_TYPE_MAPPING

## Acceptance Criteria

- [ ] .github/workflows/inbound-bridge.yml exists
  Verify: test -f $(git rev-parse --show-toplevel)/.github/workflows/inbound-bridge.yml
- [ ] Workflow has schedule trigger
  Verify: grep -q 'schedule:' $(git rev-parse --show-toplevel)/.github/workflows/inbound-bridge.yml
- [ ] Workflow uses concurrency group jira-bridge (same as outbound)
  Verify: grep -q 'group: jira-bridge' $(git rev-parse --show-toplevel)/.github/workflows/inbound-bridge.yml
- [ ] ACLI checksum verification step present
  Verify: grep -q 'sha256sum' $(git rev-parse --show-toplevel)/.github/workflows/inbound-bridge.yml
- [ ] Workflow uses BRIDGE_BOT identity for commits (echo prevention)
  Verify: grep -q 'BRIDGE_BOT_NAME' $(git rev-parse --show-toplevel)/.github/workflows/inbound-bridge.yml
- [ ] ruff check passes on bridge-inbound.py (no regressions)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/bridge-inbound.py

