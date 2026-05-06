# THREAT_MODEL

**Status**: Canonical v0.1 threat model  
**Audience**: security researchers, high-value users, integrators, and v0.2/v0.3 design reviewers  
**Related specs**: `CLASSIFIER_SPEC.md`, `CDP_GUARD_SPEC.md`, `FSEVENTS_DETECTION_SPEC.md`, `INVISIBILITY_SPEC.md`, `TAMPER_RESISTANCE_SPEC.md`, `APPLE_ES_APPLICATION.md`

---

## 1. Purpose and Audience

This document is the canonical statement of Sanctuary's threat model. It explains what Sanctuary protects, what it does not protect, what assumptions it makes about macOS, and where future versions will strengthen the model.

The intended readers are security researchers evaluating Sanctuary, users with high-value assets deciding whether to deploy it, integrators building on top of Sanctuary's CLI or daemon surfaces, and future design reviewers for v0.2 and v0.3. It is written for people who need precise boundaries more than reassurance.

This document is not marketing material. It is not a feature roadmap. It is not an implementation guide. Implementation details live in component specs such as `CLASSIFIER_SPEC.md`, `CDP_GUARD_SPEC.md`, `FSEVENTS_DETECTION_SPEC.md`, and `TAMPER_RESISTANCE_SPEC.md`. This document states the security model those components are meant to satisfy.

Sanctuary v0.1 is intentionally narrow. It detects AI agent access to sensitive local resources and blocks one high-impact browser attack path: Chrome DevTools Protocol attachment to protected browser profiles. Filesystem protection in v0.1 is detection-only. Synchronous filesystem denial requires Apple's Endpoint Security entitlement, as described in `APPLE_ES_APPLICATION.md`.

## 2. What Sanctuary Protects

Sanctuary protects local resources that become dangerous when readable or controllable by an AI agent process.

Release labels in this section are security labels, not marketing labels. "Covered in v0.1" may mean detection, blocking, or both. Each asset category states which. v0.1 has one synchronous block: CDP attachment to protected browser profiles. Filesystem and extension-storage protections in v0.1 are detection and audit, not denial.

Sanctuary's protection model spans three tiers. Detection records that an event happened. Denial blocks an event and surfaces an error to the actor. Invisibility prevents the actor from learning the resource exists at all. v0.1 ships detection across all protected surfaces and denial for CDP attachment to protected browser profiles. v0.2, conditional on Apple's Endpoint Security entitlement, will move filesystem and extension-storage protection to the invisibility tier per `INVISIBILITY_SPEC.md`. Invisibility is strictly stronger than denial and is the long-term protection model for resources that should not exist from the agent's perspective.

**Cryptocurrency wallet seeds and private keys**: Wallet app data and extension storage often contain encrypted vault material, local account metadata, and state that can help an attacker drain funds. v0.1 detects agent reads of known wallet extension storage and common wallet app directories through FSEvents and process attribution. It does not decrypt or inspect wallet contents. It does not stop a wallet from signing a transaction if the user or a malicious browser extension initiates it. v0.2 plans invisibility for known wallet extension storage paths and standalone wallet app data directories per `INVISIBILITY_SPEC.md`, conditional on Endpoint Security entitlement.

**SSH keys and identities**: `~/.ssh` is protected as a default sensitive folder. v0.1 detects agent access and writes signed audit entries. It does not prevent the read from completing. v0.2 intends invisibility for `~/.ssh` and other protected folders when accessed by classified agents, using `ES_EVENT_TYPE_AUTH_OPEN`, `ES_EVENT_TYPE_AUTH_READDIR`, and related events. See `INVISIBILITY_SPEC.md`.

**GPG keys**: `~/.gnupg` is covered like SSH keys. v0.1 detects access. v0.2 intends invisibility for `~/.gnupg` when accessed by classified agents, using Endpoint Security filesystem authorization events. See `INVISIBILITY_SPEC.md`. Sanctuary does not replace GPG passphrase hygiene or hardware-backed keys.

**Cloud provider credentials**: `~/.aws`, and planned defaults for `~/.azure` and `~/.gcloud`, are sensitive because a short-lived agent read can become cloud account compromise. v0.1 detects access for configured protected folders. v0.2 intends invisibility for `~/.aws`, `~/.azure`, and `~/.gcloud` when accessed by classified agents. See `INVISIBILITY_SPEC.md`. Sanctuary does not rotate leaked credentials. It does not inspect cloud API traffic.

**Browser-stored secrets**: Cookies, form data, password manager integration state, and wallet sessions live inside browser profiles. v0.1 protects the specific browser attack surface that matters for the demo and for active-wallet compromise: CDP attachment. It does not generally protect all browser profile files from reads unless the user protects those folders.

**Wallet browser extension storage**: v0.1 includes a curated extension list and materializes Chromium storage paths for wallets and password managers. Agent access to these paths is detected and logged. v0.1 does not block filesystem reads. v0.2 moves from detection to invisibility for known wallet extension storage paths per `INVISIBILITY_SPEC.md`.

**Password manager state**: v0.1 includes coverage of known password manager extension storage in Chromium browsers: 1Password, Proton Pass, Bitwarden, Dashlane, LastPass, NordPass, Keeper, and Enpass. v0.1 is detection-only. v0.2 will make this storage invisible to classified agents per `INVISIBILITY_SPEC.md`, including standalone password manager app data directories. Native app IPC between extension and companion app continues to function normally because first-party processes are not classified as agents.

**Active wallet browser sessions**: v0.1 blocks agent connections to Chrome, Brave, Edge, Arc, and other Chromium debug ports when the destination profile is protected. This is implemented through browser debug-port discovery, `pf` loopback redirect, CDP proxy attribution, and the classifier. See `CDP_GUARD_SPEC.md`. This does not protect non-CDP browser automation through Accessibility APIs, screen scraping, or malicious extensions.

The strongest v0.1 guarantee is therefore narrow but real: a classified agent should not be able to attach to a protected Chromium profile through CDP. The broadest v0.1 guarantee is visibility: agent access to configured sensitive folders and extension storage should produce signed local evidence. Users should not confuse these two guarantees.

## 3. Adversaries

### 3.1. Naive AI agent

A naive AI agent runs as the user, uses standard file APIs and HTTP libraries, and does not actively evade detection. Examples include out-of-the-box Codex, a default Cursor agent, Claude Code running normal tool calls, or a basic LangChain pipeline with a shell tool.

Sanctuary v0.1 is strong against this class for CDP. An agent connecting to a protected browser debug port is attributed, classified, and dropped. Sanctuary v0.1 is partial for filesystem access: it detects and alerts after FSEvents reports activity. The read may already have happened.

### 3.2. Adversarial AI agent

An adversarial AI agent runs as the user but actively tries to bypass controls. It may rename itself, spawn from non-agent parents, use Python or Node runtime indirection, avoid known package names, call obscure system APIs, or attempt privilege escalation. Examples include AutoGPT-style systems instructed to bypass security tools and custom agents built specifically to exfiltrate secrets.

Sanctuary v0.1 makes this harder but does not make it impossible. The classifier combines known-agent registry entries, code signing, parent-chain propagation, LaunchAgent origin, Python and Node argv inspection, runtime fingerprints, and user tags. See `CLASSIFIER_SPEC.md`. A determined user-space adversary can still try to avoid all known signals. v0.1 should be treated as high-value detection and targeted blocking, not a complete sandbox.

### 3.3. Root-privileged adversary

A root-privileged adversary has root through `sudo NOPASSWD`, an exploit chain, social engineering, or a separate compromise. It can kill the daemon, unload launchd jobs, flush `pf`, edit SQLite state, delete logs, and replace binaries.

Sanctuary v0.1 has partial visibility against this class. LaunchDaemon `KeepAlive`, signed and hash-chained audit entries, SMAppService registration, bundle IDs, peer monitoring, and CDP Guard pf re-validation make some tamper attempts visible and recoverable, including unexpected daemon disappearance and flushed CDP redirect rules. They do not create real root resistance. v0.2 addresses this through the remaining mechanisms in `TAMPER_RESISTANCE_SPEC.md`: launchd-state polling, code signature self-verification, policy row integrity, stronger visible tamper UI, and ES-based prevention where Apple's entitlement is granted.

## 4. Attack Surfaces

### 4.1. Filesystem reads

v0.1 covers filesystem reads with detection only. FSEvents reports path activity asynchronously, and Sanctuary attributes access using process snapshots and file descriptor inspection. It can produce definite, probable, correlated, or unattributed audit entries. v0.2 requires Endpoint Security for either synchronous denial or the invisibility model documented in `INVISIBILITY_SPEC.md`. The invisibility model is the chosen v0.2 direction.

### 4.2. Filesystem writes

v0.1 detects writes to protected folders and extension storage when FSEvents reports them. This is useful for wallet state mutation, key replacement, and tampering with protected directories. v0.1 does not prevent writes. v0.2 plans ES-based denial for protected paths.

### 4.3. Browser CDP attachment

v0.1 covers CDP attachment with real-time blocking. Sanctuary discovers browser debug ports, redirects loopback traffic through a `pf` anchor, attributes the client process with `proc_pidfdinfo`, classifies it, and drops agent connections to protected profiles. This is the strongest v0.1 enforcement surface.

### 4.4. Browser extension storage

v0.1 detects reads and writes to known wallet and password manager extension storage. It supports Chromium-style profile paths. It does not yet cover every browser extension model or every Firefox storage path. v0.2 intends invisibility for materialized storage paths of known wallet and password manager extensions per `INVISIBILITY_SPEC.md`.

### 4.5. Clipboard access

Clipboard protection is not covered in v0.1. Agents can read clipboard contents if they have local user privileges and the OS permits it. v0.3 may integrate pasteboard monitoring and TCC-aware prompts. This must be designed carefully because clipboard monitoring can become privacy-invasive.

### 4.6. Screen capture

Screen capture is not covered in v0.1. A process with Screen Recording permission can observe wallet windows, QR codes, seed phrases displayed on screen, or password manager UI. v0.3 may integrate TCC state inspection and user guidance. Sanctuary cannot silently revoke TCC permissions without user action.

### 4.7. Accessibility API access

Accessibility automation is not covered in v0.1. A process with Accessibility permission can click buttons, type, and drive wallet UI outside CDP. v0.3 may inspect TCC grants and warn when known agents have Accessibility permission. Blocking requires OS cooperation and explicit user workflows.

### 4.8. Raw process memory reads via `task_for_pid`

Raw memory reads are not covered in v0.1. Processes with sufficient entitlement or root privileges may attempt process inspection. Effective control requires Endpoint Security and Apple's broader platform protections. Sanctuary can observe and deny some related process operations only if ES entitlement is granted.

### 4.9. Network egress to known data-exfil destinations

Sanctuary v0.1 is not a network firewall. It does not block arbitrary outbound network traffic, C2 callbacks, or data exfiltration to unknown endpoints. Network Extension-based egress policy is a v0.3 candidate and depends on Apple granting the relevant Network Extension entitlement.

### 4.10. Keychain item queries

Keychain access is not covered in v0.1. macOS Keychain has its own access control prompts and ACLs. Sanctuary does not sit in front of Keychain queries. Future versions may use Endpoint Security and audit-token-aware correlation to warn when agents invoke Keychain-related tools, but Sanctuary does not replace Keychain policy.

### 4.11. `DYLD_INSERT_LIBRARIES` injection

Dynamic library injection is not covered in v0.1. SIP and library validation constrain many injection paths, but user-space processes can still be manipulated in some configurations. Sanctuary may observe suspicious launch patterns later, but this is not a v0.1 protection.

### 4.12. Kernel exploits

Kernel exploits are out of scope. Sanctuary trusts the macOS kernel. Kernel compromise is Apple's responsibility and belongs in the user's broader platform security model.

### 4.13. Hardware attacks

Hardware attacks are out of scope. Sanctuary does not defend against cold boot attacks, bus probing, JTAG, malicious peripherals, or extended physical access.

### 4.14. Supply chain attacks on Sanctuary itself

Sanctuary reduces this risk through AGPL v3 open source distribution, signed releases, notarization, and planned reproducible builds. v0.1 is public source plus signed artifacts. v1.0 should add reproducible build documentation and release attestation.

## 5. What Sanctuary Does NOT Do

Sanctuary is not a general antivirus or EDR. It does not detect ransomware, miners, commodity malware, browser exploit kits, or persistence mechanisms unrelated to AI agents.

Sanctuary is not a network firewall. It does not block arbitrary C2 traffic, prevent data exfiltration to arbitrary endpoints, or filter inbound connections. Little Snitch and LuLu are complementary tools, not competitors for this layer.

Sanctuary is not a sandbox. It does not run agents in isolated environments. It observes and controls selected resource access from ordinary macOS processes.

Sanctuary is not a credential vault. It does not store, manage, rotate, or recover secrets. If a secret has already leaked, Sanctuary cannot make it safe again.

Sanctuary is not a backup tool. It does not snapshot wallet state or restore lost keys.

Sanctuary is not a malware scanner. It does not analyze binaries for malicious patterns.

Sanctuary does not protect against a user voluntarily granting broad `sudo NOPASSWD` to an agent and walking away. Social engineering of the user remains the weakest link.

Sanctuary does not protect against agents the user explicitly trusts through `sanctuary trust add`. Trusted paths are an override. They should be used sparingly.

## 6. Trust Boundaries

Users trust Sanctuary itself. That means Sanctuary binaries must be signed, notarized, open source, and eventually reproducible. A compromised Sanctuary release can undermine the product.

Sanctuary trusts Apple's code signing infrastructure. If Developer ID or notarization trust is compromised, Sanctuary's production identity checks lose meaning.

Sanctuary trusts the local OS kernel. Kernel exploits, rootkits, and boot-chain compromise are out of scope.

Sanctuary does not trust agents, even if the user installed them. Installation is not consent to read wallets, keys, or browser sessions.

Sanctuary does not trust user-installed browser extensions. It protects extension storage from agents, but it does not vouch for the extension's own behavior.

Sanctuary does not phone home in its enforcement path. v0.2 may add Sparkle auto-update checks. Those checks must be explicit, signed, and limited to update metadata.

## 7. Cryptographic Assumptions

Sanctuary trusts Apple Secure Enclave behavior, modulo published vulnerabilities. It trusts T2 and Apple Silicon boot integrity. It trusts macOS code signing, Developer ID, and notarization for production identity checks.

Sanctuary ships a SHA-256 audit hash chain in v0.1. Each audit entry points to the previous signed entry, making deletion from the middle, forged replacement, and rollback visible during verification. Sanctuary trusts Ed25519 for audit log line signatures. It trusts HMAC-SHA256 for v0.2 policy database row integrity. It trusts the user's Touch ID or passcode as a local owner-presence signal.

Cryptography protects integrity and evidence. It does not prevent a root adversary from deleting all local state. That is why `TAMPER_RESISTANCE_SPEC.md` includes visible alerts, immutable rotated logs, and optional off-machine replication for later versions.

## 8. Out-of-Scope Threats

Physical access attacks are out of scope, including cold boot, JTAG, malicious peripherals, direct disk extraction from an unlocked machine, and evil-maid attacks with extended access.

Hypervisor compromise is out of scope. Supply chain attacks on macOS itself are out of scope. Quantum cryptanalysis is out of scope.

A user who voluntarily disables Sanctuary is out of scope. Sanctuary can make dangerous actions visible and require local owner presence, but it cannot protect a user who intentionally turns it off.

## 9. Privacy Posture

Sanctuary is local-first. There is no telemetry by default. The audit log is stored locally and is never transmitted unless the user opts into a future v0.3 forensic replication feature.

Process identity collection is intentionally narrow. `ProcArgsParser` stores environment variable names only, never values. This invariant matters because variables such as `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and cloud credentials are exactly the material Sanctuary is meant to protect. The classifier may know that an environment variable named `ANTHROPIC_API_KEY` exists. It must never read, store, log, or transmit the value.

No cloud account is required for v0.1. Open source distribution lets researchers verify these claims in code.

## 10. Comparison to Adjacent Tools

Little Snitch is a network firewall. It can control outbound connections, but it does not protect against local filesystem reads of `~/.ssh` or wallet extension storage. It is complementary.

LuLu from Objective-See is a free network firewall. It is also complementary.

BlockBlock from Objective-See detects persistence mechanisms. It helps identify LaunchAgents and LaunchDaemons, but it does not classify AI agents or protect wallet storage from them.

macOS Lockdown Mode reduces platform attack surface. It is valuable for high-risk users, but it does not address the local AI-agent threat directly.

Sandboxing tools isolate selected apps. That is a different approach. Sanctuary assumes users will continue running ordinary agents and adds targeted protection around sensitive resources.

Hardware security keys are orthogonal and recommended for high-value accounts and wallets. They reduce the damage of credential theft, but they do not stop an agent from reading local files or driving a browser session.

Sanctuary is one layer in a defense-in-depth strategy.

## 11. Disclosure Policy

Security reports should follow `SECURITY.md`. Vulnerabilities should be reported privately to `hello@hardener.ai`, not filed as public GitHub issues.

Sanctuary commits to a 48-hour acknowledgment SLA and a 7-day initial assessment. Coordinated disclosure is preferred. There is no paid bug bounty in v0.1. A paid program may launch in v0.2 after Endpoint Security entitlement-based enforcement ships.

## 12. Version History

**v0.1**: Initial threat model. Documents CDP blocking, FSEvents detection, classifier assumptions, privacy posture, and known limitations.

**v0.2**: Planned update for tamper resistance, Endpoint Security enforcement via the invisibility model, policy integrity, and stronger visible tamper reporting.

**v0.3**: Planned update for Network Extension egress policy, sealed-secret release, clipboard or TCC-aware protections, and optional off-machine forensic replication.
