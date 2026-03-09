#!/usr/bin/env bash
# staging-deploy-check.sh
# Mock deploy check script for portability test fixture.
# In a real project this would poll the deployment API and exit:
#   0 = healthy (deploy complete and serving traffic)
#   1 = unhealthy (deploy failed or environment is down)
#   2 = deploying (still in progress, retry later)
#
# This mock always exits 0 (healthy) so tests can verify .sh dispatch.

exit 0
