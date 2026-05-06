#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if [[ "${E2E_PF:-0}" != "1" ]]; then
  printf 'SKIP: set E2E_PF=1 to run the pf-backed CDP Guard scenario\n'
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

log_step "starting CDP Guard harness for protected fixture profile"
sudo -n "$CDP_HARNESS_BIN" --debug-port 19222 --profile "$profile" --protected > "$E2E_WORK_DIR/cdp-harness.log" 2>&1 &
harness_pid="$!"
sleep 2

log_step "requesting CDP endpoint through fixture agent"
agent_response="$E2E_WORK_DIR/cdp-agent-response.txt"
"$fake_agent" http-get 127.0.0.1 19222 /json/version > "$agent_response" 2>&1 || true
cat "$agent_response"
if ! grep -Eq '403|Forbidden' "$agent_response"; then
  printf 'FAIL: agent CDP connection was not blocked with 403/Forbidden\n' >&2
  exit 1
fi

log_step "requesting CDP endpoint through non-agent curl"
non_agent_response="$E2E_WORK_DIR/cdp-non-agent-response.txt"
curl -s -i http://127.0.0.1:19222/json/version > "$non_agent_response"
cat "$non_agent_response"
if ! grep -Eq 'HTTP/1\.[01] 200' "$non_agent_response" || ! grep -q 'webSocketDebuggerUrl' "$non_agent_response"; then
  printf 'FAIL: non-agent CDP connection was not allowed through to fixture server\n' >&2
  exit 1
fi

log_step "CDP guard blocking scenario passed"
