#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

sim_pid=""
cleanup() {
  if [[ -n "$sim_pid" ]] && kill -0 "$sim_pid" >/dev/null 2>&1; then
    kill -TERM "$sim_pid" >/dev/null 2>&1 || true
    wait "$sim_pid" 2>/dev/null || true
  fi
  sanctuary_clean_state >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

require_binaries "$SANCTUARY_BIN" "$SANCTUARYD_BIN"

log_step "cleaning state"
sanctuary_clean_state

log_step "starting sanctuaryd"
sanctuary_start

log_step "starting menu-bar peer simulator"
"$SANCTUARY_BIN" peer-monitor-simulate --duration 16 --interval 1 --timeout 1 --expect-running \
  > "$E2E_WORK_DIR/peer-monitor-sim.log" 2>&1 &
sim_pid="$!"

wait_for_file_pattern "$E2E_WORK_DIR/peer-monitor-sim.log" "daemon_peer_connected" 6

log_step "simulating unexpected daemon stop"
daemon_pid="$(cat "$E2E_WORK_DIR/sanctuaryd.pid")"
kill -TERM "$daemon_pid" >/dev/null 2>&1 || true
for _ in {1..50}; do
  if ! kill -0 "$daemon_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
rm -f "$E2E_WORK_DIR/sanctuaryd.pid"

wait_for_file_pattern "$E2E_WORK_DIR/peer-monitor-sim.log" "TAMPER_DETECTED peer_unresponsive" 8
wait_for_file_pattern "$SANCTUARY_AUDIT_PATH" '"action":"TAMPER_DETECTED".*"policy":"peer_monitor"' 6

log_step "restarting daemon"
sanctuary_start

if ! wait_for_file_pattern "$E2E_WORK_DIR/peer-monitor-sim.log" "daemon_peer_(restarted|recovered)" 8; then
  printf 'FAIL: peer simulator did not observe daemon recovery\n' >&2
  cat "$E2E_WORK_DIR/peer-monitor-sim.log" >&2
  exit 1
fi

wait_with_timeout "$sim_pid" 20
sim_pid=""

log_step "peer simulator evidence"
cat "$E2E_WORK_DIR/peer-monitor-sim.log"

log_step "audit evidence"
grep -E '"action":"(PEER_CONNECTED|PEER_DISCONNECTED|PEER_RESTARTED|PEER_RECOVERED|TAMPER_DETECTED)"' "$SANCTUARY_AUDIT_PATH"

log_step "peer disconnect tamper scenario passed"
