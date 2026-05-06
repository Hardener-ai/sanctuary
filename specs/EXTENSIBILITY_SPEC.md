# EXTENSIBILITY_SPEC

**Status**: architecture note for post-v0.1 expansion  
**Audience**: future contributors, security researchers, v0.2/v0.3 planning  
**Related specs**: `CLASSIFIER_SPEC.md`, `CDP_GUARD_SPEC.md`, `FSEVENTS_DETECTION_SPEC.md`, `THREAT_MODEL.md`, `COVERAGE_GAPS.md`

---

## 1. Purpose

This document explains how Sanctuary's enforcement architecture can extend beyond AI agents to other endpoint threat categories. Sanctuary v0.1 deliberately ships with AI-agent-shaped rules. That is the product wedge, the demo story, and the current user promise. The underlying machinery is broader by design.

The core primitives are process classification, protected-resource observation, per-process attribution, policy decisions, and signed audit evidence. Those primitives are useful for AI agents, but they are not inherently limited to AI agents. A process that reads `~/.ssh` can be an agent, a compromised package installer, a backdoored CLI, an infostealer, or a living-off-the-land shell chain. The enforcement question is the same: who is the actor, what did it touch, what policy applies, and what evidence should be recorded?

The audience for this document is future contributors evaluating expansion proposals, security researchers assessing whether Sanctuary is a narrow demo or a real architecture, and the v0.2/v0.3 planning process. This spec signals architectural depth without committing v0.1 to non-AI threats.

## 2. The General-Purpose Architecture

### 2.1. Process classifier

`CLASSIFIER_SPEC.md` defines the current classifier around one question: "Is this process an AI agent?" The v0.1 type is `AgentVerdict`, with `.agent`, `.suspicious`, and `.notAgent` cases plus confidence. The important architectural fact is that enforcement does not need the English word "agent." It needs a typed classification with reason, confidence, and enough identity to explain the decision.

The existing rules are pluggable: known-binary registry, code signing identifiers, team identifiers, parent chain, LaunchAgent origin, Python and Node runtime fingerprints, user-tagged agent paths, and trusted-path allowlist. New categories can add rules without changing CDP Guard, FSEvents detection, audit logging, or policy storage. For example, a future `ThreatVerdict.infostealer` or `Classification.supplyChainTool` could flow through the same allow/deny pipeline.

The current contract makes some AI-specific assumptions in naming, but not in shape. The refactor path is straightforward: preserve `AgentVerdict` for v0.1 compatibility, then introduce a generic classification layer that can wrap `AgentVerdict` and future categories.

### 2.2. FSEvents detection layer

`ProtectedFolderWatcher` and `ExtensionStorageProtectionService` observe filesystem paths and attribute activity to processes. They do not intrinsically care whether the process is an AI agent. They care whether the process classification maps to a policy decision.

The same machinery can observe protected paths for any process category. Today, "classified as agent" is the category that matters. Tomorrow, "recently installed package script," "unknown unsigned CLI reading credentials," or "known infostealer family" could be categories. Attribution remains the same: FSEvents provides path activity, `proc_pidfdinfo` and process snapshots provide best-effort actor attribution, and the audit log records the result.

This is why `FSEVENTS_DETECTION_SPEC.md` remains valuable after Endpoint Security arrives. FSEvents is not only a fallback; it is a broad observation plane for resource access and change detection.

### 2.3. CDP Guard / `pf` anchor

CDP Guard is implemented for Chromium debug ports, but the pattern is more general. The daemon owns a `pf` anchor namespace, redirects loopback traffic to a proxy listener, attributes the peer process, classifies it, and then allows or denies the connection.

That architecture can mediate other localhost services with similar risk profiles: local databases, unauthenticated admin consoles, model-server APIs, browser automation bridges, MCP-over-TCP servers, or IPC sockets exposed on loopback. The product should not expand there casually. Each service has different protocol expectations and failure modes. But the primitive exists: per-connection process classification and policy enforcement.

The strongest lesson from `CDP_GUARD_SPEC.md` is not "protect CDP." It is "localhost is not a security boundary when agents run on the same machine." That insight generalizes.

### 2.4. Signed audit log

The audit log is intentionally generic. It records actor, action, target, attribution, policy, decision, timestamp, and signature. It already supports detections and denials from different subsystems.

Future categories do not need a new evidence system. A supply-chain rule, extension rule, persistence rule, or infostealer rule can emit the same signed JSONL structure. Tamper resistance can then apply uniformly: line signatures, future hash chains, rotation, verification CLI, and eventual off-machine replication all work across categories.

## 3. Future Threat Categories

### 3.1. Supply chain compromise

The threat is a compromised npm, pip, Homebrew, or other package that reads sensitive files during install scripts or runtime. This maps well to Sanctuary's existing model because package scripts are processes touching protected paths.

Detection would start with a classifier rule for newly installed binaries or scripts reading protected paths within N days of install. The new machinery would be install-time provenance tracking: package manager hooks, package receipt parsing, `npm`, `pip`, `uv`, `brew`, and `pnpm` context detection, and a registry of install roots.

What Sanctuary would not do is deep static analysis of package contents. Static analysis belongs to package security vendors and ecosystem scanners. Sanctuary's useful role is local behavioral evidence: this package installer touched `~/.ssh` or wallet storage.

### 3.2. Backdoored CLI tools

A trusted CLI can become malicious after installation. The interesting signal is deviation from baseline behavior. A tool that historically never read `~/.aws` but suddenly does so deserves attention.

Existing machinery can observe the read and identify the executable. New work would include behavioral baselining, local history, update correlation, and deviation alerts. The policy would need careful UX because developer tools legitimately change behavior over time.

Sanctuary would not detect the initial compromise vector. It would detect surprising local behavior against protected resources.

### 3.3. Malicious browser or IDE extensions

Browser extensions, VS Code extensions, Cursor extensions, and similar plugin systems can read project files, invoke tools, and run in extension host processes. v0.1 protects wallet browser extension storage from agents, but it does not attribute access to individual IDE or browser extensions.

The existing classifier can identify extension host processes. New work would inspect extension manifests, map extension IDs to host-process activity, and add per-extension policy. For VS Code-style hosts, this may require correlating extension installation metadata with child processes and file access. For browsers, it requires browser-specific profile and extension metadata.

Sanctuary will not become an extension marketplace verifier. It can tell the user that an extension host touched protected resources, and later it may identify the extension most likely responsible.

### 3.4. Living-off-the-land attacks

Living-off-the-land attacks use legitimate signed binaries such as `curl`, `ssh`, `openssl`, `sqlite3`, `osascript`, or shell utilities. The executable itself is not suspicious. The context is.

Sanctuary already captures parent chain, arguments, cwd, signatures, and runtime fingerprints. Future rules could classify suspicious command invocations: `curl` launched by an agent immediately after reading `~/.ssh`, `sqlite3` reading browser cookies, or `openssl` invoked against wallet material.

The hard part is distinguishing legitimate admin use from compromise in real time. v0.1 avoids this because false positives are existential. Future living-off-the-land coverage should begin as detection-only with clear evidence, not automatic blocking.

### 3.5. Infostealers

Commodity infostealers read browser cookies, wallet files, password manager data, SSH keys, cloud credentials, and local databases. That overlaps heavily with Sanctuary's protected resources.

If a non-trusted process reads protected paths, the FSEvents and future ES machinery can alert or block regardless of whether the process is an AI agent. New work is mostly registry expansion: known-bad binary names, signing identifiers, bundle IDs, persistence labels, and behavior patterns.

Sanctuary would not prevent initial infection. It would provide local detection and, with ES, denial at the protected-resource boundary.

### 3.6. Persistence mechanisms

Malware persists through LaunchAgents, LaunchDaemons, login items, shell profile edits, cron-like schedulers, browser extensions, and background services. Sanctuary already has process inventory, LaunchAgent parsing, SMAppService state awareness, and daemon lifecycle checks.

Future persistence coverage could detect new or modified persistence entries and surface them in the dropdown. `TAMPER_RESISTANCE_SPEC.md` already defines some persistence-adjacent checks for Sanctuary's own daemon. Generalizing that to user-level persistence is possible.

Sanctuary should not automatically remove persistence in early versions. Removal has high breakage risk. The initial product should alert and explain.

## 4. What v0.1 Deliberately Doesn't Do

v0.1 ships AI-agent-focused rules, not general endpoint protection. That is intentional. The wedge is AI agent containment because it is specific, urgent, and underserved. Expanding too early would dilute the story and put Sanctuary in direct comparison with mature tools such as Little Snitch, LuLu, BlockBlock, and enterprise EDR products.

The architecture supports expansion. The product promise does not yet. v0.1 should be judged on whether it identifies agent processes, detects agent access to protected local resources, blocks CDP wallet-drain paths, and produces trustworthy local evidence. Non-AI categories belong in planning, research, or experimental flags until real users show they need them.

## 5. Expansion Decision Framework

### 5.1. Is the existing machinery sufficient?

If a category only needs a new rule, registry entry, or policy mapping, it is low-cost. Examples include known-bad binaries or package-manager install roots.

If a category needs a new OS primitive, it is high-cost. Clipboard, screen capture, Accessibility, Keychain, and network egress require new permission models or entitlements.

### 5.2. Does it strengthen or dilute the AI agent story?

For v0.1 and v0.2, the answer must be strict. If the work does not strengthen AI agent containment or the demo path, defer it. In v0.3, adjacent threat categories can be considered if users ask for them and the implementation reuses existing primitives. By v1.0, positioning may evolve based on adoption data.

### 5.3. Is there an existing tool that does this better?

Network egress is already served by Little Snitch and LuLu. Persistence detection is served by BlockBlock. Static analysis is served by package and malware security vendors. Sanctuary should complement those tools, not clone them poorly.

### 5.4. Does it require new entitlements or permissions?

Endpoint Security gates filesystem enforcement and some process tamper prevention. Network Extension gates process-aware egress policy. TCC-related surfaces require user-facing permission UX. Secure Enclave designs require production signing and careful LocalAuthentication flows. Any expansion that depends on these must be planned around entitlement timelines.

## 6. Architectural Invariants

### 6.1. Local-first

No telemetry by default. No cloud dependency for enforcement. Any data leaving the machine must be explicit opt-in.

### 6.2. Privacy posture

Never read environment variable values. Never inspect file contents. Never log secret values. Avoid path presentation that leaks secrets in UI or support artifacts. `THREAT_MODEL.md` and `COVERAGE_GAPS.md` both depend on this invariant.

### 6.3. Open source

Sanctuary is AGPL v3. The threat model, coverage gaps, and core enforcement code are public. Reproducible builds are a v1.0 target.

### 6.4. Defensible defaults

New categories should start detection-only. Enforcement requires explicit user enablement, a clear policy, and a tamper-evident audit trail. If false positives would break normal developer workflows, the feature is not ready for automatic blocking.

## 7. Non-Goals for Extensibility

Sanctuary will not become a general antivirus. It will not become an EDR with behavioral ML, managed cloud telemetry, or broad enterprise response actions. It will not become a network firewall; Little Snitch and LuLu serve that role. It will not become a sandbox; isolating processes is a different architectural approach.

Future expansion should make Sanctuary a better local resource shield, not a worse version of every security product.

## 8. Revision Triggers

Update this spec when a new threat category is formally added to v0.2 or later planning, when a new architectural primitive lands, or when launch feedback changes the section 5 decision framework.

Examples include Endpoint Security enforcement, Network Extension integration, TCC permission inspection, per-extension attribution, Secure Enclave sealed-state release, or a public decision to support non-AI threat classes. If the product promise changes, this document must change with it.
