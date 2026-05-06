#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

profile="$E2E_WORK_DIR/metamask-profile"
metamask_id="nkbihfbeogaeaoehlefnkodbefgpgknn"
storage_dir="$profile/Local Extension Settings/$metamask_id"
fixture_file="$storage_dir/fixture-vault.ldb"
fake_bin_dir="$E2E_WORK_DIR/fake-bin"
fake_agent="$fake_bin_dir/codex"
agent_audit="$E2E_WORK_DIR/extension-agent-audit.log"
non_agent_audit="$E2E_WORK_DIR/extension-non-agent-audit.log"

cleanup() {
  sanctuary_clean_state >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

require_binaries "$SANCTUARY_BIN" "$SANCTUARYD_BIN"
sanctuary_clean_state

mkdir -p "$storage_dir" "$fake_bin_dir"
printf 'fixture metadata only; no wallet secret\n' > "$fixture_file"
make_fake_agent_binary "$fake_agent"

log_step "protecting fake MetaMask storage for fixture profile"
"$SANCTUARY_BIN" protect-extension metamask --profile "$profile"

log_step "starting sanctuaryd"
sanctuary_start
sleep 2

agent_since="$(audit_timestamp_now)"
log_step "reading fixture storage through fixture agent executable"
"$fake_agent" read "$fixture_file" >/dev/null
wait_for_file_pattern "$SANCTUARY_AUDIT_PATH" '"policy":"protected_extension_storage"' 10 || true
capture_audit_since "$agent_since" > "$agent_audit"
cat "$agent_audit"

if ! grep -Eq '"action":"DETECT_ALERT".*"policy":"protected_extension_storage"|"policy":"protected_extension_storage".*"action":"DETECT_ALERT"' "$agent_audit"; then
  printf 'FAIL: agent extension storage read did not produce protected_extension_storage DETECT_ALERT\n' >&2
  exit 1
fi

non_agent_since="$(audit_timestamp_now)"
log_step "reading fixture storage through non-agent /bin/cat"
/bin/cat "$fixture_file" >/dev/null
sleep 1
capture_audit_since "$non_agent_since" > "$non_agent_audit"
cat "$non_agent_audit"

if grep -Eq '"level":"(definite|probable)"' "$non_agent_audit"; then
  printf 'FAIL: non-agent extension storage read was attributed as definite/probable\n' >&2
  exit 1
fi

log_step "extension storage scenario passed"
