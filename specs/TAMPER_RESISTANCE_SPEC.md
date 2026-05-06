# TAMPER_RESISTANCE_SPEC

**Component**: Sanctuary self-defense and tamper visibility  
**Status**: v0.2-v1.0 architecture spec  
**Owner**: SanctuaryDaemon, SanctuaryMenuBar  
**Related specs**: `CLASSIFIER_SPEC.md`, `CDP_GUARD_SPEC.md`, `FSEVENTS_DETECTION_SPEC.md`, `AGENT_REGISTRY_SPEC.md`, `APPLE_ES_APPLICATION.md`

---

## 1. Threat Model

The adversary is an AI agent process that has already gained root on the user's Mac. It may have escalated through a local vulnerability, a malicious dependency, social engineering of the user, or a separate exploit chain. Sanctuary v0.1 assumes agents usually run with user privileges. This document covers the harder v0.2 question: what happens after that assumption fails.

A root-privileged agent can kill processes, modify files, load and unload launchd jobs, edit LaunchDaemon plists, flush `pf` rules, delete package receipts, replace Sanctuary binaries, edit user defaults, modify SQLite policy state, remove or truncate audit logs, and install persistence mechanisms. It can also run `launchctl`, `pfctl`, `sqlite3`, `codesign`, `chflags`, and `rm` with elevated privileges. If the user granted broad `NOPASSWD` sudo to an agent, the adversary can perform most of these actions without another prompt.

We assume the adversary cannot bypass Apple's Secure Enclave without a known vulnerability. We assume it cannot modify hardware, defeat T2 or Apple Silicon startup integrity, bypass code signing on signed Apple system binaries, or silently forge a valid Developer ID signature for Sanctuary. We also assume FileVault, SIP, and the system volume seal behave as designed.

Tamper resistance is defense-in-depth. A sufficiently sophisticated root-privileged adversary will eventually win on the local machine. Sanctuary's goal is not to make tamper impossible. The goal is to make defeating Sanctuary expensive, slow, and visible. We convert silent compromise into loud compromise. Users should see that protection was disabled, audit state was modified, or enforcement rules were flushed.

## 2. What v0.1 Already Does

Sanctuary v0.1 has several partial self-defense properties.

The daemon is installed as a LaunchDaemon with `KeepAlive: true`. This restarts `sanctuaryd` after a crash or ordinary process exit. The gap is that `KeepAlive` does not help if an adversary uses `launchctl bootout`, removes the plist, disables the SMAppService registration, or replaces the daemon binary before launchd restarts it.

Audit log entries are individually signed. The production design uses `CryptoKit.Curve25519.Signing.PrivateKey` stored through modern Keychain `SecItem` APIs. Development ad-hoc builds fall back to an in-memory key to avoid repeated keychain prompts. The gap is that signatures do not prevent deletion, truncation, rollback, or removal of the signing key. They only make forged or modified lines detectable.

CDP Guard uses a `com.apple/250.SanctuaryRedirect` `pf` anchor namespace. This avoids editing `/etc/pf.conf` and prevents Sanctuary from clobbering user-maintained packet filter configuration. The gap is that root can still run `pfctl -F all`, flush the anchor, or load a conflicting rule set.

SMAppService registration means the menu bar app registers the daemon through Apple's blessed service-management flow. Unregistration requires admin authorization in normal operation. The gap is that root can directly manipulate launchd state, remove bundle contents, or use the same admin channel to unregister.

Bundle ID and LaunchDaemon label matching reduce accidental impostor loading. The daemon label is `ai.hardener.sanctuary.daemon`, and the menu bar app bundle is `ai.hardener.sanctuary.menubar`. The gap is that bundle IDs are metadata. They are meaningful only when paired with code signature validation.

## 3. Attack Surfaces (v0.2 Scope)

### 3.1. Daemon process (`sanctuaryd`)

The daemon can be killed with `kill`, `launchctl kill`, Activity Monitor, or direct root process management. v0.1 relies on LaunchDaemon `KeepAlive`. v0.2 adds peer monitoring between daemon and menu bar app, launchd job-state polling, and Endpoint Security signal authorization when the entitlement is granted.

### 3.2. LaunchDaemon plist

The LaunchDaemon plist can be removed, edited, unloaded, or replaced. v0.1 bundles a plist inside the menu bar app and registers it through SMAppService. v0.2 verifies the active launchd job label, expected program path, and code signature of the referenced executable. Missing or mutated state produces `TAMPER_DETECTED`.

### 3.3. `pf` anchor rules

The CDP redirect anchor can be flushed or replaced. v0.1 installs rules and cleans them on shutdown. v0.2 revalidates anchor contents every 30 seconds, reloads expected rules when missing, and logs tamper when rules disappear outside Sanctuary's own stop path.

### 3.4. Audit log file

The audit log can be deleted, truncated, appended with fake lines, or rolled back to an older copy. v0.1 signs each line and links entries with a SHA-256 hash chain, making deletion from the middle, forged replacement, and rollback visible during verification. Rotated logs get `chflags uchg` in v0.2 to raise the cost of modification.

### 3.5. Policy database (SQLite)

The policy database can be edited directly to remove protected folders, remove extension protections, or add trusted paths. v0.1 stores policy rows in SQLite without row-level integrity. v0.2 signs policy rows with a key stored in the System keychain, rejects rows whose integrity checks fail, and surfaces tamper.

### 3.6. Sanctuary binaries

The menu bar app or daemon can be replaced with a neutered binary. v0.1 relies on bundle layout and launchd configuration. v0.2 requires Developer ID signing and validates the daemon's own code signature at launch with `SecCodeCopySelf` and `SecCodeCheckValidity`. XPC peers are verified before commands are accepted.

### 3.7. Inventory snapshot

`/var/db/sanctuary/inventory.json` can be deleted or forged to hide running agents from the menu bar. v0.1 treats it as a convenience snapshot, not policy authority. v0.2 signs snapshots or marks them explicitly untrusted. If the snapshot is missing, the UI must say "daemon unavailable" rather than showing a clean machine.

### 3.8. Audit signing key

The audit signing key can be deleted from Keychain or replaced if the adversary controls root and user authorization. v0.1 stores production keys through `SecItemAdd` and `SecItemCopyMatching` using `kSecClassGenericPassword`, `kSecAttrService`, `kSecAttrAccount`, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. v0.2 detects key replacement by recording the public key fingerprint in the app bundle's signed resources and in the audit header.

### 3.9. SMAppService registration state

The registration can be disabled through the normal admin path or manipulated by root. v0.1 can show daemon status. v0.2 polls `SMAppService.daemon(plistName:).status`, correlates it with launchd state, and alerts on unexpected transitions.

### 3.10. User defaults / preferences

User defaults can be edited to hide onboarding, suppress UI warnings, or mark setup complete. v0.1 uses defaults for UX state only. v0.2 keeps security-relevant state in the policy database and treats preferences as untrusted hints. A modified preference may change presentation, but it cannot disable protection.

## 4. Defense Mechanisms

### 4.1. Daemon watchdog with peer monitoring

IMPLEMENTED in v0.1: Sanctuary uses LaunchDaemon `KeepAlive` plus peer monitoring between the menu bar app and `sanctuaryd`. Each side generates a fresh startup UUID. The menu bar app pings the daemon every 10 seconds through a local Unix domain socket, and the daemon records menu bar peer liveness when pings arrive. If the menu bar app disappears, the daemon records an informational peer-disconnect event only, because the user may legitimately quit the UI.

The tamper-sensitive direction is daemon disappearance. If the menu bar app expects protection to be running and receives three consecutive ping failures over the 30-second budget, it surfaces a red tamper state and writes `TAMPER_DETECTED` with reason `peer_unresponsive`. If the daemon returns with the same UUID, the peer is marked recovered. If it returns with a new UUID, the peer is marked restarted. v0.2 still adds launchd job-state polling with safe `launchctl list`-style metadata, not `launchctl print`, to avoid environment leakage.

The tradeoff is false positives during upgrades, restarts, and user logout. Sanctuary should suppress peer alerts during a signed, expected update window and during normal shutdown. It should never suppress unexpected disappearance while protections are active.

### 4.2. Tamper-evident audit log

IMPLEMENTED in v0.1: the audit log is a hash chain. Each entry includes `prevHash`, computed over the canonical JSON of the previous signed entry, including that entry's Ed25519 signature. Each entry is also signed with the production audit key in the System keychain. This is stronger than independent signatures: deleting the middle of the file or rolling back to an old copy breaks continuity.

Rotated logs are marked immutable with `chflags uchg`. Root can remove `uchg` with `chflags nouchg`, so this is not a hard barrier. It is a friction and evidence layer. Removing the flag should itself be detected through periodic file metadata checks and, when Endpoint Security is available, through `ES_EVENT_TYPE_NOTIFY_SETFLAGS` / related file metadata notifications where supported.

v0.3 may add off-machine encrypted replication. That is the forensic answer to local root compromise. It must be explicit opt-in because Sanctuary's privacy posture is local-first.

### 4.3. `pf` rule re-validation

IMPLEMENTED in v0.1: CDP Guard stores the expected redirect rules in memory and re-validates the Sanctuary pf anchor every 30 seconds while protection is active. The revalidator runs `pfctl` with explicit argument arrays against `com.apple/250.SanctuaryRedirect`, compares normalized rule structure internally, and does not log raw rule contents.

When rules are flushed or modified, Sanctuary reloads macOS' default `/etc/pf.conf` anchor scaffold, reloads its own anchor, writes `PF_RULES_MISSING` or `PF_RULES_MODIFIED`, writes a `TAMPER_DETECTED` audit entry with reason `pf_rules_flushed` or `pf_rules_modified`, and changes the dropdown state to a warning or red repeated-tamper state. It rate-limits retries so a broken `pfctl` or disabled packet filter does not create a busy loop.

Endpoint Security does not expose a public `es_event_pf_anchor_*` event. With the ES entitlement, Sanctuary can prevent common tamper paths by authorizing `pfctl` execution (`ES_EVENT_TYPE_AUTH_EXEC`) and observing writes or unlinks to anchor files (`ES_EVENT_TYPE_NOTIFY_OPEN`, `ES_EVENT_TYPE_AUTH_UNLINK`, `ES_EVENT_TYPE_NOTIFY_RENAME`). Direct kernel packet-filter state still requires validation.

### 4.4. Code signature self-verification

v0.2 requires Developer ID signed builds for production tamper resistance. The daemon verifies itself at startup using `SecCodeCopySelf`, `SecCodeCopySigningInformation`, and `SecCodeCheckValidity`. It compares the team identifier, signing identifier, and designated requirement against values shipped in the signed app bundle.

When the daemon accepts privileged commands from the menu bar app over XPC, it verifies the peer using the XPC audit token. The implementation should use `xpc_connection_get_audit_token`, create a `SecCode` object for that audit token, and validate the same Developer ID requirement. If validation fails, the daemon refuses the command and logs to Apple Unified Logging and the tamper-evident audit log if available.

This mitigates binary replacement. It does not help ad-hoc dev builds, and the dev path must say so clearly.

### 4.5. Policy database integrity

v0.2 adds row-level integrity to `protected_folders`, `protected_extensions`, `user_tagged_agents`, and `trusted_paths`. Each row carries an HMAC over stable fields such as `(table, id, path, source, added_at, updated_at)` using a key stored through Keychain `SecItem` APIs. The HMAC can use `CryptoKit.HMAC<SHA256>` or CommonCrypto `CCHmac`.

On read, Sanctuary verifies the HMAC before using the row. Rows that fail are ignored and generate `TAMPER_DETECTED`. This mitigates direct SQLite edits that remove protections or add trusted paths. The tradeoff is read latency. That is acceptable because the daemon caches authoritative policy in memory and refreshes only on startup or DB change.

### 4.6. Sealed-secret state release (v0.3)

v0.3 can store "always protected" user intentions under a Secure Enclave-backed key. Key generation uses Keychain attributes such as `kSecAttrTokenIDSecureEnclave`, access control requiring biometry, and a private key that never leaves the enclave. Disabling protection requires Touch ID or equivalent local owner presence even if an adversary has sudo.

This mitigates silent disable by a root-privileged agent with broad sudo rights. It depends on Apple Developer Program enrollment, production signing, and correct LocalAuthentication behavior. It is deferred because v0.2 should first ship visible tamper detection.

### 4.7. Visible tamper UI

v0.2 adds a prominent tamper state to the menu bar dropdown. The shield becomes red, the status row says what changed, and the activity feed shows the tamper event above ordinary detections. Notification Center also shows a local notification for tamper. v0.3 paid plans may add SMS or email notification, but only after explicit opt-in.

The UI must avoid vague warnings. "Protection may be disabled" is not enough. It should say "Sanctuary pf rules were flushed and reloaded" or "Sanctuary daemon was unloaded from launchd."

### 4.8. Endpoint Security real-time prevention

If Apple grants `com.apple.developer.endpoint-security.client`, Sanctuary can move from detection to prevention for several tamper paths.

It can subscribe to `ES_EVENT_TYPE_AUTH_SIGNAL` to deny `SIGTERM` and `SIGKILL` delivered to `sanctuaryd`, except from signed Sanctuary updater processes and expected system shutdown contexts. It can use `ES_EVENT_TYPE_AUTH_UNLINK` and `ES_EVENT_TYPE_AUTH_RENAME` to prevent deletion or replacement of `/var/db/sanctuary/audit.log`, rotated logs, policy DB files, and LaunchDaemon plists. It can use `ES_EVENT_TYPE_AUTH_EXEC` to authorize `launchctl`, `pfctl`, `sqlite3`, and shell invocations whose arguments match known tamper patterns.

Without ES, Sanctuary remains detection-after-the-fact for these surfaces.

## 5. macOS API Considerations

Secure Enclave key generation uses Keychain APIs with `kSecAttrTokenIDSecureEnclave`, `SecAccessControlCreateWithFlags`, and LocalAuthentication policies. Some flows require entitlements and production signing. These are not assumed in ad-hoc builds.

HMAC computation for policy rows can use `CryptoKit.HMAC<SHA256>` or CommonCrypto `CCHmac`. Audit log line signatures already use CryptoKit Ed25519 signing. Hash chains use `SHA256`.

`chflags uchg` marks rotated logs immutable. Root can remove it. The value is evidence and delay, not absolute prevention.

launchd has throttle behavior to prevent rapid restart loops. The watchdog must distinguish crash loops from tamper and surface both.

Endpoint Security gives process-kill, unlink, rename, and exec authorization layers if Apple grants `com.apple.developer.endpoint-security.client`. This document supports `APPLE_ES_APPLICATION.md`.

XPC peer verification depends on audit tokens. The daemon should verify callers with `xpc_connection_get_audit_token`, `SecCodeCopyGuestWithAttributes`, and `SecCodeCheckValidity`.

## 6. Implementation Phases

Phase 1, v0.2, after Apple ES entitlement or in parallel where possible:

- Daemon watchdog peer monitoring (implemented in v0.1; launchd-state polling remains v0.2).
- `pf` rule re-validation and auto-reload (implemented in v0.1; ES-backed prevention remains conditional).
- Tamper-evident audit log hash chain.
- Code signature self-verification.
- Visible tamper UI and Notification Center alerts.
- ES real-time prevention where entitlement approval permits it.

Phase 2, v0.3, after Network Extension or Secure Enclave work is stable:

- Policy database HMAC integrity.
- Sealed-secret state release for always-protected intent.
- Optional off-machine encrypted audit replication.

Phase 3, v1.0, enterprise features:

- Hardware key attestation.
- EDR API integration if Apple grants an enterprise tier.
- Compliance audit reports for SOC 2 and ISO 27001 workflows.

## 7. Testing Strategy

Every tamper mechanism gets an e2e scenario:

- `scenario-tamper-kill-daemon.sh`: send `SIGTERM` and, with ES enabled, attempt `SIGKILL`.
- `scenario-tamper-launchctl-unload.sh`: unload or boot out the daemon.
- `scenario-tamper-flush-pf.sh`: run `pfctl -F all`.
- `scenario-tamper-modify-audit.sh`: truncate the audit log and append a fake entry.
- `scenario-tamper-modify-db.sh`: edit SQLite rows with `sqlite3`.
- `scenario-tamper-replace-binary.sh`: replace the daemon with an unsigned fixture.
- `scenario-tamper-disable-via-defaults.sh`: edit onboarding, alert, and protection preferences.

Each scenario triggers tamper, verifies detection within 30 seconds, verifies recovery within 60 seconds for recoverable tamper, and verifies a `TAMPER_DETECTED` audit entry. Alert delivery must happen within 5 seconds after detection. The e2e suite should run in two modes: non-ES detection-only and ES prevention mode.

## 8. Known Limitations

A sufficiently sophisticated rootkit can defeat all of this. A malicious kernel extension, a compromised boot chain, or a targeted Secure Enclave vulnerability is outside Sanctuary's control.

Sanctuary raises the cost of attack and turns silent attacks into visible ones. It is not a replacement for hardware security keys, FileVault, Lockdown Mode, dedicated security workstations, or sound operational practice. High-assurance users should combine Sanctuary with hardware-backed authentication and separate machines for high-value wallet operations.

Cold boot attacks and attacks against Secure Enclave-stored secrets are out of scope.

## 9. Decision Log

**Hash chain over signatures alone**: independent signatures detect modified lines, but they do not prove continuity. A hash chain makes truncation, deletion from the middle, and rollback visible.

**Peer monitoring over a third watchdog daemon**: a third privileged daemon increases install complexity and creates another binary to protect. The menu bar app and daemon already exist, so they can watch each other with less surface area.

**Sealed-secret release deferred to v0.3**: it is powerful but requires careful Secure Enclave UX and entitlement work. v0.2 should first make tamper visible and recoverable.

**ES prevention conditional on entitlement**: Endpoint Security is the right primitive for real-time kill, unlink, rename, and exec authorization. Sanctuary cannot assume entitlement approval. The v0.2 design must degrade to detection without lying to users.

**No kext or custom system extension for v0.2**: kernel extensions are deprecated and inappropriate for a consumer security product. A DriverKit or Network Extension path does not solve filesystem or process-kill tamper. Endpoint Security is the Apple-supported path.
