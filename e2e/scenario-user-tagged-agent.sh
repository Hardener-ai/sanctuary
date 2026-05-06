#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

trap 'sanctuary_clean_state >/dev/null 2>&1 || true' EXIT INT

require_binaries "$SANCTUARY_BIN" "$SANCTUARYD_BIN"

log_step "cleaning state"
sanctuary_clean_state

fixture_dir="$E2E_WORK_DIR/user-tagged-fixture"
agent="$fixture_dir/dummy-binary"
protected="$E2E_WORK_DIR/protected-folder"
probe="$protected/probe.txt"
mkdir -p "$fixture_dir" "$protected"

log_step "building fixture agent"
make_fake_agent_binary "$agent"

log_step "tagging fixture binary as agent"
"$SANCTUARY_BIN" agents add "$agent"
"$SANCTUARY_BIN" agents list | tee "$E2E_WORK_DIR/user-tagged-agents-list.txt"
grep -Fq "$agent" "$E2E_WORK_DIR/user-tagged-agents-list.txt"
grep -Fq "User-tagged agents:" "$E2E_WORK_DIR/user-tagged-agents-list.txt"
grep -Fq "Bundled known agents:" "$E2E_WORK_DIR/user-tagged-agents-list.txt"

log_step "protecting fixture folder"
"$SANCTUARY_BIN" protect "$protected"

log_step "starting sanctuaryd"
sanctuary_start

log_step "touching protected folder from tagged fixture agent"
"$agent" write-hold "$probe" &
agent_pid="$!"
wait_with_timeout "$agent_pid" 6

log_step "waiting for audit entry"
wait_for_file_pattern "$SANCTUARY_AUDIT_PATH" "DETECT_ALERT.*protected_folder.*dummy-binary" 6

log_step "audit evidence"
grep -E "DETECT_ALERT.*protected_folder.*dummy-binary" "$SANCTUARY_AUDIT_PATH"

log_step "scenario passed"
