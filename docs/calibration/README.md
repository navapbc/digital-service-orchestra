# Calibration Program Setup

## Overview

The DSO calibration program tracks code quality health over time via three persistent tracking tickets. These tickets accumulate rollup data as comments, enabling trend analysis and health reporting.

## One-Time Bootstrap

Before enabling the calibration-rollup GitHub Actions workflow, run the bootstrap script to create the three calibration tracking tickets:

```bash
.claude/scripts/dso-bootstrap-calibration-tickets.sh
```

This script is idempotent — safe to run multiple times. It creates the following tracking tickets if they do not exist:

- `calibration-program-health` — monthly/quarterly health rollups produced by `calibration-report.sh monthly` and `calibration-report.sh quarterly`
- `mutation-history` — per-CI-run mutation score accumulation via `calibration-report.sh mutation-append`
- `suite-churn-history` — per-CI-run suite churn accumulation via `calibration-report.sh churn-append`

Once the tickets exist, the calibration-rollup workflow will run successfully on first invocation.

If the tickets are accidentally deleted, re-run the bootstrap script to recreate them — the rollup workflow will resume accumulation from the next run forward.

## Preflight Integration (calibration-rollup.yml)

The calibration-rollup GitHub Actions workflow (implemented in story 9713-09ca) invokes this bootstrap script as a preflight step to ensure tracking tickets exist before attempting rollup operations. This prevents the workflow from failing on first run with a "ticket not found" error.

## Tracking Ticket Schema

Each tracking ticket accumulates data as ticket comments in a structured format. The `calibration-report.sh` script appends one comment per run and reads the comment history for trend analysis. The tickets are long-lived and should not be closed — they serve as append-only data stores.
