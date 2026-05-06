#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if [[ "${E2E_PF:-0}" != "1" ]]; then
  printf 'SKIP: set E2E_PF=1 to run the pf-backed pf tamper scenario\n'
  exit 77
fi

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "${harness_pid:-}" ]]; then
    kill -TERM "$harness_pid" >/dev/null 2>&1 || true
  fi
  sanctuary_clean_state >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

require_binaries "$SANCTUARY_BIN" "$CDP_HARNESS_BIN"
sanctuary_clean_state

fake_bin_dir="$E2E_WORK_DIR/fake-bin"
fake_agent="$fake_bin_dir/codex"
profile="$E2E_WORK_DIR/protected-cdp-profile"
mkdir -p "$fake_bin_dir" "$profile"
make_fake_agent_binary "$fake_agent"

log_step "starting fixture CDP-shaped HTTP server on 127.0.0.1:19222"
python3 - "$E2E_WORK_DIR/cdp-fixture.log" <<'PY' &
import http.server
import json
import sys

log_path = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(self.path + "\n")
        if self.path == "/json/version":
            body = json.dumps({"Browser": "Fixture/1.0", "webSocketDebuggerUrl": "ws://127.0.0.1:19222/devtools/browser/fixture"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

http.server.ThreadingHTTPServer(("127.0.0.1", 19222), Handler).serve_forever()
PY
server_pid="$!"
sleep 1

log_step "starting CDP Guard harness with pf revalidation"
sudo -n "$CDP_HARNESS_BIN" \
  --debug-port 19222 \
  --profile "$profile" \
  --protected \
  --audit-path "$SANCTUARY_AUDIT_PATH" \
  --audit-dev-key-path "$SANCTUARY_AUDIT_DEV_KEY_PATH" \
  --pf-revalidation-interval 2 \
  > "$E2E_WORK_DIR/cdp-harness.log" 2>&1 &
harness_pid="$!"
sleep 2

anchor="com.apple/250.SanctuaryRedirect"
initial_count="$(sudo -n pfctl -a "$anchor" -s nat 2>/dev/null | wc -l | tr -d ' ')"
if (( initial_count == 0 )); then
  printf 'FAIL: expected initial Sanctuary pf anchor rules\n' >&2
  exit 1
fi
log_step "initial pf anchor rule count: $initial_count"

log_step "flushing pf rules to simulate tamper"
sudo -n pfctl -F all >/dev/null 2>&1
post_global_flush_count="$(sudo -n pfctl -a "$anchor" -s nat 2>/dev/null | wc -l | tr -d ' ')"
if (( post_global_flush_count > 0 )); then
  log_step "global flush left named anchor populated; flushing Sanctuary anchor directly"
  sudo -n pfctl -a "$anchor" -F all >/dev/null 2>&1
fi

log_step "waiting for revalidator to detect and reload"
if ! wait_for_file_pattern "$SANCTUARY_AUDIT_PATH" '"action":"TAMPER_DETECTED".*pf_rules_flushed' 20; then
  printf 'FAIL: expected pf_rules_flushed tamper audit entry\n' >&2
  sed -n '1,120p' "$SANCTUARY_AUDIT_PATH" >&2 || true
  exit 1
fi

reloaded_count="$(sudo -n pfctl -a "$anchor" -s nat 2>/dev/null | wc -l | tr -d ' ')"
if (( reloaded_count == 0 )); then
  printf 'FAIL: expected pf anchor rules to be re-installed after flush\n' >&2
  exit 1
fi
log_step "reloaded pf anchor rule count: $reloaded_count"

log_step "verifying CDP Guard still blocks agent after recovery"
agent_response="$E2E_WORK_DIR/cdp-agent-after-pf-reload.txt"
"$fake_agent" http-get 127.0.0.1 19222 /json/version > "$agent_response" 2>&1 || true
cat "$agent_response"
if ! grep -Eq '403|Forbidden' "$agent_response"; then
  printf 'FAIL: agent CDP connection was not blocked after pf recovery\n' >&2
  exit 1
fi

log_step "audit evidence"
grep -E '"action":"(PF_RULES_MISSING|PF_RULES_MODIFIED|TAMPER_DETECTED|PF_RULES_VALIDATED)".*"policy":"cdp_guard_pf"' "$SANCTUARY_AUDIT_PATH"

log_step "pf flush tamper scenario passed"
