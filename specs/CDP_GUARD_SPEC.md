# CDP_GUARD_SPEC

**Component**: `Sources/SanctuaryCore/CDPGuard/`
**Status**: spec for v1 implementation
**Owner**: SanctuaryDaemon (runs CDPGuard as a sub-component)
**Critical path rank**: 2 of 6 — without this, the demo doesn't work

---

## 1. Purpose

CDP Guard is the enforcement layer that prevents AI agents from hijacking authenticated browser sessions to drain wallets, scrape passwords, or impersonate the user.

The attack it stops:

1. User has Chrome (or Brave, Edge, Arc) running with MetaMask installed and unlocked
2. Agent obtains a CDP (Chrome DevTools Protocol) WebSocket URL — either because the user launched Chrome with `--remote-debugging-port`, or because the agent uses `playwright.connectOverCDP()` against a debug port the agent itself opened
3. Agent issues CDP commands to drive MetaMask: open the popup, click "Confirm", sign a tx that drains the wallet to attacker-controlled address
4. Wallet drained. User had no idea.

CDP Guard breaks this attack at the WebSocket layer. When an agent process attempts to attach to a protected browser profile via CDP, the connection is dropped before any commands can be issued.

This is the **demo's enforcement layer**. The killer launch video shows: agent attaches → drains wallet (no Sanctuary). Sanctuary enabled → agent attaches → drop → wallet untouched.

---

## 2. Background: how CDP works

Chrome and Chromium-based browsers (Brave, Edge, Arc, Vivaldi) expose a debugging API when launched with `--remote-debugging-port=N` or `--remote-debugging-pipe`.

```
chrome --remote-debugging-port=9222
```

This opens a localhost HTTP server on port 9222 with two key endpoints:

- `GET http://127.0.0.1:9222/json/version` — browser metadata, gives the **WebSocket Debugger URL** (`webSocketDebuggerUrl`) for the browser-level target
- `GET http://127.0.0.1:9222/json` — list of debuggable targets (tabs, extensions, service workers), each with its own WebSocket URL

A client (Playwright, Puppeteer, anything) connects to the WebSocket URL. From that point on, the client can:

- Send `Target.getTargets` to list tabs and extension service workers
- Send `Target.attachToTarget` to attach to a specific tab or extension
- Send `Runtime.evaluate` to execute arbitrary JavaScript in the target
- Send `Input.dispatchMouseEvent` / `Input.dispatchKeyEvent` to simulate clicks and typing
- Drive MetaMask's UI, fill forms, submit transactions

The CDP WebSocket is **unauthenticated**. Anyone on localhost who can reach the port can drive the browser. This is by design (debugging should be easy) and exactly the security gap CDP Guard closes for agent contexts.

### How agents use this in practice

Three paths:

| Path | Description | How CDP Guard sees it |
|---|---|---|
| **A. User-launched debug port** | User runs `chrome --remote-debugging-port=9222` themselves, agent connects to it | CDP Guard sees a WebSocket connection on a known browser debug port |
| **B. Agent launches its own Chrome** | Agent spawns Chromium with debug port, drives it. (Playwright's default mode.) | The Chromium process is parented to the agent → classifier already flags it. Plus debug port detection. |
| **C. Agent uses `connectOverCDP` against existing browser** | User runs Chrome normally, agent attaches via Playwright's `connectOverCDP()`. **Requires** user-enabled debug port (Path A). | Same as Path A. |

There is no fourth path that doesn't go through CDP. (Browser extensions running malicious JS is a different attack surface — out of scope for CDP Guard.)

---

## 3. Architecture

CDP Guard is a TCP-level interception proxy that sits in front of every detected browser debug port. Connections from agent processes are dropped before the WebSocket upgrade completes. Connections from non-agent processes pass through unchanged.

```
┌──────────────────────────────────────────────────┐
│            CDP Guard (in daemon)                 │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ Browser Debug Port Discovery                │  │
│  │  - lsof for chrome/Brave/Edge/Arc + :*      │  │
│  │  - kqueue NOTE_EXTEND on /Applications      │  │
│  │  - poll every 5s as fallback                │  │
│  └────────────────────────────────────────────┘  │
│                       │                          │
│  ┌────────────────────▼───────────────────────┐  │
│  │ Port Hijack via pf (packet filter)         │  │
│  │  Redirect 127.0.0.1:9222 → 127.0.0.1:N     │  │
│  │  where N is our proxy listener             │  │
│  └────────────────────┬───────────────────────┘  │
│                       │                          │
│  ┌────────────────────▼───────────────────────┐  │
│  │ Proxy Listener (NWConnection)              │  │
│  │  1. Accept TCP from client                 │  │
│  │  2. Look up client pid via lsof / proc API │  │
│  │  3. Classify client process                │  │
│  │  4. If agent → drop with 403               │  │
│  │  5. If profile is protected → drop         │  │
│  │  6. Else → splice to real browser port     │  │
│  └────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

---

## 4. Process attribution: the hard part

The classifier in §3 step 3 needs the **client pid** of the incoming TCP connection. This is the hardest part of CDP Guard and the place implementation can fail.

### Approaches considered

**A. Read `lsof -i tcp:<port> -nP` and parse output.**
Slow (~50-100ms shell-out), brittle (parsing). Use only as fallback.

**B. Use `proc_pidfdinfo` to enumerate file descriptors of every process and find the one matching the socket.**
Better. We can iterate processes and ask each "do you have a socket open with these endpoints?" Cost: O(processes × fds). On a busy machine, several hundred processes × tens of fds each = manageable but not free.

**C. Use Network framework's `NWConnection.metadata(definition: NWProtocolTCP.definition)` to get peer info.**
Gives us `pid` of the peer for local connections via `endpoint.interface` on recent macOS. **Confirm during implementation** — this is the cleanest path if it works.

**D. Audit tokens via Endpoint Security `ES_EVENT_TYPE_NOTIFY_SOCKET_CONNECT`.**
Cleanest of all if we have ES entitlement. Without entitlement: fallback to B or C.

### Decision for v1

- **Primary**: Approach B (`proc_pidfdinfo` enumeration). Acceptable but slower, and it uses public macOS process/socket inspection APIs.
- **Rejected as primary**: Approach C (`NWConnection` metadata). The spike in `specs/CDP_PEER_PID_SPIKE.md` found TCP metadata but no public peer-pid or audit-token-equivalent surface.
- **Diagnostic only**: Approach A (`lsof`). Useful during development, too slow and brittle for hot-path enforcement.
- **Future** (post-ES-entitlement): Approach D.

Spike result: see `specs/CDP_PEER_PID_SPIKE.md`.

If neither A nor B nor C reliably returns a pid in <10ms, CDP Guard **fails closed** for protected profiles: drop the connection. (Better to break a power-user's manual debugging session than to leak a wallet.) This is configurable via `sanctuary config set cdp.fail-mode {open|closed}`. Default: **closed**.

---

## 5. Browser debug port discovery

Browsers don't advertise their debug ports in any registry. We have to discover them.

### Discovery mechanism

```swift
func discoverBrowserDebugPorts() -> [BrowserDebugPort] {
    let browserBundleIDs = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
    ]

    var results: [BrowserDebugPort] = []
    for app in NSWorkspace.shared.runningApplications {
        guard let bundleID = app.bundleIdentifier,
              browserBundleIDs.contains(bundleID) else { continue }

        // Inspect arguments for --remote-debugging-port=N
        if let args = processArguments(for: app.processIdentifier),
           let port = parseRemoteDebuggingPort(from: args) {
            results.append(.init(pid: app.processIdentifier,
                                 bundleID: bundleID,
                                 port: port,
                                 profilePath: parseUserDataDir(from: args)))
        }

        // Also check if the browser opened a port via lsof scan
        // (catches --remote-debugging-pipe → fallback ephemeral ports)
        let listeningPorts = listeningPortsForPid(app.processIdentifier)
        for port in listeningPorts where !results.contains(where: { $0.port == port }) {
            // Verify it's actually a CDP port by GET /json/version
            if isCDPPort(host: "127.0.0.1", port: port) {
                results.append(.init(pid: app.processIdentifier,
                                     bundleID: bundleID,
                                     port: port,
                                     profilePath: nil))
            }
        }
    }
    return results
}
```

### Polling cadence

- On daemon start: discover immediately
- Subscribe to `NSWorkspace.didLaunchApplicationNotification` and `didTerminateApplicationNotification` to react to browser launches/exits
- Poll every 5s as defense-in-depth (catches debug ports opened mid-run)

---

## 6. Port hijack via pf

To intercept connections, we redirect traffic to a port the daemon controls.

### macOS pf rules

When a browser debug port is discovered:

```
# Redirect traffic to the browser's debug port to our proxy
rdr on lo0 inet proto tcp from any to 127.0.0.1 port 9222 -> 127.0.0.1 port 49222
```

Where `49222` is the daemon's listener port. The daemon then proxies allowed connections back to `127.0.0.1:9222` (the real browser port).

### pfctl management

The daemon owns a dedicated pf anchor:

```
# /etc/pf.anchors/com.sanctuary
rdr on lo0 inet proto tcp from any to 127.0.0.1 port 9222 -> 127.0.0.1 port 49222
```

Loaded into pf via:

```bash
pfctl -a com.sanctuary -f /etc/pf.anchors/com.sanctuary
```

pf must be enabled (`pfctl -e`). On macOS pf is disabled by default but is installed. The daemon checks state on startup and enables pf in the `com.sanctuary` anchor only — never touches the global ruleset.

### Cleanup on shutdown

The daemon flushes the anchor on exit:

```bash
pfctl -a com.sanctuary -F all
```

Crash recovery: on next start, daemon flushes and rebuilds the anchor.

### Privilege

`pfctl` requires root. Sanctuary daemon already runs as root (LaunchDaemon). No additional privilege needed.

---

## 7. Proxy listener behavior

```swift
class CDPProxyListener {
    let listenerPort: UInt16  // 49222

    func handleNewConnection(_ conn: NWConnection) {
        // Step 1: get peer pid
        guard let peerPid = peerPid(of: conn) else {
            // Can't attribute → fail closed for protected port
            if connectionIsToProtectedPort(conn) {
                conn.cancel()
                logUnattributableBlock(conn)
                return
            }
            // Non-protected port → splice through
            spliceToRealPort(conn)
            return
        }

        // Step 2: classify peer
        let identity = ProcessIdentity.fetch(pid: peerPid)
        let verdict = AgentClassifier.shared.classify(identity)

        // Step 3: decide
        switch verdict {
        case .agent:
            // Send a 403 over HTTP if the request is HTTP, otherwise just close
            sendHTTPRefusal(conn)
            conn.cancel()
            auditLog.record(.cdpDeny(peer: identity,
                                     port: connectionTargetPort(conn)))

        case .suspicious:
            // Surface UI prompt; meanwhile hold the connection 250ms then close
            // (CDP clients don't tolerate long stalls; better to fail than hang)
            uiPromptQueue.enqueue(.cdpAttempt(identity: identity))
            conn.cancel()
            auditLog.record(.cdpSuspicious(peer: identity))

        case .notAgent:
            spliceToRealPort(conn)
        }
    }

    func spliceToRealPort(_ clientConn: NWConnection) {
        let realPort = realPortForRedirected(clientConn)
        let serverConn = NWConnection(to: .hostPort(host: "127.0.0.1",
                                                    port: realPort),
                                      using: .tcp)
        // Bidirectional splice with no buffering
        bidirectionalCopy(clientConn, serverConn)
    }
}
```

### HTTP refusal payload (when peer speaks HTTP first)

If we detect an HTTP request line in the first bytes (peer is hitting `/json/version` or similar):

```
HTTP/1.1 403 Forbidden
Content-Type: text/plain
Connection: close

Sanctuary blocked CDP access from agent process. See sanctuary log for details.
```

For raw WebSocket upgrades (already past HTTP): just close the connection. The agent's CDP client will see ECONNREFUSED equivalent and surface its own error.

---

## 8. Protected profile vs unprotected profile

Not every CDP connection is malicious. A user may legitimately want to debug their own browser session. CDP Guard only blocks connections to **protected profiles**, not all CDP traffic.

### Profile registration

```bash
sanctuary protect-profile "/Users/tgg/Library/Application Support/Google/Chrome/Default"
sanctuary protect-profile "/Users/tgg/Library/Application Support/BraveSoftware/Brave-Browser/Default"
```

Stored in policy DB:

```sql
CREATE TABLE protected_profiles (
    id INTEGER PRIMARY KEY,
    profile_path TEXT NOT NULL UNIQUE,
    bundle_id TEXT,
    added_at INTEGER NOT NULL
);
```

### Determining the profile of a CDP session

The CDP server's `/json/version` endpoint includes a `userDataDir` field on recent Chromium versions. Without it: parse `--user-data-dir` from the browser process arguments. A browser launched without `--user-data-dir` uses the default profile path for that browser.

When CDP Guard intercepts a connection:

1. Look up which browser pid owns the target debug port (we know this from discovery)
2. Look up that browser's `userDataDir` (cached at discovery time)
3. Check `protected_profiles` for a match

### Default protected profiles in v0.1

When the user first installs Sanctuary, prompt to auto-protect:

- Default Chrome profile: `~/Library/Application Support/Google/Chrome/Default`
- Default Brave profile: `~/Library/Application Support/BraveSoftware/Brave-Browser/Default`
- Default Arc profile: `~/Library/Application Support/Arc/User Data/Default`

User can decline and add manually later. Conservative default: protect on prompt-accept; do not auto-protect silently.

---

## 9. Agent-launched Chromium (the Playwright case)

Playwright/Puppeteer agents launch their own Chromium with `--remote-debugging-port=0` (ephemeral port). This Chromium is parented to the agent process.

CDP Guard's behavior:

1. Discovery sees a new browser process appear
2. Classifier sees the parent is an agent → this Chromium is itself an agent
3. Any CDP traffic to this ephemeral port is by-definition agent-controlled
4. **No interception needed.** This Chromium has no protected profile (it's a fresh user-data-dir in `/tmp`)

The danger isn't this Chromium driving its own fresh profile — it has no wallets, no passwords. The danger is this agent then using `connectOverCDP` to attach to the **user's** real browser. That's caught by §7's classifier check on the proxy listener for the real browser's debug port.

---

## 10. Failure modes

| Failure | Behavior |
|---|---|
| Daemon starts but can't bind listener port | Disable CDP Guard, alert via menu bar, audit log warning. Other Sanctuary features keep working. |
| pf rule installation fails | Same as above. CDP Guard disabled but Sanctuary still runs. |
| Browser opens debug port between polls | Caught by next poll (5s window) or by NSWorkspace launch notification (immediate). Worst case: 5s exposure window on browser launch. |
| Peer pid attribution fails | Per §4: fail closed for protected ports. Connection dropped. |
| Real browser port becomes unreachable mid-splice | Existing connections drop naturally. No recovery needed. |
| User runs Chrome from a non-`/Applications` path | Discovery via NSWorkspace still catches it (uses bundle ID, not path). Manual `--remote-debugging-port` argv parsing still works. |
| Network framework `NWConnection` peer-pid lookup not supported on user's macOS version | Fall back to Approach B (`proc_pidfdinfo`). Logged at install time. |

---

## 11. Test plan

### Unit tests

1. Parse `--remote-debugging-port=9222` from argv → returns 9222
2. Parse `--remote-debugging-port 9222` (space form) → returns 9222
3. Parse `--remote-debugging-port=0` → returns 0 (ephemeral)
4. Parse missing `--remote-debugging-port` → nil
5. Parse `--user-data-dir=/foo` → returns "/foo"
6. Parse `--user-data-dir "/foo bar"` → returns "/foo bar"
7. `isCDPPort` GETs /json/version, returns true on JSON with `webSocketDebuggerUrl`
8. `isCDPPort` returns false on non-CDP HTTP server
9. `isCDPPort` returns false on connection refused
10. pf anchor file generation: emits valid `rdr` rules
11. pf anchor file generation: empty when no protected profiles
12. Profile path matcher: exact match, normalized
13. Profile path matcher: trailing slash normalized
14. Profile path matcher: realpath resolved (symlinks)

### Integration tests (require real Chrome)

15. Launch Chrome with `--remote-debugging-port=9222`. Connect from a non-agent process. Expect: connection succeeds, /json/version returned.
16. Same setup. Connect from a user-tagged agent process. Expect: connection refused, audit log entry.
17. Launch Chrome with default profile. `sanctuary protect-profile` it. Repeat (16). Expect: same — agent blocked.
18. Launch Chrome with default profile, NOT protected. Connect from agent. Expect: connection allowed (because profile not protected). Audit log records as `.cdpAllow(unprotected)`.
19. Drop pf rules manually mid-test (`pfctl -a com.sanctuary -F all`). Verify daemon detects within 5s and reinstalls.
20. Browser launches mid-test. Verify discovery picks it up within 5s.

### Demo path test (the launch video)

21. Real testnet MetaMask wallet, $10 testnet ETH. Run drain-attack agent skill against unprotected Chrome. Wallet drains. Restore. Enable Sanctuary, protect profile, repeat. Wallet untouched. Audit log shows the attempt with peer pid, peer path, timestamp.

This is the test that gates the launch video. It must pass in a recordable, reproducible way before week 5.

---

## 12. Definition of done

CDP Guard v1 is done when:

- [ ] All 14 unit tests in §11 pass via `swift test`
- [ ] Integration tests 15-20 pass on a clean macOS Sonoma+ machine
- [ ] Demo path test 21 passes and is recordable
- [ ] Discovery latency < 5s after browser launch
- [ ] Proxy splice adds < 5ms latency on allowed connections (measure: WebSocket round-trip time)
- [ ] Daemon survives `pfctl -F all` (manual flush) without crashing; reinstalls anchor within 5s
- [ ] No false positives on integration test set (regular browser usage with no agent)
- [ ] CLI commands `sanctuary protect-profile` / `unprotect-profile` / `list-profiles` work end-to-end
- [ ] Menu bar surfaces protected profiles list with toggles

---

## 13. Open implementation questions

1. **`NWConnection` peer pid availability**: confirm during implementation whether `NWConnection.metadata(definition: NWProtocolTCP.definition).effectiveRemoteEndpoint` (or equivalent) returns peer pid for loopback. If not, use `proc_pidfdinfo` fallback path; document the perf delta.
2. **HTTPS CDP**: some browsers may support TLS-wrapped CDP. v0.1 assumes plaintext localhost (the documented norm). If a TLS variant emerges, add to v0.2 backlog.
3. **Browser sandboxing**: Chrome's network process is separate from the renderer. Confirm the listening socket is owned by the main browser pid (it should be), not a helper. If owned by a helper, discovery needs to walk to the parent.
4. **Arc's data layout**: Arc uses non-standard profile paths. Validate the default profile path during implementation; user-data-dir argv parsing should still work.
