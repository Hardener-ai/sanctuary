#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${SANCTUARY_E2E_COMMON_LOADED:-}" ]]; then
  SANCTUARY_E2E_COMMON_LOADED=1

  SANCTUARY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  export SANCTUARY_ROOT

  E2E_WORK_DIR="${E2E_WORK_DIR:-/tmp/sanctuary-e2e}"
  export E2E_WORK_DIR

  SANCTUARY_BIN="${SANCTUARY_BIN:-$SANCTUARY_ROOT/.build/release/sanctuary}"
  SANCTUARYD_BIN="${SANCTUARYD_BIN:-$SANCTUARY_ROOT/.build/release/sanctuaryd}"
  CDP_HARNESS_BIN="${CDP_HARNESS_BIN:-$SANCTUARY_ROOT/.build/release/sanctuary-cdpguard-test}"
  export SANCTUARY_BIN SANCTUARYD_BIN CDP_HARNESS_BIN

  SANCTUARY_DB_PATH="${SANCTUARY_DB_PATH:-$E2E_WORK_DIR/policy.sqlite}"
  SANCTUARY_AUDIT_PATH="${SANCTUARY_AUDIT_PATH:-$E2E_WORK_DIR/audit.log}"
  SANCTUARY_INVENTORY_SNAPSHOT_PATH="${SANCTUARY_INVENTORY_SNAPSHOT_PATH:-$E2E_WORK_DIR/inventory.json}"
  SANCTUARY_AUDIT_DEV_KEY_PATH="${SANCTUARY_AUDIT_DEV_KEY_PATH:-$E2E_WORK_DIR/audit-signing.key}"
  SANCTUARY_PEER_SOCKET_PATH="${SANCTUARY_PEER_SOCKET_PATH:-$E2E_WORK_DIR/peer-monitor.sock}"
  export SANCTUARY_DB_PATH SANCTUARY_AUDIT_PATH SANCTUARY_INVENTORY_SNAPSHOT_PATH SANCTUARY_AUDIT_DEV_KEY_PATH SANCTUARY_PEER_SOCKET_PATH

  mkdir -p "$E2E_WORK_DIR"

  log_step() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
  }

  require_binaries() {
    local missing=0
    for binary in "$@"; do
      if [[ ! -x "$binary" ]]; then
        printf 'missing executable: %s\n' "$binary" >&2
        missing=1
      fi
    done
    return "$missing"
  }

  sanctuary_clean_state() {
    sanctuary_stop >/dev/null 2>&1 || true
    if command -v sudo >/dev/null 2>&1; then
      sudo pfctl -a 'com.apple/250.SanctuaryRedirect' -F all >/dev/null 2>&1 || true
    fi
    mkdir -p "$(dirname "$SANCTUARY_AUDIT_PATH")"
    : > "$SANCTUARY_AUDIT_PATH"
    rm -f "$SANCTUARY_DB_PATH" "$SANCTUARY_INVENTORY_SNAPSHOT_PATH" "$SANCTUARY_AUDIT_DEV_KEY_PATH" "$SANCTUARY_PEER_SOCKET_PATH"
  }

  sanctuary_start() {
    require_binaries "$SANCTUARYD_BIN"
    mkdir -p "$E2E_WORK_DIR"
    SANCTUARY_DB_PATH="$SANCTUARY_DB_PATH" \
      SANCTUARY_AUDIT_PATH="$SANCTUARY_AUDIT_PATH" \
      SANCTUARY_INVENTORY_SNAPSHOT_PATH="$SANCTUARY_INVENTORY_SNAPSHOT_PATH" \
      SANCTUARY_AUDIT_DEV_KEY_PATH="$SANCTUARY_AUDIT_DEV_KEY_PATH" \
      SANCTUARY_PEER_SOCKET_PATH="$SANCTUARY_PEER_SOCKET_PATH" \
      "$SANCTUARYD_BIN" > "$E2E_WORK_DIR/sanctuaryd.log" 2>&1 &
    echo "$!" > "$E2E_WORK_DIR/sanctuaryd.pid"
    sleep 1
  }

  sanctuary_stop() {
    if [[ -f "$E2E_WORK_DIR/sanctuaryd.pid" ]]; then
      local pid
      pid="$(cat "$E2E_WORK_DIR/sanctuaryd.pid")"
      if kill -0 "$pid" >/dev/null 2>&1; then
        kill -TERM "$pid" >/dev/null 2>&1 || true
        for _ in {1..50}; do
          if ! kill -0 "$pid" >/dev/null 2>&1; then
            break
          fi
          sleep 0.1
        done
      fi
      rm -f "$E2E_WORK_DIR/sanctuaryd.pid"
    fi
  }

  capture_audit_since() {
    local since="$1"
    python3 - "$since" "$SANCTUARY_AUDIT_PATH" <<'PY'
import json
import sys
from datetime import datetime, timezone

since_raw, path = sys.argv[1], sys.argv[2]

def parse_ts(value):
    value = value.replace("Z", "+00:00")
    return datetime.fromisoformat(value)

since = parse_ts(since_raw)
try:
    lines = open(path, "r", encoding="utf-8").read().splitlines()
except FileNotFoundError:
    sys.exit(0)

for line in lines:
    entry_json = line.split(',"sig":"', 1)[0]
    try:
        entry = json.loads(entry_json)
        ts = parse_ts(entry.get("ts", "1970-01-01T00:00:00Z"))
    except Exception:
        continue
    if ts >= since:
        print(line)
PY
  }

  assert_audit_contains() {
    local pattern="$1"
    local file="${2:-$SANCTUARY_AUDIT_PATH}"
    if ! grep -Eq "$pattern" "$file"; then
      printf 'expected audit pattern not found: %s\n' "$pattern" >&2
      return 1
    fi
  }

  audit_timestamp_now() {
    python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"))
PY
  }

  wait_for_file_pattern() {
    local file="$1"
    local pattern="$2"
    local timeout="${3:-5}"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
      if [[ -f "$file" ]] && grep -Eq "$pattern" "$file"; then
        return 0
      fi
      sleep 0.2
    done
    return 1
  }

  make_fake_agent_binary() {
    local output="$1"
    local source="$output.c"
    mkdir -p "$(dirname "$output")"
    cat > "$source" <<'C'
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: codex <write-hold|read> <path>\n");
        return 64;
    }

    if (strcmp(argv[1], "write-hold") == 0) {
        int fd = open(argv[2], O_CREAT | O_WRONLY | O_TRUNC, 0600);
        if (fd < 0) {
            perror("open");
            return 1;
        }
        const char *body = "fixture data only\n";
        if (write(fd, body, strlen(body)) < 0) {
            perror("write");
            return 1;
        }
        sleep(2);
        close(fd);
        return 0;
    }

    if (strcmp(argv[1], "read") == 0) {
        int fd = open(argv[2], O_RDONLY);
        if (fd < 0) {
            perror("open");
            return 1;
        }
        char buffer[256];
        while (read(fd, buffer, sizeof(buffer)) > 0) {}
        sleep(4);
        close(fd);
        return 0;
    }

    if (strcmp(argv[1], "http-get") == 0) {
        if (argc < 5) {
            fprintf(stderr, "usage: codex http-get <host> <port> <path>\n");
            return 64;
        }
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            perror("socket");
            return 1;
        }
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)atoi(argv[3]));
        if (inet_pton(AF_INET, argv[2], &addr.sin_addr) != 1) {
            perror("inet_pton");
            return 1;
        }
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            perror("connect");
            return 1;
        }
        char request[1024];
        snprintf(request, sizeof(request), "GET %s HTTP/1.1\r\nHost: %s:%s\r\nConnection: close\r\n\r\n", argv[4], argv[2], argv[3]);
        if (write(fd, request, strlen(request)) < 0) {
            perror("write");
            return 1;
        }
        char buffer[1024];
        ssize_t n;
        while ((n = read(fd, buffer, sizeof(buffer))) > 0) {
            fwrite(buffer, 1, (size_t)n, stdout);
        }
        close(fd);
        return 0;
    }

    fprintf(stderr, "unknown command: %s\n", argv[1]);
    return 64;
}
C
    clang "$source" -o "$output"
    chmod 0755 "$output"
  }

  wait_with_timeout() {
    local pid="$1"
    local timeout="${2:-5}"
    local deadline=$((SECONDS + timeout))
    while kill -0 "$pid" >/dev/null 2>&1; do
      if (( SECONDS >= deadline )); then
        kill -TERM "$pid" >/dev/null 2>&1 || true
        sleep 0.2
        kill -KILL "$pid" >/dev/null 2>&1 || true
        return 1
      fi
      sleep 0.1
    done
    wait "$pid" 2>/dev/null || true
    return 0
  }
fi
