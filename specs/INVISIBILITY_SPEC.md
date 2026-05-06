# INVISIBILITY_SPEC

**Status**: v0.2+ architecture spec  
**Owner**: SanctuaryDaemon, future Endpoint Security client  
**Related specs**: `CLASSIFIER_SPEC.md`, `CDP_GUARD_SPEC.md`, `FSEVENTS_DETECTION_SPEC.md`, `EXTENSION_STORAGE_SPEC.md`, `TAMPER_RESISTANCE_SPEC.md`, `THREAT_MODEL.md`, `COVERAGE_GAPS.md`, `EXTENSIBILITY_SPEC.md`, `APPLE_ES_APPLICATION.md`

---

## 1. Purpose

Sanctuary has three protection models on a spectrum.

**Detection**: the agent acts, Sanctuary records the act, and the user sees evidence. This is the v0.1 filesystem model through FSEvents.

**Denial**: the agent acts, Sanctuary records and blocks the act, and the agent receives an error. This is the v0.1 CDP Guard model for protected browser debug ports.

**Invisibility**: the agent looks for the resource, and the resource appears not to exist. The agent does not learn that the resource exists or that Sanctuary intervened.

This document specifies the invisibility model for v0.2 and later. It is the strongest local protection Sanctuary can offer for filesystem and extension-storage resources. It depends on Apple's Endpoint Security entitlement, `com.apple.developer.endpoint-security.client`, requested in `APPLE_ES_APPLICATION.md`.

The audience is v0.2 implementers, security researchers, and Apple's Endpoint Security entitlement reviewer. The goal is to show that Sanctuary's ES use is narrow, defensive, privacy-preserving, and technically grounded.

Important API constraint: Endpoint Security is primarily an authorization API. It can allow or deny operations, and some events provide event-specific response semantics, but it does not generally let clients rewrite arbitrary syscall return values or directory buffers. This spec defines invisibility as the product target. v0.2 implements the closest absence-like behavior the ES API permits, and explicitly records where the platform only supports denial.

## 2. Why Invisibility Is Strictly Stronger

A denied access tells the attacker useful facts:

- The resource exists at this path.
- Some control is preventing access.
- Alternative paths, privilege escalation, parent-process spoofing, or tool changes may be worth trying.

An invisible resource tells the attacker less. The agent cannot distinguish "this user has no password manager" from "this user has Sanctuary protecting password manager storage." It sees the same result it would see on a machine where the resource genuinely does not exist.

This matters for AI agents because many agent plans are deterministic. They enumerate directories, read known files, summarize findings, and move on. An empty enumeration is a valid, common, expected outcome. An `EACCES` or `EPERM` error is a prompt for further action. It may cause the model to try other locations, ask the user for permission, use `sudo`, or report that a security tool is blocking progress.

Invisibility also defends against user-mediated bypass. A denied read can produce an agent message like "I encountered an error reading `~/.aws/credentials`; please grant permission." A helpful user may disable the tool to "fix" the task. If the resource appears absent, the agent has no error to weaponize.

Invisibility is not secrecy against all side channels. It is a per-process filesystem presentation model. It aims to suppress high-signal existence disclosures in normal API results.

## 3. Resource Categories

### 3.1. Folders

Examples include `~/.ssh`, `~/.aws`, `~/.gnupg`, wallet app data folders, and user-added protected folders.

Many legitimate tools need these folders. `git` and `ssh` need SSH keys. `aws`, `gcloud`, and `az` need cloud credentials. Password managers and wallet apps need their own data. Hiding protected folders globally would break ordinary workflows. Invisibility must be agent-scoped: visible to user shells and legitimate tools, invisible to classified agents.

Implementation surfaces:

- `ES_EVENT_TYPE_AUTH_READDIR` for parent directory enumeration.
- `ES_EVENT_TYPE_AUTH_OPEN` for direct file and directory opens.
- `ES_EVENT_TYPE_AUTH_GETATTRLIST`, `ES_EVENT_TYPE_AUTH_GETEXTATTR`, `ES_EVENT_TYPE_AUTH_LISTEXTATTR`, and `ES_EVENT_TYPE_AUTH_READLINK` for metadata and symlink probes.
- `ES_EVENT_TYPE_AUTH_FSGETPATH` where a process tries to resolve a path from a file descriptor.
- `ES_EVENT_TYPE_NOTIFY_STAT` and `ES_EVENT_TYPE_NOTIFY_LOOKUP` for audit and tuning. Current SDK headers expose these as notify events, not auth events, so they cannot directly enforce invisibility.

Hide-vs-deny decision per call:

- Agent calls `readdir` on the home directory: the ideal behavior is to omit `.ssh`, `.aws`, `.gnupg`, and protected children. If ES cannot filter individual directory entries, v0.2 must document the limitation and avoid claiming true enumeration invisibility.
- Agent calls `open("~/.ssh/id_rsa")`: return the closest absence-like failure the ES response API permits. If the kernel maps denial to `EPERM` or `EACCES`, log this as denial-level fallback rather than true invisibility.
- Agent calls metadata APIs against `~/.ssh`: respond as if the path does not exist where the ES API permits it; otherwise deny and log the mismatch.
- Non-agent calls the same operations: allow normally.

False positive risk is real. A legitimate tool misclassified as an agent may see missing credentials and fail in confusing ways. Mitigations are the trusted-path allowlist, the menu bar's visible protection list, and the signed audit log. `CLASSIFIER_SPEC.md` already emphasizes conservative classification because false positives are existential.

### 3.2. Browser wallet extensions

Wallet extensions live inside browser profile directories. Hiding them from agents covers the direct-filesystem attack: an agent bypasses the browser and reads extension storage files, IndexedDB data, LevelDB logs, or cached wallet metadata.

For v0.2, scope is this direct read path. An agent using `sqlite3`, Python, Node, shell tools, or custom code to inspect browser profile state should see protected wallet-extension storage as absent.

Implementation:

- Use the same ES events as folder invisibility.
- Use `KnownExtensions` and `ExtensionPathMaterializer` from `EXTENSION_STORAGE_SPEC.md`.
- Materialized Chromium paths become invisible to classified agents.
- Browser processes, first-party extension hosts, and non-agent user tools continue to access storage normally.

The harder case is agent-driven browser UI extraction. If an agent attaches through CDP and asks the wallet UI for state, CDP Guard handles that through denial in v0.1. Invisibility for browser-mediated UI paths is not v0.2 scope.

### 3.3. Password manager extensions

Password manager extensions follow the same model as wallet extensions. Examples include 1Password, Bitwarden, Dashlane, LastPass, Keeper, NordPass, Enpass, and Proton Pass where extension IDs and paths are known.

Specific consideration: many password managers have native companion apps and helpers. 1Password, for example, uses signed native components and browser integration. Invisibility must not break first-party IPC or storage access. The native app, signed helpers, browser process, and extension runtime are not agents. They must be allowed.

This requires careful code-signing and bundle-identifier checks. A password manager helper signed by the vendor should not be hidden from its own storage simply because it is a background process.

### 3.4. Standalone password manager and wallet apps

Standalone apps such as 1Password.app, Proton Pass.app, Ledger Live.app, Trezor Suite.app, Electrum, Exodus, and other wallet tools store data in Application Support or app container directories. These directories follow the same invisibility model as folders.

The protected directories are hidden from classified agents and visible to the app itself, signed helper processes, and the user. Many such apps use XPC services, login items, browser companions, and updater helpers. The classifier must correctly attribute these as legitimate first-party processes.

The initial registry should be conservative. It is better to protect fewer app data directories accurately than to hide broad `Application Support` paths and break unrelated software.

### 3.5. Cryptocurrency hardware wallet sockets and devices

Hardware wallets such as Ledger, Trezor, Keystone, and similar devices expose themselves through USB, HID, vendor-specific libraries, local sockets, browser bridges, or companion apps. These are not ordinary filesystem resources.

Hardware wallet invisibility is not v0.2 scope. It likely requires USB or HID device access mediation, IOKit observation, DriverKit or other macOS subsystem work, and potentially separate entitlement review. This section exists so the limitation is explicit.

## 4. macOS API Requirements

Invisibility requires the Endpoint Security client entitlement. Without `com.apple.developer.endpoint-security.client`, v0.1 cannot do it. FSEvents can detect after the fact, but cannot alter what a process sees.

ES events needed for v0.2 filesystem invisibility:

- `ES_EVENT_TYPE_AUTH_OPEN`
- `ES_EVENT_TYPE_AUTH_READDIR`
- `ES_EVENT_TYPE_AUTH_GETATTRLIST`
- `ES_EVENT_TYPE_AUTH_GETEXTATTR`
- `ES_EVENT_TYPE_AUTH_LISTEXTATTR`
- `ES_EVENT_TYPE_AUTH_READLINK`
- `ES_EVENT_TYPE_AUTH_FSGETPATH`
- `ES_EVENT_TYPE_AUTH_CREATE`, `ES_EVENT_TYPE_AUTH_RENAME`, `ES_EVENT_TYPE_AUTH_UNLINK`, and `ES_EVENT_TYPE_AUTH_TRUNCATE` for write-side consistency

Process attribution and classifier cache maintenance:

- `ES_EVENT_TYPE_NOTIFY_EXEC`
- `ES_EVENT_TYPE_NOTIFY_FORK`
- `ES_EVENT_TYPE_NOTIFY_EXIT`
- `audit_token_t` from ES messages for definitive process identity

Current SDK caveat: `ES_EVENT_TYPE_NOTIFY_STAT` and `ES_EVENT_TYPE_NOTIFY_LOOKUP` exist as notify events. There is no `ES_EVENT_TYPE_AUTH_STAT` or `ES_EVENT_TYPE_AUTH_LOOKUP` in the local macOS SDK headers checked while drafting this spec. Where the desired invisibility behavior depends on `stat` or path lookup, v0.2 must enforce at the closest available auth surface and use notify events for audit, testing, and gap measurement.

Performance constraints are strict. Filesystem auth events sit on hot paths. The ES handler must respond in tens of microseconds for cached decisions and must avoid synchronous disk, SQLite, network, Keychain, or code-signing work. Classification results must be precomputed and cached by pid plus process start time. Policy path matching must use an in-memory trie or equivalent prefix index. Cache invalidation must happen when user tags, trusted paths, protected folders, or protected extensions change.

## 5. Implementation Phases

Phase 1, v0.2 after ES entitlement:

- Folder invisibility for protected paths.
- Extension storage invisibility for known wallet and password manager extension IDs in Chromium browsers.
- Standalone app data directory invisibility for known password manager and wallet apps.
- Signed audit entries for every invisibility hit.
- Menu bar rendering for recent invisibility hits.

Phase 2, v0.3 after Network Extension entitlement:

- Local socket protection for password manager IPC when a classified agent attempts unauthorized connection.
- DNS or network-level absence semantics for selected cloud password manager API endpoints when accessed from classified agents, if product testing shows this is useful and not confusing.

Phase 3, v1.0 or later:

- USB or HID device mediation for hardware wallets.
- Per-extension-version policy for extension updates that change IDs or storage models.
- Broader non-AI categories if `EXTENSIBILITY_SPEC.md` decision criteria are met.

## 6. UX Implications

Invisibility changes the user contract. Protection is quiet from the agent's point of view, but visible to the user.

When a user installs a new wallet extension, Sanctuary should detect the storage path via FSEvents and the known-extension registry, then surface a notification: "MetaMask detected. Make it invisible to AI agents?" The prompt should offer one-click protection. Once protected, extension storage is invisible to agents.

When a classified agent enumerates hidden paths, Sanctuary logs an `INVISIBILITY_HIT` event. The dropdown shows recent hits with attribution. The user gets evidence that protection mattered without giving the agent a useful error message.

When a user tries to debug why an agent cannot see something, the UI must be honest. The setup/settings flow should show protected folders, wallets, password managers, and trusted exceptions. A power-user mode should allow temporary visibility for legitimate agent workflows. The trusted-path allowlist remains the per-binary escape hatch.

The UI should avoid scary language for ordinary invisibility hits. A hit means protection worked. It is not automatically compromise.

## 7. Failure Modes and Defenses

### 7.1. Classifier false positive

A legitimate tool is classified as an agent and protected resources appear missing. Mitigations: trusted-path allowlist, clear menu bar state, detailed audit log, conservative classifier rules, and easy reporting.

### 7.2. Classifier false negative

An agent is not classified and sees protected resources normally. Mitigation is the same as v0.1: registry breadth, user tagging, parent-chain tracking, runtime fingerprints, and dogfood. Invisibility does not make classification stronger. It makes correct classification more powerful.

### 7.3. Race conditions

ES auth events have time budgets. A cache miss or slow classifier lookup could force a default decision. The implementation should fail open on internal performance failure to avoid hanging the system, but it must log heavily and surface health degradation. Policy-state corruption should fail closed only for narrow, known protected resources where the daemon can still respond safely.

### 7.4. Side-channel disclosure

An agent might detect invisibility through timing, path count differences, inode behavior, error-code inconsistencies, or comparing results through another process. This is acknowledged. v0.2 should aim for normal absence semantics, not perfect indistinguishability. Future work can measure and reduce timing differences.

### 7.5. Existing file descriptors

If an agent already has an open file descriptor to a resource before protection is enabled, invisibility on later `open()` calls does not revoke that handle. Closing another process's file descriptors is high-risk and out of v0.2 scope. The daemon should log this limitation and may warn when enabling protection while agents are already running.

## 8. What Invisibility Doesn't Solve

Invisibility hides resource existence at selected local access surfaces. It does not protect decrypted content in transit or memory.

Out of scope:

- Agents that drive the browser through CDP to extract wallet state through the UI. `CDP_GUARD_SPEC.md` handles this with v0.1 denial.
- Agents that intercept clipboard contents containing decrypted secrets. See `COVERAGE_GAPS.md` Gap 3.
- Agents that capture the screen showing decrypted secrets. See Gap 4.
- Agents using Accessibility APIs to read or drive password manager UI. See Gap 5.
- Agents on another machine accessing this Mac over SSH, shared folders, or network APIs. See Gap 17.
- Root adversaries disabling Sanctuary itself. See `TAMPER_RESISTANCE_SPEC.md`.

Invisibility is one strong layer. It is not the entire defense.

## 9. Comparison to Denial Model

For an agent attempting to read `~/.ssh/id_rsa`:

Denial model:

- `open()` returns `EACCES` or `EPERM`.
- Agent receives "Permission denied."
- Agent reports an error to the orchestrator or user.
- User may grant elevated permissions to resolve the task.

Invisibility model:

- `open()` returns `ENOENT` or the closest absence-like result available through ES response semantics.
- Agent receives "No such file or directory."
- Agent reports "no SSH keys found" or moves on.
- User sees no agent-facing error, but Sanctuary records an `INVISIBILITY_HIT`.

The implementation cost is similar because both require ES authorization. The invisibility model leaks less and creates less user-facing friction. Sanctuary chooses invisibility where the API allows it, and denial where absence cannot be represented safely.

This distinction matters in user-facing claims. "Invisible" is accurate only for operations where Sanctuary can produce absence semantics. Where macOS only permits allow/deny, the UI and documentation must say "blocked" or "denied," not "hidden."

## 10. Decision Log

**Why ENOENT not EACCES**: absence leaks less than denial. `EACCES` confirms a target. `ENOENT` matches the ordinary case where a user does not have the resource.

**Why agent-scoped not global**: protected resources must remain visible to legitimate user workflows. Per-process visibility is the only workable model.

**Why v0.2 not v0.1**: FSEvents cannot alter syscall results. ES entitlement is required.

**Why hardware wallets are out of scope**: hardware wallets use USB, HID, local sockets, browser bridges, and companion apps. That is a different subsystem and likely a different entitlement path.

**Why document SDK caveats**: Apple reviewers and implementers need a realistic event map. If an operation is notify-only in the SDK, Sanctuary must not claim it can enforce there directly.

**Why call this an invisibility spec anyway**: the product goal is still invisibility because it is the better security model. The implementation must be honest about where ES reaches that goal and where it falls back to denial.
