# Sanctuary End-to-End Attack Scenarios

These scenarios are reproducible proof runs for Sanctuary's launch demo and
future bounty program. Each script demonstrates one attack surface, captures
the relevant evidence, and writes a markdown result through `e2e/run-all.sh`.

## Quick Start

```bash
cd ~/Projects/sanctuary
swift build -c release --product sanctuary --product sanctuaryd --product sanctuary-cdpguard-test
./e2e/run-all.sh
```

PF-backed CDP interception is gated because it touches macOS `pf`:

```bash
E2E_PF=1 ./e2e/run-all.sh
```

The scripts use temporary state by default:

- Policy DB: `/tmp/sanctuary-e2e/policy.sqlite`
- Audit log: `/tmp/sanctuary-e2e/audit.log`
- Inventory snapshot: `/tmp/sanctuary-e2e/inventory.json`
- Peer monitor socket: `/tmp/sanctuary-e2e/peer-monitor.sock`

Override these with `SANCTUARY_DB_PATH`, `SANCTUARY_AUDIT_PATH`,
`SANCTUARY_INVENTORY_SNAPSHOT_PATH`, and `SANCTUARY_PEER_SOCKET_PATH` when
needed.

## Prerequisites

- macOS 14+
- Sanctuary built in release mode
- The scoped `sanctuary-dev` sudoers file for PF scenarios
- A real Chromium-family browser for the final CDP demo path
- Hermes and OpenClaw running for the classifier inventory scenario

No scenario reads or prints environment values, real SSH keys, or wallet
contents. Files created by the scenarios contain fixture text only.

## Scenarios

### `scenario-classifier-hermes-openclaw.sh`

Tests that `sanctuary inventory list` identifies the modal-user agent stack.

Proves:

- Hermes appears as `backgroundService`
- OpenClaw appears as `backgroundService`
- `sanctuaryd` is excluded from its own inventory

Expected duration: 1-3 seconds.

Common failure modes: Hermes/OpenClaw are not running, or a new install layout
needs another registry/runtime fingerprint.

### `scenario-fs-detection-ssh.sh`

Tests that an agent write inside `~/.ssh` produces a signed audit alert.

Proves:

- Protected folder registration works
- The daemon watches the protected path
- A known-agent fixture executable is attributed as `definite` or `probable`
- A non-agent shell access is not attributed as `definite` or `probable`

Expected duration: 5-8 seconds.

Common failure modes: `~/.ssh` does not exist, FSEvents delivery is delayed, or
the fixture process exits before vnode attribution can observe its file
descriptor.

### `scenario-extension-storage-metamask.sh`

Tests that a MetaMask extension storage access by an agent creates an audit
alert.

Proves:

- The extension registry accepts MetaMask protection for a fixture profile
- Once extension storage watching is daemon-wired, the protected path emits
  `protected_extension_storage` alerts

Expected duration: 4-6 seconds.

Common failure modes: fixture profile layout drift, FSEvents delivery delay, or
the fixture process exiting before vnode attribution can observe its file
descriptor.

### `scenario-cdp-guard-blocks.sh`

Tests that CDP Guard blocks an agent from attaching to a protected browser
profile while allowing non-agent access.

Proves:

- PF redirect sends local CDP traffic through Sanctuary
- Process attribution distinguishes agent and non-agent callers
- Protected profile policy blocks the agent path

Expected duration: 10-20 seconds.

This scenario is gated behind `E2E_PF=1` because it touches `pf`.

### `scenario-user-tagged-agent.sh`

Tests that `sanctuary agents add <path>` persists user state and affects live
daemon classification.

Proves:

- User-tagged agents are stored in the policy DB
- `sanctuary agents list` separates user-tagged agents from bundled known agents
- The daemon classifies the tagged fixture binary as an agent
- Protected-folder access by the fixture produces a `DETECT_ALERT`

Expected duration: 5-8 seconds.

Common failure modes: policy DB path mismatch between CLI and daemon, or the
fixture process exiting before vnode attribution observes its open file.

### `scenario-tamper-evident-audit.sh`

Tests that signed audit entries are linked by SHA-256 hash chain continuity.

Proves:

- A pristine audit log verifies as valid
- Replacing a middle line with another signed line breaks the hash chain
- Deleting tail lines leaves the remaining prefix valid
- Truncating mid-entry reports a parse failure

Expected duration: 10-15 seconds.

Common failure modes: dev signing configuration that prevents the CLI verifier
from using the same audit public key as the daemon, or too few generated audit
events on a slow FSEvents delivery cycle.

### `scenario-tamper-peer-disconnect.sh`

Tests that the menu-bar peer monitor notices an unexpectedly unavailable
daemon and writes a tamper audit event.

Proves:

- The daemon peer socket responds to menu-bar pings
- A missing daemon produces `TAMPER_DETECTED` when protection is expected
- Restarting the daemon is observed as peer recovery or restart

Expected duration: 18-25 seconds.

Common failure modes: stale peer sockets from previous runs, daemon startup
failure, or a changed peer-monitor timing budget.

### `scenario-tamper-pf-flush.sh`

Tests that Sanctuary detects a flushed CDP Guard pf anchor, reloads the rules,
and keeps blocking agent CDP attempts.

Proves:

- The Sanctuary pf anchor is present before tamper
- `pfctl -F all` is detected as `TAMPER_DETECTED`
- The anchor rules are re-installed automatically
- CDP Guard still blocks a fixture agent after recovery

Expected duration: 4-10 seconds.

This scenario is gated behind `E2E_PF=1` because it flushes and reloads pf state.

Common failure modes: missing sudoers entry for `pfctl`, pf disabled or broken on
the host, or CDP Guard harness startup failure.
