# FSEVENTS_DETECTION_SPEC

**Component**: `Sources/SanctuaryCore/FSEventsDetection/`
**Status**: spec for v1 implementation
**Owner**: SanctuaryDaemon
**Critical path rank**: 5 of 6 — ships v0.1 detection, upgrades to ES enforcement in v0.2

---

## 1. Purpose

Sanctuary's strongest filesystem story (synchronous deny via Endpoint Security) requires Apple's `com.apple.developer.endpoint-security.client` entitlement, which takes 4-12 weeks. This component is the v0.1 stand-in: detect protected-resource access by agent processes via FSEvents, log it, alert the user, and surface it in the audit log. Detection-only — no synchronous block.

This is the honest fallback. We ship knowing the gap and we tell users about it.

When Apple grants the entitlement, the ES-based enforcement layer slots in alongside this one without replacing it (FSEvents stays useful for higher-level events like "directory tree changed"). Until then, FSEvents is the only filesystem signal Sanctuary has.

---

## 2. What we can and cannot do

### What FSEvents gives us

FSEvents reports filesystem **changes** asynchronously, batched in ~10ms-1s windows depending on the flag set. With `kFSEventStreamCreateFlagFileEvents`, we get per-file events including reads on macOS recent versions. We get:

- Path of the changed file
- Event flags (created, modified, removed, renamed, plus `ItemInodeMetaMod` for access time updates)
- Event ID (monotonic)
- Timestamp (approximate, within FSEvents' batching window)

### What FSEvents does NOT give us

- The **pid** of the process that caused the event
- Synchronous control (the operation has already completed when we hear about it)
- Reliable detection of pure-read operations on every macOS version (read events are best-effort)

The missing pid is the most important gap. It means we cannot directly say "agent X read file Y." We can only say "file Y was accessed at time T, and at time T agent X was running." That's a correlation, not an attribution.

### How we close the gap

We pair FSEvents with **process accounting**: a continuously-updated map of `(pid, executable_path, agent_verdict, fds_open)` derived from `proc_listpids` polling and `proc_pidfdinfo` enumeration. When an FSEvents event fires, we ask: "which currently-running agent processes have this file (or its parent directory) in their open fd set?"

This gives us a probable attribution — not certain, but actionable. If we have an open fd to the file from agent process X within a 1-second window of the event, we attribute the access to X.

Confidence levels in the audit log:

- **Definite**: open fd matches at event time → attribute to that pid
- **Probable**: open fd matched within 5s before event → likely that pid
- **Correlated**: agent was running, no fd evidence → "agent activity coincided"
- **Unknown**: no agents running at event time → log without attribution (still useful — protected file accessed)

---

## 3. Architecture

```
┌──────────────────────────────────────────────┐
│         FSEventsDetection Module             │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │ FSEvents Stream                         │  │
│  │  - per-protected-path watcher           │  │
│  │  - flags: FileEvents + WatchRoot        │  │
│  │  - latency: 100ms                       │  │
│  └────────────────────┬───────────────────┘  │
│                       │                      │
│  ┌────────────────────▼───────────────────┐  │
│  │ Process FD Index (refreshed 500ms)      │  │
│  │  pid → set<vnode_id, path>              │  │
│  │  built from proc_pidfdinfo              │  │
│  │  filtered to agent pids only            │  │
│  └────────────────────┬───────────────────┘  │
│                       │                      │
│  ┌────────────────────▼───────────────────┐  │
│  │ Attribution Engine                      │  │
│  │  event(path, ts) →                      │  │
│  │    matching agent pids with open fd     │  │
│  │    or recent agent activity             │  │
│  │  → AttributionResult                    │  │
│  └────────────────────┬───────────────────┘  │
│                       │                      │
│  ┌────────────────────▼───────────────────┐  │
│  │ Audit Logger + Alert Dispatcher        │  │
│  │  - log entry per event                  │  │
│  │  - menu bar live feed                   │  │
│  │  - notification center alert            │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

---

## 4. Watched paths

Two sources of watched paths:

### 4a. User-protected folders

Anything from `sanctuary protect <folder>` populates the `protected_folders` table:

```sql
CREATE TABLE protected_folders (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    added_at INTEGER NOT NULL
);
```

### 4b. Sanctuary defaults

On first install, Sanctuary auto-protects (with consent prompt):

```
~/.ssh
~/.aws
~/.gnupg
~/.config/solana
~/.config/sui
~/.bitcoin
~/Library/Application Support/io.kek-wallet
~/Library/Application Support/Electrum
~/Library/Application Support/Bitcoin
~/Library/Application Support/Ethereum
~/Library/Application Support/Ledger Live
~/Library/Application Support/Exodus
~/Library/Application Support/Atomic
~/.electron-cash
```

The menu bar prompt looks like:

> **Protect default sensitive folders?**
>
> ☑ ~/.ssh (SSH keys)
> ☑ ~/.aws (AWS credentials)
> ☑ ~/.gnupg (PGP keys)
> ☑ Wallet app data folders (Ledger Live, Electrum, Exodus, Atomic, etc.)
>
> [Protect Selected] [Skip]

Same model as extension storage prompt: defaults checked, user opts out per-item.

### 4c. Extension storage paths (handled by EXTENSION_STORAGE_SPEC)

Those paths come pre-registered via that spec's flow. FSEvents Detection accepts them as inputs but doesn't manage them.

### Combined watch list

At daemon start, the watch list is:

```
union(
  protected_folders.path,
  default_sensitive_paths_user_accepted,
  extension_storage.materialized_paths
)
```

One FSEvents stream per top-level distinct path. Subdirectory watching is implicit (FSEvents covers descendants).

---

## 5. Process FD index

The attribution engine needs a fast lookup: "given a vnode_id (or path), which agent pids have it open?"

### Data structure

```swift
struct AgentFDIndex {
    var pidToFDs: [pid_t: Set<FDEntry>]
    var pathToPids: [String: Set<pid_t>]
    var lastRefresh: Date
}

struct FDEntry: Hashable {
    let fd: Int32
    let vnodeID: UInt64
    let path: String?  // best-effort resolution
}
```

### Refresh cadence

- Initial build: on daemon start
- Periodic: every 500ms (covers most agent fd churn)
- Event-driven: on `ES_EVENT_TYPE_NOTIFY_OPEN` if entitlement granted (post-v0.2). Without ES, polling is the only option.

### Cost

500ms refresh of `proc_pidfdinfo` for every agent process is cheap if we filter to agents only. On a machine with 5 agent processes each holding ~30 fds = 150 fd lookups every 500ms = 300/s. Negligible.

We do NOT enumerate fds for non-agent processes. We only need to know what agents have open.

### Stale-but-bounded

A 500ms refresh window means our fd index can be up to 500ms stale. That's fine for "probable" attribution. For "definite" attribution (open at event time), we accept that the agent may have closed the fd between event and our next index refresh — in that case attribution downgrades to "probable" and we log accordingly.

---

## 6. Attribution flow

```swift
struct FSEvent {
    let path: String
    let flags: FSEventStreamEventFlags
    let timestamp: Date
}

enum AttributionResult {
    case definite(pid: pid_t, identity: ProcessIdentity)
    case probable(pid: pid_t, identity: ProcessIdentity, ageSec: TimeInterval)
    case correlated(agentPids: [pid_t])
    case unattributed
}

func attribute(_ event: FSEvent) -> AttributionResult {
    // Step 1: definite check
    if let pid = fdIndex.pathToPids[event.path]?.first {
        return .definite(pid: pid, identity: ProcessIdentity.fetch(pid: pid))
    }

    // Step 2: parent dir definite check (some events report directory)
    let parent = (event.path as NSString).deletingLastPathComponent
    if let pid = fdIndex.pathToPids[parent]?.first {
        return .definite(pid: pid, identity: ProcessIdentity.fetch(pid: pid))
    }

    // Step 3: probable — fd recently held
    if let recent = fdHistory.recentlyHeldBy(path: event.path,
                                              within: 5.0,
                                              of: event.timestamp) {
        return .probable(pid: recent.pid,
                         identity: ProcessIdentity.fetch(pid: recent.pid),
                         ageSec: recent.ageSec)
    }

    // Step 4: correlated — agents running but no fd evidence
    let agents = AgentClassifier.shared.runningAgents()
    if !agents.isEmpty {
        return .correlated(agentPids: agents.map { $0.pid })
    }

    // Step 5: nothing
    return .unattributed
}
```

---

## 7. Alerting

Each event produces one audit log entry and may produce one user-facing alert.

### Audit log entry

```json
{
  "ts": "2026-05-04T13:21:09Z",
  "kind": "fs_access",
  "path": "/Users/tgg/.ssh/id_rsa",
  "flags": ["read", "fileEvents"],
  "attribution": {
    "level": "probable",
    "pid": 4421,
    "process": {
      "path": "/usr/local/bin/claude",
      "signing_id": "..."
    },
    "age_sec": 1.2
  },
  "policy": "protected_folder",
  "action": "DETECT_ALERT"
}
```

The `action` is always `DETECT_ALERT` in v0.1 (we cannot deny). When ES lands in v0.2, this becomes `DENY_READ` for the same event.

### User-facing alert

Three escalation levels based on attribution and frequency:

| Trigger | Alert |
|---|---|
| Definite/probable agent access to default-protected file | macOS notification + menu bar badge |
| Definite/probable agent access to user-protected folder | macOS notification + menu bar badge |
| Correlated (no fd evidence) | menu bar log entry only — no notification (too noisy) |
| Unattributed | menu bar log entry only |
| Repeated access (same agent + path within 60s) | suppress notifications, count visible in menu bar |

Notifications must be **specific and actionable**:

> 🛡 Sanctuary Alert
> claude (pid 4421) read your SSH key (~/.ssh/id_rsa).
> Sanctuary detected this. Click to review.

Clicking opens menu bar dropdown with the audit log entry expanded.

### Why detect-but-don't-block instead of block-via-LaunchAgent-tricks

We can't synchronously block via FSEvents. Some products try to "block" by killing the offending process after the event. We deliberately do NOT do this:

- The read has already happened by the time we'd kill
- Killing legitimate processes that turned out to be misclassified is destructive
- Honest detection is better than false enforcement

When ES entitlement lands, real synchronous deny replaces this. Until then, we give the user awareness — which is more than they have today.

---

## 8. Performance budget

- FSEvents stream callback overhead: < 1ms per event (just enqueues for async processing)
- Attribution: < 10ms per event (cached fd index lookup is microseconds; the cost is `ProcessIdentity.fetch` on cache miss, ~5ms)
- Audit log write: < 5ms (append + signed line; fsync per entry is fine at expected event volume)
- Notification dispatch: bounded by macOS NotificationCenter; we throttle to max 3 notifications per 60s window per (agent, path) pair to avoid spam

Steady state expected event volume on a developer machine with default protections: < 1 event/min. Bursts during agent activity: tens to hundreds of events/min for a few seconds. Budget must hold during bursts.

---

## 9. Storage

Audit log file: `/var/db/sanctuary/audit.log`. Same file that the Endpoint Security path writes to (when v0.2 lands). One JSONL line per event. Rotation: when file exceeds 100MB, rotate to `audit.log.1`, retain 5 generations.

Signed: each line includes an Ed25519 signature over the line content. Daemon's signing key is stored in the System keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Verification: `sanctuary verify-log` walks the file checking signatures; tampered lines flagged.

---

## 10. Test plan

### Unit tests

1. FSEvent dispatcher routes events to the correct watched-path bucket
2. Attribution `.definite` when fdIndex has matching path
3. Attribution `.probable` when fdHistory has entry within 5s
4. Attribution `.correlated` when agents running but no fd
5. Attribution `.unattributed` when no agents running
6. Notification throttle: 4th event within 60s for same (pid, path) suppresses notification but still logs
7. Audit log line format matches schema
8. Audit log line signature verifies
9. Audit log rotation at 100MB
10. Default-protected paths list expands `~` correctly per-user

### Integration tests (require real filesystem)

11. Register `/tmp/sanctuary-test-folder` as protected. Touch file inside it from non-agent shell. Verify event detected, attribution `.unattributed`, audit log written, **no notification** (because not an agent).
12. Same setup. Touch file from a user-tagged-agent process (test harness sets up a tagged binary). Verify attribution `.definite` or `.probable`, notification dispatched, audit log written.
13. Open file from agent process, hold fd, then touch via non-agent. Verify attribution does NOT incorrectly assign to the agent merely because they have an fd open (the event was caused by the non-agent — but our attribution is correlation-based, so this WILL false-positive. Document as known limitation in audit log entries marked `.probable`.)
14. Burst test: 100 events in 1s. Verify no event drops, all logged, attribution correct on at least 95.
15. Process FD index refresh: agent opens fd, wait 500ms, verify index sees it. Agent closes, wait 500ms, verify index reflects close.

### Edge cases

16. Watched path is deleted entirely (e.g., user removes ~/.ssh). FSEvents stream stays subscribed; daemon logs "watched path no longer exists" once and continues.
17. Watched path is recreated after deletion. Events resume.
18. Symlink protection: `sanctuary protect ~/Vault` where Vault is a symlink to `/Volumes/External/Vault`. Verify both paths watched after symlink resolution.
19. Watched path on external volume that gets unmounted. Stream pauses; logs warning. Resumes on remount.

---

## 11. Definition of done

- [ ] All unit tests in §10 pass
- [ ] Integration tests 11-15 pass
- [ ] Edge cases 16-19 handled with no crashes
- [ ] Performance budget in §8 met
- [ ] Default-protected paths prompt working in menu bar first-run
- [ ] CLI: `sanctuary protect <path>`, `sanctuary unprotect <path>`, `sanctuary list` work
- [ ] Audit log signing + verification working
- [ ] Notification throttling working
- [ ] Documented user-facing copy explaining "detection-only" vs ES enforcement, so users understand what v0.1 does and does not block

---

## 12. v0.2 upgrade path

When ES entitlement is granted:

1. Add ES extension target to project
2. Subscribe to `ES_EVENT_TYPE_AUTH_OPEN`, `AUTH_READDIR`, `AUTH_GETATTRLIST` for protected paths
3. On AUTH event from agent peer: deny (returns ENOENT), write audit log entry with `action: DENY_READ`
4. FSEvents stream stays in place: catches anything ES misses (unlikely but useful as belt-and-suspenders), and provides higher-level events ES doesn't (e.g., directory rename)
5. User-facing copy updates: "detect" becomes "block"
6. Audit log schema unchanged (already supports both `DETECT_ALERT` and `DENY_READ`)

The point: nothing about FSEvents Detection has to be torn out when ES arrives. The two layers compose. This is intentional.

---

## 13. Open implementation questions

1. **Read-event reliability across macOS versions**: confirm `kFSEventStreamCreateFlagFileEvents` reports reads consistently on Sonoma, Sequoia. If reads aren't reliable on some versions, we lose the most important signal.
2. **`vnode_id` from FSEvents vs from `proc_pidfdinfo`**: confirm they match. Without matching IDs, fd-based attribution falls back to path-based which is less reliable when paths get renamed.
3. **System Integrity Protection**: some paths under `/System` and `/Library` are SIP-protected. We don't watch those by default but if user-added, FSEvents may not fire for them. Document.
4. **Extended attributes / xattr access**: not currently in our event flag set. Some attacks read xattr (e.g., quarantine flags). Add to v0.2 backlog.
