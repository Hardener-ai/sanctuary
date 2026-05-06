#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

probe="$HOME/.ssh/.sanctuary-probe"
fake_bin_dir="$E2E_WORK_DIR/fake-bin"
fake_agent="$fake_bin_dir/codex"
agent_audit="$E2E_WORK_DIR/fs-agent-audit.log"
non_agent_audit="$E2E_WORK_DIR/fs-non-agent-audit.log"

cleanup() {
  rm -f "$probe" "$agent_audit" "$non_agent_audit"
  sanctuary_clean_state >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if [[ ! -d "$HOME/.ssh" ]]; then
  printf 'FAIL: ~/.ssh does not exist on this machine\n' >&2
  exit 1
fi

require_binaries "$SANCTUARY_BIN" "$SANCTUARYD_BIN"
sanctuary_clean_state

mkdir -p "$fake_bin_dir"
make_fake_agent_binary "$fake_agent"

log_step "protecting ~/.ssh in the e2e policy DB"
"$SANCTUARY_BIN" protect "$HOME/.ssh"

log_step "starting sanctuaryd"
sanctuary_start
sleep 2

agent_since="$(audit_timestamp_now)"
log_step "writing probe through fixture agent executable: $fake_agent"
"$fake_agent" write-hold "$probe" &
agent_pid="$!"
sleep 0.5
wait_with_timeout "$agent_pid" 5 || {
  printf 'FAIL: fixture agent did not exit within timeout\n' >&2
  exit 1
}
wait_for_file_pattern "$SANCTUARY_AUDIT_PATH" '"policy":"protected_folder"' 10 || true
capture_audit_since "$agent_since" > "$agent_audit"
cat "$agent_audit"

if ! grep -Eq '"action":"DETECT_ALERT".*"policy":"protected_folder"|"policy":"protected_folder".*"action":"DETECT_ALERT"' "$agent_audit"; then
  printf 'FAIL: agent access did not produce a protected_folder DETECT_ALERT\n' >&2
  exit 1
fi

if ! grep -Eq '"level":"(definite|probable)"' "$agent_audit"; then
  printf 'FAIL: agent access was not attributed as definite or probable\n' >&2
  exit 1
fi

log_step "writing probe through non-agent /bin/sh"
# The detector intentionally retains short-lived agent fd evidence for 5s so
# FSEvents that arrive late can still be attributed. Wait out that window before
# proving a clean non-agent access does not inherit the previous agent event.
sleep 6
non_agent_since="$(audit_timestamp_now)"
/bin/sh -c 'printf "non-agent\n" > "$1"; sleep 1' sh "$probe"
sleep 1
capture_audit_since "$non_agent_since" > "$non_agent_audit"
cat "$non_agent_audit"

if grep -Eq '"level":"(definite|probable)"' "$non_agent_audit"; then
  printf 'FAIL: non-agent access was attributed as definite/probable\n' >&2
  exit 1
fi

log_step "filesystem detection scenario passed"
