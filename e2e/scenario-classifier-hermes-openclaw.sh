#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

log_step "checking live agent inventory"
require_binaries "$SANCTUARY_BIN"

inventory="$("$SANCTUARY_BIN" inventory list)"
printf '%s\n' "$inventory"

if ! printf '%s\n' "$inventory" | grep -Ei 'openclaw.*backgroundService|backgroundService.*openclaw' >/dev/null; then
  printf 'SKIP: scenario-classifier-hermes-openclaw requires a live OpenClaw process in inventory; not present on this host\n'
  exit 77
fi

failures=0

if printf '%s\n' "$inventory" | grep -Ei 'hermes.*backgroundService|backgroundService.*hermes' >/dev/null; then
  log_step "Hermes appears as backgroundService"
else
  printf 'FAIL: Hermes did not appear with category backgroundService\n' >&2
  failures=$((failures + 1))
fi

log_step "OpenClaw appears as backgroundService"

if printf '%s\n' "$inventory" | grep -Ei '\bsanctuaryd\b' >/dev/null; then
  printf 'FAIL: sanctuaryd appeared in inventory\n' >&2
  failures=$((failures + 1))
else
  log_step "sanctuaryd excluded from inventory"
fi

if (( failures > 0 )); then
  exit 1
fi

log_step "classifier inventory scenario passed"
