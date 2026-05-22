---
name: dso:test-quality-report
description: Surfaces calibration program health by running the monthly and quarterly calibration reports. Use when checking test-quality calibration trends, reviewing reviewer calibration data, or auditing the calibration program status. Trigger phrases include '/dso:test-quality-report', 'run calibration report', 'show calibration health', 'test quality report'.
user-invocable: true
allowed-tools: Bash, Read
---

# Test Quality Report

Runs the calibration program health reports (monthly and quarterly) and surfaces their outputs.

## Prerequisites

Calibration tracking tickets must exist. If they are absent, create them first:

```bash
bash .claude/scripts/dso-bootstrap-calibration-tickets.sh
```

## Invocation

```
/dso:test-quality-report
```

## Steps

### Step 1: Run Monthly Report

```bash
.claude/scripts/dso calibration-report.sh monthly
```

Surface the full output to the user.

### Step 2: Run Quarterly Report

```bash
.claude/scripts/dso calibration-report.sh quarterly
```

Surface the full output to the user.

### Step 3: Summary

After both reports complete, provide a one-paragraph summary of the calibration program health, highlighting any trends, gaps, or action items surfaced by the reports.
