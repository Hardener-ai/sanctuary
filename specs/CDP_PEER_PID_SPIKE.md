# CDP_PEER_PID_SPIKE

**Component**: `Sources/CDPPeerPIDSpike/`
**Status**: completed; Approach C rejected as primary
**Owner**: SanctuaryCore / SanctuaryDaemon
**Critical path rank**: highest current uncertainty for CDP Guard

---

## 1. Decision

Run this spike before deeper CDP Guard implementation. Completed result: public Network.framework TCP metadata did not expose a usable peer pid or audit-token-equivalent for an accepted loopback TCP connection.

The classifier is good enough to integrate. CDP Guard process attribution is still the largest v0.1 launch risk because the demo only works if Sanctuary can connect an incoming localhost CDP connection to the client process that opened it.

Security posture: if attribution is uncertain, protected CDP ports fail closed by default. A wallet-protection product cannot guess wrong in the permissive direction.

---

## 2. Question

Can Sanctuary obtain the peer pid for an incoming loopback TCP connection using public Network.framework APIs quickly and reliably?

Specifically, test whether `NWConnection.metadata(definition: NWProtocolTCP.definition)` or adjacent public `NWConnection` state exposes the client process pid for a localhost connection.

If yes:

- CDP Guard can use the clean Network.framework path for v0.1.
- `proc_pidfdinfo` enumeration remains a fallback.

If no:

- Update `CDP_GUARD_SPEC.md` to demote Approach C.
- Build v0.1 on `proc_pidfdinfo` socket enumeration.
- Keep `lsof` only as a diagnostic/debug fallback, never hot-path enforcement.

Current decision: Approach C is rejected as the v0.1 primary path. Build `PeerProcessAttributor` on Approach B.

---

## 3. Non-goals

This spike does not:

- Implement CDP proxying.
- Parse WebSocket upgrades.
- Classify real agent processes.
- Discover browser debug ports.
- Use private macOS APIs.
- Shell out to `lsof`.
- Read environment variable values.

---

## 4. Test Harness

Executable target:

```text
sanctuary-cdp-peer-pid-spike
```

Run:

```sh
swift run sanctuary-cdp-peer-pid-spike
```

Optional fixed port:

```sh
swift run sanctuary-cdp-peer-pid-spike 49222
```

The harness:

1. Starts an `NWListener` on `127.0.0.1` with an ephemeral port by default.
2. Opens a localhost `NWConnection` client from the same process.
3. Accepts the connection on the listener.
4. Inspects public TCP metadata from the accepted server-side `NWConnection`.
5. Emits JSON containing:
   - expected client pid
   - listener port
   - metadata type
   - metadata description
   - reflected metadata children
   - current conclusion

Using the same process for the first run is intentional: the expected pid is unambiguous. If Network.framework cannot surface the current process pid in this simplest case, it is not viable as CDP Guard's primary attribution path.

---

## 5. Success Criteria

Approach C is accepted only if all are true:

- The public Network.framework surface exposes a stable peer pid or audit-token-equivalent.
- The field is available on the server side of an accepted loopback TCP connection.
- The field matches the connecting process pid in repeated runs.
- Lookup completes in less than 1ms after `NWConnection` reaches `.ready`.
- The implementation uses documented public APIs.

Reflection-only discovery does not count as production success. Reflection is allowed in the spike only to inspect what the public object carries.

---

## 6. Failure Criteria

Approach C is rejected if any are true:

- Metadata contains only TCP protocol state and no process identity.
- Peer pid appears only in private or unstable implementation details.
- The value cannot distinguish between two separate local client processes.
- The value is unavailable before WebSocket upgrade handling.
- Lookup requires private frameworks or entitlements not available to v0.1.

Expected outcome from SDK inspection: public Network.framework likely does not expose peer pid for TCP. The spike exists to verify that, not to wish it away.

Observed first run:

```json
{
  "currentConclusion": "no-peer-pid-surface-observed-via-public-network-metadata; proceed to proc_pidfdinfo fallback unless a lower-level NW API proves otherwise",
  "networkMetadataDescription": "Network.NWProtocolTCP.Metadata",
  "networkMetadataType": "NWProtocolMetadata",
  "reflectedMetadataChildren": [
    "some: Network.NWProtocolTCP.Metadata"
  ]
}
```

---

## 7. Follow-up If Approach C Fails

Build `PeerProcessAttributor` on Approach B:

1. Capture the accepted connection's local and remote endpoint tuple.
2. Enumerate candidate pids via `proc_listpids`.
3. Enumerate each pid's file descriptors via `proc_pidinfo(..., PROC_PIDLISTFDS, ...)`.
4. Inspect socket descriptors via `proc_pidfdinfo(..., PROC_PIDFDSOCKETINFO, ...)`.
5. Match TCP sockets by local address, local port, remote address, remote port, protocol, and state.
6. Return exactly one pid or fail closed for protected profiles.

Performance target: p95 under 10ms on a typical developer Mac. If full-system scans are too slow, narrow candidates by recent process cache, `netstat`-like kernel socket tables, or CDP client behavior observed during browser debug-port discovery.
