#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

trap 'sanctuary_clean_state >/dev/null 2>&1 || true' EXIT INT TERM

require_binaries "$SANCTUARY_BIN" "$SANCTUARYD_BIN"

fixture_dir="$E2E_WORK_DIR/tamper-fixture"
agent="$fixture_dir/codex"
protected="$fixture_dir/protected"
pristine="$E2E_WORK_DIR/audit-pristine.log"
mkdir -p "$fixture_dir" "$protected"

log_step "cleaning state"
sanctuary_clean_state

log_step "building fixture agent"
make_fake_agent_binary "$agent"

log_step "tagging fixture agent and protecting fixture folder"
"$SANCTUARY_BIN" agents add "$agent" >/dev/null
"$SANCTUARY_BIN" protect "$protected" >/dev/null

log_step "starting sanctuaryd"
sanctuary_start

log_step "generating audit entries"
for index in 1 2 3 4 5; do
  "$agent" write-hold "$protected/probe-$index.txt" &
  wait_with_timeout "$!" 6
done

wait_for_file_pattern "$SANCTUARY_AUDIT_PATH" '"action":"DETECT_ALERT"' 10
entry_count="$(grep -c '"action":"DETECT_ALERT"' "$SANCTUARY_AUDIT_PATH" || true)"
if (( entry_count < 3 )); then
  printf 'FAIL: expected at least 3 audit entries, found %s\n' "$entry_count" >&2
  exit 1
fi

log_step "verifying pristine log"
"$SANCTUARY_BIN" log verify --path "$SANCTUARY_AUDIT_PATH"
cp "$SANCTUARY_AUDIT_PATH" "$pristine"

log_step "tamper 1: replace a middle line with another valid signed line"
python3 - "$SANCTUARY_AUDIT_PATH" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
if len(lines) < 3:
    raise SystemExit("not enough lines to tamper")
lines[2] = lines[0]
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
if "$SANCTUARY_BIN" log verify --path "$SANCTUARY_AUDIT_PATH" > "$E2E_WORK_DIR/tamper-middle.txt" 2>&1; then
  printf 'FAIL: modified middle line verified as valid\n' >&2
  exit 1
fi
cat "$E2E_WORK_DIR/tamper-middle.txt"
grep -Eq 'hash chain broken|signature verification failed' "$E2E_WORK_DIR/tamper-middle.txt"

log_step "tamper 2: delete last two lines"
cp "$pristine" "$SANCTUARY_AUDIT_PATH"
python3 - "$SANCTUARY_AUDIT_PATH" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
path.write_text("\n".join(lines[:-2]) + "\n", encoding="utf-8")
PY
"$SANCTUARY_BIN" log verify --path "$SANCTUARY_AUDIT_PATH" > "$E2E_WORK_DIR/tamper-tail-delete.txt" 2>&1
cat "$E2E_WORK_DIR/tamper-tail-delete.txt"
grep -Eq 'Audit log valid\.' "$E2E_WORK_DIR/tamper-tail-delete.txt"

log_step "tamper 3: truncate file mid-entry"
cp "$pristine" "$SANCTUARY_AUDIT_PATH"
python3 - "$SANCTUARY_AUDIT_PATH" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = path.read_text(encoding="utf-8")
path.write_text(data[:-12], encoding="utf-8")
PY
if "$SANCTUARY_BIN" log verify --path "$SANCTUARY_AUDIT_PATH" > "$E2E_WORK_DIR/tamper-truncate.txt" 2>&1; then
  printf 'FAIL: truncated line verified as valid\n' >&2
  exit 1
fi
cat "$E2E_WORK_DIR/tamper-truncate.txt"
grep -Eq 'entry parse failure' "$E2E_WORK_DIR/tamper-truncate.txt"

log_step "tamper-evident audit scenario passed"
