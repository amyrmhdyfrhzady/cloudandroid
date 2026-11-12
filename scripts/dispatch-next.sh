#!/usr/bin/env bash
set -euo pipefail
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_REF_NAME:?}"

# workflow_dispatch is one of the events that can start a workflow using GITHUB_TOKEN.
gh workflow run android.yml --repo "$GITHUB_REPOSITORY" --ref "$GITHUB_REF_NAME" -f continuous=true
echo 'Next Cloud Android runner queued.'
