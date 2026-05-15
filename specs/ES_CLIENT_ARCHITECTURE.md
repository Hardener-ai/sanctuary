# ES_CLIENT_ARCHITECTURE

**Status**: v0.2 architecture spec
**Owner**: SanctuaryEndpointSecurity, SanctuaryDaemon
**Related specs**: `APPLE_ES_APPLICATION.md`, `CLASSIFIER_SPEC.md`, `CAPABILITY_SCOPING_SPEC.md`, `HUMAN_APPROVAL_SPEC.md`, `INVISIBILITY_SPEC.md`, `TAMPER_RESISTANCE_SPEC.md`, `THREAT_MODEL.md`

---

## 1. Process Boundary and Rationale

Sanctuary v0.2 introduces a dedicated Endpoint Security client process with the
bundle ID `ai.hardener.sanctuary.endpointsecurity`. The ES client is separate
from both the menu bar app and the daemon.

The separation exists for two reasons.

First, it keeps entitlement scope tight. The Endpoint Security entitlement is
powerful and reviewed by Apple as a security-sensitive capability. The binary
that holds `com.apple.developer.endpoint-security.client` should be as small
and auditable as possible. It should subscribe to ES events, perform hot-path
policy checks, and communicate with the daemon. It should not own UI state,
fleet policy sync, onboarding, or general product behavior.

Second, it reduces review and update surface. The daemon can evolve its policy
database, audit-log plumbing, SDK server, and menu bar IPC without every daemon
change being coupled to the entitled ES client binary. The ES client can be
reviewed as a narrowly scoped enforcement component.

The downside is real. A separate ES client introduces another process, another
IPC boundary, another lifecycle to supervise, and a potential extra round trip
on the hottest path in the product: authorization events such as
`ES_EVENT_TYPE_AUTH_OPEN`. File-open latency budgets are tight. A naive design
that calls the daemon for every auth event would make Sanctuary feel slow and
would increase the risk of ES timeouts.

Sanctuary mitigates that cost with a hot local decision cache inside the ES
client. The daemon remains the source of truth for policy, grants,
classification, and audit. The ES client keeps enough signed or epoch-bound
state locally to answer common auth decisions without IPC. It calls the daemon
only on cache miss, pending approval, epoch mismatch, or explicit invalidation.

This spec documents that boundary. If implementation proves the separate
process model cannot meet the latency budget, the fallback is daemon-as-ES
client. That fallback is simpler, but it widens the entitled binary and should
be treated as a deliberate architecture change, not an incidental shortcut.

## 2. Hot Path: `AUTH_*` Decision Flow

The ES client subscribes to the narrow event set documented in
`APPLE_ES_APPLICATION.md`. Auth-class events are handled synchronously and must
return an allow, deny, or invisibility-equivalent response within Apple's ES
deadline.

The hot path has three modes:

1. **Cache hit:** the ES client decides locally with zero daemon IPC.
2. **Cache miss:** the ES client performs a synchronous daemon round trip.
3. **Pending approval:** the ES client holds the auth decision while the daemon
   asks the menu bar app to present a human approval flow.

### 2.1. Cache Structure

The local cache is keyed by the facts needed to make a safe decision:

- `policy_epoch`
- `agent_instance_id`
- `session_id`, when the process belongs to a cooperative SDK session
- `grant_id`, when the operation is covered by a specific grant
- ES event class, for example `AUTH_OPEN` or `AUTH_CREATE`
- normalized operation, for example `file.read`, `file.write`, `file.delete`,
  or `exec.shell`
- normalized resource scope, for example protected path prefix, exact path,
  extension-storage materialized path, or executable path
- process identity fingerprint, including pid, executable path, code-signing
  state, and parent-chain attribution
- decision result and expiration

The cache is scoped to the current boot, current ES client instance, and current
daemon policy epoch. It is not an authority. It is a performance copy of daemon
policy state.

Resource matching must use canonicalized paths and explicit scope semantics. A
cached allow for `~/Projects/app` does not imply access to `~/.ssh`, even if the
agent supplies a path with symlinks or `..` segments. Protected-resource checks
run before cooperative grant checks.

### 2.2. Cache Hit Path

On an auth event, the ES client:

1. Extracts process identity from the ES message audit token.
2. Looks up the process in the local process/session table.
3. Normalizes the requested operation and resource.
4. Checks whether the local cache entry matches the current `policy_epoch`.
5. Applies the cached decision.
6. Appends a durable audit intent to the local ES WAL.
7. Returns the ES authorization response.

The cache-hit path must perform no daemon IPC. The target added latency for
`AUTH_OPEN` cache hits is less than 100 microseconds.

### 2.3. Cache Miss Path

On cache miss, the ES client asks the daemon for a decision over the Unix domain
socket at `~/Library/Application Support/sanctuary/daemon.sock`. The request
contains only policy-relevant metadata:

- ES event class
- normalized operation
- normalized resource scope
- process identity and parent-chain attribution
- session and grant identifiers if known
- current ES client policy epoch

The daemon returns:

- decision: allow, deny, invisible, or pending approval
- policy epoch used for the decision
- matching rule or grant identifier
- cacheability: cacheable, non-cacheable, or cache-until timestamp
- audit classification

If the daemon returns allow, deny, or invisible, the ES client writes the audit
intent to the WAL, updates the hot cache if permitted, and answers the ES event.

The target added latency for cache misses is less than 5 milliseconds when the
daemon is healthy and no human approval is required.

### 2.4. Pending Approval Path

Some decisions require human approval per `HUMAN_APPROVAL_SPEC.md`. In that
case the daemon returns `pending_approval` with an approval handle. The daemon
asks the menu bar app to present the prompt. The ES client holds the auth
decision until one of these happens:

- user approves: ES client allows the operation, records the grant, and caches
  according to returned scope
- user denies: ES client denies the operation and records sticky denial for the
  session where applicable
- approval times out: ES client denies sensitive protected-resource operations
  and records timeout
- daemon disconnects: ES client applies the failure policy in section 6

The pending path must stay within ES authorization deadlines. If Apple's
deadline cannot safely support an interactive decision for a given event class,
that class must use denial or invisibility rather than a live prompt.

## 3. Cache Invalidation

Cache invalidation is a correctness boundary, not an optimization detail.
Sanctuary must never keep using a cached allow after the user or policy engine
has revoked it.

### 3.1. Policy Epoch

The daemon owns a monotonically increasing `policy_epoch`. It increments the
epoch on ordinary policy mutations:

- protected resource added or removed
- trusted path added or removed
- agent tag changed
- workspace-scoped exception added, changed, expired, or removed
- fleet policy snapshot updated
- protected extension registry updated

Each daemon decision carries the epoch it was computed against. The ES client
stores that epoch with cache entries. If its local epoch differs from the
daemon's current epoch, cache entries from the old epoch are invalid.

Epoch invalidation is simple and conservative. It is sufficient for normal
mutations, but not sufficient for urgent targeted revocations.

### 3.2. Targeted Push Invalidation

The daemon pushes invalidation messages to the ES client over the same Unix
domain socket channel used for decisions. Targeted invalidation is required for:

- user revokes a grant while a session is active
- user reclassifies an agent as restricted
- menu bar or fleet policy marks a process family untrusted
- daemon detects policy tamper and invalidates derived state
- grant expires before the cache entry's ordinary TTL

Invalidation keys:

- `grant_id`
- `session_id`
- `agent_instance_id`
- resource scope
- event class / operation class
- process identity fingerprint, when invalidating one process without killing a
  whole session

The ES client acknowledges invalidations. Until acknowledged, the daemon treats
the ES client as potentially stale and may surface degraded health in the menu
bar. If acknowledgement fails, the daemon can force an ES client restart.

### 3.3. Revocation Semantics

Revocation is effective at the next authorization boundary. Sanctuary does not
attempt to stop an operation that the kernel has already authorized and that is
already in progress. It does prevent subsequent auth events using the revoked
grant.

For high-risk grants, revocation also removes related cache entries by
`agent_instance_id` and resource scope, not only by `grant_id`. This prevents a
new grant from accidentally inheriting stale allow state.

Agent reclassification is broader than grant revocation. If a user marks an
agent restricted, all allows for that `agent_instance_id` and its inherited
process tree are invalidated immediately.

## 4. Audit Durability

The ES client must not make auth decisions that disappear from the audit trail.
Fire-and-forget audit buffering is not acceptable for a product that promises
tamper-evident audit.

The ES client writes every auth decision to a local write-ahead log before
responding to the kernel. The daemon drains that WAL and folds entries into the
signed SHA-256 hash-chain audit log.

### 4.1. WAL Location

The WAL lives in a daemon-owned application support directory:

```text
~/Library/Application Support/sanctuary/es-client.wal
```

The production path may move to a root-owned LaunchDaemon support directory if
the ES client runs as root. The invariant is that the path is local, protected
from ordinary user edits, and owned by the Sanctuary runtime, not by an agent.

### 4.2. WAL Format

The WAL is append-only JSONL using canonical JSON for each line. Each entry
contains:

- `wal_entry_id`
- monotonic local sequence number
- ES client `instance_uuid`
- daemon `policy_epoch`
- event class and normalized operation
- process identity fingerprint
- session / grant identifiers where known
- normalized target summary
- decision
- timestamp
- previous WAL entry hash
- entry hash

The WAL chain is separate from the primary audit hash chain. It exists to make
undrained ES decisions durable and tamper-evident until the daemon incorporates
them into the main audit log.

The WAL must not include environment variable values or file contents. Paths
follow the privacy rules in `THREAT_MODEL.md` and `COVERAGE_GAPS.md`.

### 4.3. Append Semantics

For auth decisions, WAL append happens before the ES authorization response.
The append is designed to be fast and local. It must not wait for daemon IPC or
hash-chain audit persistence.

If the ES client cannot append the WAL entry:

- protected-resource operations fail closed
- low-risk operations may fail open only if the failure policy allows it
- the daemon and menu bar show degraded audit health

### 4.4. Drain Protocol

The daemon drains WAL entries in order. For each entry it:

1. verifies JSON parse and WAL hash continuity
2. validates ES client `instance_uuid` and signing context where available
3. appends a corresponding event to the signed main audit log
4. records the highest drained WAL sequence
5. acknowledges drain progress to the ES client

The ES client may compact or rotate WAL segments only after daemon
acknowledgement. Unacknowledged entries must survive ES client restart.

### 4.5. Daemon Restart

If the daemon restarts while the ES client continues running, the ES client
keeps appending to its WAL and serves cacheable decisions whose epoch is still
valid. It attempts to reconnect. On reconnect, it sends:

- ES client `instance_uuid`
- current policy epoch known to the ES client
- highest WAL sequence appended
- highest daemon-acknowledged WAL sequence

The daemon then drains missing WAL entries before accepting the ES client's
state as healthy.

## 5. Crash Recovery

Crash recovery must distinguish honest crashes from tamper.

### 5.1. ES Client Restart

On startup, the ES client opens its WAL before subscribing to new auth events.
It verifies continuity from the last daemon-acknowledged sequence through the
tail. It then reconnects to the daemon and requests policy state.

The ES client must replay or expose undrained WAL entries before accepting a
fresh policy epoch as clean. This prevents a crash from erasing decisions that
were already made.

### 5.2. WAL Integrity Check

If the WAL fails to parse, has a broken hash chain, has a missing sequence, or
contains an entry from an unexpected ES client instance, the ES client reports
`AUDIT_GAP_DETECTED` to the daemon. The daemon surfaces degraded audit health
in the menu bar and starts a fresh WAL segment only after preserving the
corrupted segment for inspection.

`TAMPER_DETECTED` is reserved for actual interference signals, such as
unexpected file replacement, permission mutation, WAL deletion while the ES
client was healthy, or repeated corruption after restart. Honest crashes with
intact WAL replay produce recovery events, not tamper events.

### 5.3. Daemon Recovery

On daemon restart, the daemon treats the ES client as stale until:

1. the ES client reconnects
2. WAL drain catches up
3. policy epoch is synchronized
4. targeted invalidation channel is active

Until then, the menu bar shows degraded enforcement health. The daemon does not
pretend ES enforcement is healthy merely because the ES client process exists.

## 6. Failure Modes

### 6.1. Daemon Unreachable

If the ES client cannot reach the daemon:

- `AUTH_OPEN` and related file operations on known protected paths fail closed
  or return invisibility semantics where supported.
- operations outside protected resources fail open by default, with WAL audit
  entries marking the daemon as unreachable.
- cached allow decisions may continue only if the cache entry is still within
  TTL and does not require a fresh epoch check.
- any operation requiring human approval fails closed.

This policy keeps the machine usable while preserving protection for the
resources Sanctuary explicitly promises to protect.

### 6.2. ES Client Unreachable from Daemon

If the daemon cannot reach the ES client, the daemon marks ES enforcement
degraded. The menu bar shows a warning. v0.1 detection, CDP Guard, audit, and
policy UI continue to operate, but v0.2 ES denial or invisibility is not
represented as healthy.

If the ES client was previously healthy and disappears unexpectedly, the daemon
records a peer-disconnect event. Repeated or suspicious disappearance can
escalate to `TAMPER_DETECTED` according to `TAMPER_RESISTANCE_SPEC.md`.

### 6.3. WAL Corruption

WAL corruption triggers:

1. stop compacting or deleting the damaged segment
2. preserve the segment for inspection
3. report `AUDIT_GAP_DETECTED`
4. start a fresh WAL segment with a genesis marker referencing the damaged
   segment hash if available
5. continue operation under degraded audit health

Protected-resource operations may fail closed while audit health is degraded,
depending on user or fleet policy.

### 6.4. Cache Staleness

If the ES client detects an epoch mismatch but cannot fetch fresh policy, it
must not use old cached allows for protected resources. For non-sensitive
events, it may fail open with degraded audit. For sensitive events, it fails
closed or returns invisibility.

### 6.5. Approval Timeout

If a human approval request times out, the decision is denial for critical and
high-risk resources. The timeout itself is audited. Repeated timeout-driven
requests from the same agent are rate-limited to avoid prompt fatigue.

## 7. Performance Budgets

The separate-process model is acceptable only if the common path is fast.

Targets:

- cache hit on `AUTH_OPEN`: less than 100 microseconds added latency
- cache miss with healthy daemon: less than 5 milliseconds added latency
- WAL append: must not block on daemon IPC
- targeted invalidation propagation: less than 100 milliseconds under normal
  load
- daemon reconnect and WAL drain after ordinary restart: less than 2 seconds
  for small WAL backlog

Performance tests must include:

- repeated file opens inside a normal project tree
- protected-path direct open
- parent directory enumeration for invisibility
- grant revocation under load
- daemon restart while ES client is active
- WAL drain with thousands of pending decisions

If the ES client cannot meet the cache-hit budget, implementation must revisit
the process-boundary decision before v0.2 ships.

## 8. Open Questions

These questions should be resolved during the v0.2 milestone 1 design pass:

1. Should the ES client hold a read-only signed policy snapshot on disk, or
   build its cache only from daemon decisions after startup?
2. What is the exact normalized resource-scope representation shared between
   daemon and ES client?
3. Which ES auth events can safely support a pending human approval path before
   Apple's deadline forces denial?
4. Should shell-spawned child trees inherit session context indefinitely, or
   should `exec.shell` grants cap inheritance depth until a child re-justifies?
5. Where should the production WAL live if the ES client runs as root while
   the menu bar app runs as the user?
6. Should WAL entries be signed by the ES client, or is hash continuity plus
   file ownership sufficient before daemon ingestion?
7. What is the threshold between `AUDIT_GAP_DETECTED` and `TAMPER_DETECTED` for
   repeated WAL corruption?
8. How does Hardener Cloud fleet policy participate in epoch changes without
   making cloud availability part of the ES hot path?
