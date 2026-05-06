# COVERAGE_GAPS

**Status**: v0.1 operational gap inventory  
**Audience**: users making deployment decisions, contributors choosing high-impact work, security reviewers  
**Derived from**: `THREAT_MODEL.md` §4  
**Related specs**: `CLASSIFIER_SPEC.md`, `CDP_GUARD_SPEC.md`, `FSEVENTS_DETECTION_SPEC.md`, `TAMPER_RESISTANCE_SPEC.md`, `APPLE_ES_APPLICATION.md`

---

## 1. Purpose

This document is a frank inventory of what Sanctuary does not yet protect. It is organized by attack surface. For each gap, it states what is missing, why it is not covered in v0.1, what would be needed to close it, the likely target release, and what users can do today.

This document should be uncomfortable to read. Sanctuary v0.1 is useful, but it is not a complete endpoint security product. It has one real-time block: CDP attachment to protected Chromium profiles. Filesystem and extension-storage protections are detection-only until Apple grants Endpoint Security entitlement. Anything else should be treated as future work unless explicitly stated.

Use this document with `THREAT_MODEL.md`. The threat model explains boundaries. This file turns those boundaries into an operational queue.

## 2. Gap Inventory

### Gap 1: Filesystem read prevention

**Status:** Detection only

**What's missing:** v0.1 detects agent reads of protected folders and wallet extension storage after FSEvents reports activity. It does not stop the read before data reaches the agent.

**Why not in v0.1:** macOS FSEvents is asynchronous. It provides path activity but not synchronous authorization. Blocking reads requires Endpoint Security `ES_EVENT_TYPE_AUTH_OPEN`, and Apple must grant `com.apple.developer.endpoint-security.client`.

**What's needed:** ES client entitlement, a System Extension or privileged daemon integration that handles `AUTH_OPEN`, classifier lookup on the hot path, and careful timeout behavior so normal filesystem operations do not stall.

**Target release:** v0.2, awaiting Apple.

**User mitigation today:** Treat v0.1 filesystem alerts as evidence and early warning. Keep high-value secrets out of agent-accessible working directories. Use hardware-backed keys where possible. Do not run agents in shells with broad access to wallet or cloud directories.

**Severity:** High.

### Gap 2: Filesystem write prevention

**Status:** Detection only

**What's missing:** v0.1 can observe writes, deletes, and metadata changes under protected paths, but it cannot deny them.

**Why not in v0.1:** Same entitlement gap as read prevention. FSEvents reports after the write. Synchronous denial requires Endpoint Security authorization events such as `ES_EVENT_TYPE_AUTH_OPEN`, and in some cases rename/unlink authorization.

**What's needed:** ES enforcement for writes, renames, unlinks, and directory enumeration, plus policy decisions for whether some writes by non-agent tools should remain allowed.

**Target release:** v0.2, awaiting Apple.

**User mitigation today:** Keep backups of important config and wallet directories. Watch the signed audit feed. Use Git or backup tools for configuration folders where rollback matters.

**Severity:** Medium. Write-based wallet drain is less common than read or browser-control attacks, but tampering with keys and configs matters.

### Gap 3: Clipboard sniffing

**Status:** Not covered

**What's missing:** Agents can read pasteboard contents if macOS and the user's permissions allow it. Wallet addresses, seed phrases, OTPs, and API keys often pass through the clipboard.

**Why not in v0.1:** Clipboard monitoring is privacy-sensitive and not part of the CDP or FSEvents path. A naive implementation would itself become a sensitive-data collector.

**What's needed:** A pasteboard policy design, TCC-aware UX, local-only handling, and likely a separate prompt model. macOS pasteboard APIs can observe changes, but preventing reads by another process is not straightforward without broader OS support.

**Target release:** v0.3 candidate.

**User mitigation today:** Avoid copying seed phrases or private keys. Clear clipboard after wallet operations. Prefer QR or hardware-wallet flows that do not expose secrets to the clipboard.

**Severity:** High.

### Gap 4: Screen capture

**Status:** Not covered

**What's missing:** A process with Screen Recording permission can see wallet UIs, QR codes, recovery phrases, and password manager windows.

**Why not in v0.1:** Sanctuary does not inspect TCC databases or screen-capture permissions yet. Blocking capture is an OS-level permission problem, not an FSEvents problem.

**What's needed:** TCC state inspection, a UI that warns when classified agents have Screen Recording permission, and possibly guided revocation. Prevention depends on macOS TCC, not Sanctuary alone.

**Target release:** v0.3 candidate.

**User mitigation today:** Do not grant Screen Recording to agents or terminals that run agents. Review System Settings -> Privacy & Security -> Screen Recording.

**Severity:** High.

### Gap 5: Accessibility API automation

**Status:** Not covered

**What's missing:** Agents with Accessibility permission can click buttons, type text, and drive browser or wallet UI without CDP.

**Why not in v0.1:** The v0.1 real-time block is CDP-specific. Accessibility automation uses TCC-granted UI control and does not flow through the CDP proxy.

**What's needed:** TCC permission inspection, classification of processes with Accessibility grants, warnings in the menu bar, and possibly a setup flow that asks users to revoke Accessibility from agent-hosting apps.

**Target release:** v0.3 candidate.

**User mitigation today:** Do not grant Accessibility to agent terminals, IDEs, or browser automation tools unless absolutely required. Review Accessibility permissions regularly.

**Severity:** High.

### Gap 6: Raw process memory reads

**Status:** Not covered

**What's missing:** Sanctuary does not prevent `task_for_pid`, debugger attachment, or raw process memory inspection.

**Why not in v0.1:** This requires deeper process authorization and observation. macOS already restricts many paths through SIP, hardened runtime, taskgated, and entitlements, but Sanctuary does not add a layer here.

**What's needed:** Endpoint Security coverage where available, audit-token-aware process monitoring, and a precise policy that avoids breaking legitimate debuggers.

**Target release:** v0.3 or later, depending on ES scope.

**User mitigation today:** Do not run agents as root. Avoid granting developer/debug entitlements broadly. Keep wallets and password managers updated with hardened runtime protections.

**Severity:** Medium.

### Gap 7: Network egress to data exfil destinations

**Status:** Not covered

**What's missing:** If an agent reads data, Sanctuary v0.1 does not stop it from sending that data to a remote server.

**Why not in v0.1:** Network filtering requires a different primitive. CDP Guard uses `pf` narrowly for loopback browser debug ports, not general egress policy. A real product-grade egress layer likely needs Network Extension entitlement.

**What's needed:** Network Extension entitlement, per-process flow attribution, destination allowlists, UX for prompts, and care around developer workflows that legitimately contact APIs.

**Target release:** v0.3 candidate with Network Extension entitlement.

**User mitigation today:** Use Little Snitch or LuLu for network egress control. Restrict agent API keys. Run agents in environments without broad outbound access when handling secrets.

**Severity:** High.

### Gap 8: Keychain access

**Status:** Not covered

**What's missing:** Sanctuary does not sit in front of Keychain item queries or prevent an agent from triggering Keychain prompts.

**Why not in v0.1:** Keychain has its own ACL and user-consent model. Sanctuary currently protects filesystem, extension storage, and CDP. Keychain query mediation is a separate surface.

**What's needed:** ES-supported observation of keychain-related tools where possible, audit-token correlation, UI warnings when agents invoke `security` or request access, and careful avoidance of logging secret values.

**Target release:** v0.3 or later.

**User mitigation today:** Do not approve Keychain prompts you did not initiate. Keep agent processes out of trusted terminal sessions during sensitive work.

**Severity:** Medium.

### Gap 9: `DYLD_INSERT_LIBRARIES` injection

**Status:** Not covered

**What's missing:** Sanctuary does not detect or prevent dynamic-library injection into user-space processes.

**Why not in v0.1:** SIP, hardened runtime, and library validation already block many common injection paths. The remaining cases need process launch monitoring and code-signing analysis.

**What's needed:** ES exec monitoring, environment-name inspection for launch context, and rules that avoid false positives in legitimate development workflows.

**Target release:** Eventually, no committed v0.2 target.

**User mitigation today:** Keep SIP enabled. Avoid disabling library validation. Do not run wallet or password manager apps from modified launch environments.

**Severity:** Low.

### Gap 10: Browser extension installation or permission elevation

**Status:** Not covered

**What's missing:** An agent could install a malicious extension, modify browser extension state, or guide the user into granting extension permissions that later drain wallets.

**Why not in v0.1:** Sanctuary watches known extension storage and blocks CDP attachment. It does not monitor browser extension installation events or browser permission prompts.

**What's needed:** Browser-profile change monitoring, extension manifest inspection, detection of new extension IDs, and UI that distinguishes expected installs from suspicious ones.

**Target release:** v0.3 or later.

**User mitigation today:** Install extensions only from official sources. Review browser extension permissions. Use separate browser profiles for wallets.

**Severity:** Medium.

### Gap 11: Tamper resistance against root agents

**Status:** Partial

**What's missing:** A root-privileged agent can edit policy DB state, remove logs, replace binaries, or repeatedly tamper with `pf`. v0.1 now makes audit-log edits and rollback visible with a SHA-256 hash chain, detects unexpected daemon disappearance through peer monitoring, and detects/reloads flushed or modified CDP Guard pf rules. It does not prevent deletion of the whole local log or stop root from repeatedly disabling local controls.

**Why not in v0.1:** Real tamper resistance requires a combination of production signing, Endpoint Security, code signature self-verification, policy integrity, and prevention hooks. v0.1 ships tamper-evident audit continuity, peer-disconnect alerts, and pf auto-reload, but not the full prevention stack.

**What's needed:** The remaining mechanisms in `TAMPER_RESISTANCE_SPEC.md`: launchd-state polling, code signature checks, policy row HMACs, immutable rotated logs, and ES prevention if granted. Hash-chained audit logs, peer watchdog detection, and pf rule re-validation are implemented in v0.1.

**Target release:** v0.2 for detection and recovery; ES prevention awaiting Apple.

**User mitigation today:** Do not grant agents broad sudo. Avoid `NOPASSWD` for agent-run commands. Treat root-capable agents as fully trusted or do not run them.

**Severity:** High for users running agents with sudo.

### Gap 12: Firefox profile coverage

**Status:** Not covered

**What's missing:** v0.1 extension storage materialization is Chromium-focused. Firefox profiles use different paths and storage formats.

**Why not in v0.1:** The demo and initial wallet coverage centered on Chromium browsers because CDP Guard is Chromium-specific and wallet extension usage is concentrated there.

**What's needed:** Firefox profile discovery, extension ID mapping, storage path materialization, tests, and wallet registry entries for Firefox variants.

**Target release:** v0.3 or later.

**User mitigation today:** Use a protected Chromium profile for wallet operations if relying on Sanctuary v0.1. Avoid storing high-value wallet state in Firefox until coverage lands.

**Severity:** Medium.

### Gap 13: Safari coverage

**Status:** Not covered

**What's missing:** Safari extensions use a different app-extension model and storage layout. Sanctuary v0.1 does not cover Safari wallet or password manager extension storage.

**Why not in v0.1:** Safari protection requires different discovery and different assumptions from Chromium extension storage. CDP Guard does not apply to Safari.

**What's needed:** Safari extension inventory, container path mapping, TCC considerations, and possibly App Group container handling.

**Target release:** v0.3 or later.

**User mitigation today:** Use a protected Chromium wallet profile for high-risk agent sessions. Keep Safari wallet usage separate from agent workflows.

**Severity:** Medium.

### Gap 14: Network filesystems

**Status:** Partial / uncertain

**What's missing:** Network mounts such as NFS, SMB, and cloud-synced filesystems may not emit FSEvents with the same reliability or latency as local APFS volumes.

**Why not in v0.1:** v0.1 attribution is built on local FSEvents plus local process fd inspection. Remote filesystem semantics vary.

**What's needed:** Per-filesystem testing, explicit support matrix, and possibly ES enforcement for local open attempts even when backing storage is remote.

**Target release:** v0.3 or later.

**User mitigation today:** Keep wallet and key material on local APFS volumes. Do not store secrets on network shares used by agents.

**Severity:** Medium.

### Gap 15: External drives

**Status:** Partial / uncertain

**What's missing:** Wallet data or secrets stored on external drives may not be watched reliably if the drive is mounted after setup or uses an unusual filesystem.

**Why not in v0.1:** The first-run setup focuses on default local paths. External volumes require mount monitoring and per-volume support decisions.

**What's needed:** Disk Arbitration integration, mount/unmount watchers, FSEvents validation per filesystem type, and UI for protecting external paths.

**Target release:** Eventually.

**User mitigation today:** Store high-value secrets on the internal encrypted disk. If using external drives, manually protect the exact mounted path and verify audit entries.

**Severity:** Low.

### Gap 16: Multi-user macOS

**Status:** Not modeled

**What's missing:** v0.1 is designed for a single primary user. It does not fully model fast user switching, agents running in another user's session, or shared protected resources.

**Why not in v0.1:** Consumer launch scope is single-user. Multi-user policy introduces ownership, consent, and audit visibility questions.

**What's needed:** Per-user policy DBs, per-session inventory, clearer launchd boundaries, and UI that does not leak one user's paths to another.

**Target release:** Eventually.

**User mitigation today:** Do not rely on v0.1 for shared Macs. Use separate accounts and do not run agents in accounts that can access another user's secrets.

**Severity:** Low.

### Gap 17: Network-based AI agents

**Status:** Out of scope for v0.1

**What's missing:** Sanctuary detects agents running locally. It does not classify agents running on another machine that access this Mac over SSH, APIs, shared folders, or browser remote-debugging exposed beyond loopback.

**Why not in v0.1:** The process classifier sees local processes. Remote agents appear as local server processes such as `sshd`, file sharing daemons, or browsers.

**What's needed:** Network service inventory, SSH session attribution, remote principal mapping, and likely Network Extension support.

**Target release:** v0.3 or later.

**User mitigation today:** Do not expose CDP ports beyond loopback. Disable remote login when not needed. Avoid mounting secret-bearing folders into remote agent environments.

**Severity:** Medium.

### Gap 18: Agent identity spoofing via parent renaming

**Status:** Partial

**What's missing:** A sophisticated agent can double-fork, rename binaries, avoid known package names, or manipulate parent state to evade classifier rules.

**Why not in v0.1:** `CLASSIFIER_SPEC.md` deliberately balances false positives and false negatives. Overbroad matching would classify ordinary Python, Node, and shell workflows as agents.

**What's needed:** ES exec/fork tracking, stronger process lineage cache, signed registry updates, and possibly user prompts for suspicious-but-not-definite behavior.

**Target release:** v0.3 or later.

**User mitigation today:** Use `sanctuary agents add <path>` for custom agents. Keep agents installed in stable paths. Avoid running unregistered agent frameworks near secrets.

**Severity:** Medium.

### Gap 19: Encrypted browser profiles

**Status:** Partial / uncertain

**What's missing:** Some browser features and profile modes add extra encryption or storage behavior. Sanctuary's extension storage detection may not work uniformly across every profile mode.

**Why not in v0.1:** v0.1 materializes known filesystem paths. It does not reverse-engineer every browser's encryption and storage variant.

**What's needed:** Browser-specific test matrices and explicit compatibility notes.

**Target release:** Eventually.

**User mitigation today:** Verify that protected wallet access produces audit entries on the profile you actually use. Use the e2e scenarios where possible.

**Severity:** Low.

### Gap 20: Local LLMs running models with filesystem access

**Status:** Partial

**What's missing:** Local LLM serving frameworks such as Ollama and LM Studio are classified only if registered, user-tagged, or matched by runtime fingerprints. Custom unregistered local LLM tooling may not classify as an agent.

**Why not in v0.1:** A local model server is not always an agent. Some are passive inference servers; others have tool use and filesystem access. Treating all model servers as agents would create false positives.

**What's needed:** Better registry coverage, tool-use detection, MCP association, and UI for tagging local frameworks.

**Target release:** v0.3 or later.

**User mitigation today:** Add custom model-serving tools with `sanctuary agents add <path>` when they can execute tools or read files. Keep passive inference servers separated from agent orchestration.

**Severity:** Medium.

## 3. Roadmap by Severity

### High severity, v0.2 with ES entitlement

- Gap 1: Filesystem read prevention.
- Gap 2: Filesystem write prevention.
- Gap 11: Tamper resistance against root agents.

### High severity, v0.3 with broader OS integration

- Gap 3: Clipboard sniffing.
- Gap 4: Screen capture.
- Gap 5: Accessibility API automation.
- Gap 7: Network egress to data exfil destinations.

### Medium severity, v0.3 or later

- Gap 6: Raw process memory reads.
- Gap 8: Keychain access.
- Gap 10: Browser extension installation or permission elevation.
- Gap 12: Firefox profile coverage.
- Gap 13: Safari coverage.
- Gap 14: Network filesystems.
- Gap 17: Network-based AI agents.
- Gap 18: Agent identity spoofing via parent renaming.
- Gap 20: Local LLMs running models with filesystem access.

### Low severity, eventually

- Gap 9: `DYLD_INSERT_LIBRARIES` injection.
- Gap 15: External drives.
- Gap 16: Multi-user macOS.
- Gap 19: Encrypted browser profiles.

## 4. How to Help

Contributors should reference the gap number in any PR or issue. For example: "Addresses Gap 12: Firefox profile coverage." This keeps design discussion anchored to an explicit coverage boundary.

Open a GitHub issue before starting substantial work. Many gaps require Apple entitlements, UX decisions, or privacy review before code is useful. Small research PRs are welcome when they add fixtures, compatibility matrices, or documented reproduction steps.

Follow the existing pattern: write or update the spec first, add focused tests, then implement the smallest useful slice. For anything touching process identity, protected paths, audit logs, TCC, Keychain, Network Extension, or Endpoint Security, assume review will be strict.

Do not submit PRs that collect secret values, inspect file contents, or phone home. Sanctuary's privacy posture is part of the security model, not a nice-to-have.

## 5. Severity Classification Methodology

Severity is a product-prioritization heuristic, not a formal CVSS score.

**High** means a frequent or high-impact attack pattern in real-world AI agent use. Wallet drain via CDP, SSH key exfiltration, clipboard theft, Accessibility-driven UI automation, and network exfiltration are high because they map directly to plausible user harm.

**Medium** means plausible but less common, dependent on specific user setup, or partly mitigated by macOS already. Raw process memory reads, Keychain prompts, browser extension installation, Firefox/Safari gaps, remote agents, and classifier evasion sit here.

**Low** means theoretical, uncommon, strongly mitigated by macOS, or dependent on unusual configuration. Injection through `DYLD_INSERT_LIBRARIES`, external-drive secret storage, multi-user Macs, and encrypted profile quirks are lower priority for v0.1 users.

Severity may change. If real attacks shift toward a currently-low gap, the roadmap should change with them.

## 6. Disclosure of New Gaps

If a contributor or researcher finds a coverage gap not listed here, use `SECURITY.md` for sensitive vulnerability reports. Do not file a public GitHub issue if the gap enables immediate bypass against current users.

For non-sensitive gaps, open a GitHub issue and include:

- The affected attack surface.
- Whether the gap is detection, prevention, classification, UI, or documentation.
- Reproduction steps or a minimal proof of concept.
- Whether the gap requires Apple Endpoint Security, Network Extension, TCC, Keychain, or another entitlement.
- Suggested user mitigation, if known.

This document should be updated whenever Sanctuary adds coverage or when a new material gap is discovered.
