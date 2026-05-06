#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
e2e_dir="$root/e2e"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
results_path="${E2E_RESULTS_PATH:-$e2e_dir/results-$timestamp.md}"
export E2E_WORK_DIR="${E2E_WORK_DIR:-/tmp/sanctuary-e2e-$timestamp}"

scenarios=(
  "scenario-classifier-hermes-openclaw.sh"
  "scenario-fs-detection-ssh.sh"
  "scenario-extension-storage-metamask.sh"
  "scenario-cdp-guard-blocks.sh"
  "scenario-user-tagged-agent.sh"
  "scenario-tamper-evident-audit.sh"
  "scenario-tamper-peer-disconnect.sh"
  "scenario-tamper-pf-flush.sh"
)

passed=0
failed=0
skipped=0

{
  printf '# Sanctuary e2e results — %s\n\n' "$timestamp"
  printf 'Repository: `%s`\n\n' "$root"
} > "$results_path"

for scenario in "${scenarios[@]}"; do
  script="$e2e_dir/$scenario"
  output="$(mktemp "/tmp/sanctuary-e2e-$scenario.XXXXXX")"
  started="$(date +%s)"
  status="PASS"
  exit_code=0

  if bash "$script" > "$output" 2>&1; then
    status="PASS"
    passed=$((passed + 1))
  else
    exit_code=$?
    if [[ "$exit_code" == "77" ]]; then
      status="SKIP"
      skipped=$((skipped + 1))
    else
      status="FAIL"
      failed=$((failed + 1))
    fi
  fi

  ended="$(date +%s)"
  duration=$((ended - started))
  {
    printf '## %s\n\n' "$scenario"
    printf 'Status: %s\n\n' "$status"
    printf 'Duration: %ss\n\n' "$duration"
    printf 'Evidence:\n\n'
    printf '```text\n'
    cat "$output"
    printf '```\n\n'
  } >> "$results_path"
  rm -f "$output"
done

{
  printf '## Summary\n\n'
  printf 'Passed: %s\n\n' "$passed"
  printf 'Failed: %s\n\n' "$failed"
  printf 'Skipped: %s\n' "$skipped"
} >> "$results_path"

cat "$results_path"

if (( failed > 0 )); then
  exit 1
fi
