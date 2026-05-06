# CROSS_PLATFORM_ARCHITECTURE

**Status**: architecture roadmap  
**Owner**: SanctuaryCore, platform clients  
**Related specs**: `CLASSIFIER_SPEC.md`, `AGENT_REGISTRY_SPEC.md`, `FSEVENTS_DETECTION_SPEC.md`, `CDP_GUARD_SPEC.md`, `TAMPER_RESISTANCE_SPEC.md`, `THREAT_MODEL.md`, `COVERAGE_GAPS.md`, `EXTENSIBILITY_SPEC.md`

---

## 1. Goal

This document defines how Sanctuary expands from macOS-only v0.1 to a cross-platform product by v1.0.

Sanctuary v0.1 is macOS-first and Swift-native. That remains the launch path. The v0.1 codebase is already built around Apple's platform primitives: SwiftUI, SMAppService, LocalAuthentication, FSEvents, `pf`, and future Endpoint Security.

The long-term product should share pure security logic across macOS, Windows, and Linux. The shared layer should be Rust. The platform layers should remain native. This avoids the two bad extremes: rewriting working macOS code for ideological purity, or duplicating every policy decision separately on each OS.

The roadmap is intentionally evidence-led rather than language-led.

## 2. Current State

Sanctuary v0.1 is a Swift macOS app with:

- Menu bar UI and onboarding.
- `sanctuaryd` privileged daemon.
- CLI.
- Agent classifier.
- Canonical `agents.yaml` registry.
- FSEvents-based filesystem detection.
- Browser extension storage detection.
- CDP Guard using `pf` redirect for Chromium debug ports.
- Tamper-evident audit log with SHA-256 hash chain.
- Peer monitoring.
- `pf` rule re-validation.
- SMAppService daemon installation.

This implementation is launch-ready pending Apple Developer ID and distribution work. It should not be replaced before launch.

## 3. Platform Expansion Plan

### Phase 1: v0.1, now

Ship macOS Swift.

The macOS app uses native Apple frameworks:

- SwiftUI for menu bar UI and onboarding.
- SMAppService for LaunchDaemon installation.
- LocalAuthentication for Touch ID.
- FSEvents for v0.1 detection.
- `pf` for CDP Guard.
- Endpoint Security when entitlement approval arrives.

The goal is a trusted launch, demo video, signed distribution, and early user feedback.

### Phase 2: v0.2-v0.3, parallel Windows work

Start Windows development in a separate repository with the Windows engineer's chosen stack.

Target: Windows v0.1 in roughly six months after scoping.

Windows should not be forced into Swift. The likely split is:

- C++ for kernel-adjacent Minifilter work.
- WFP callout where network enforcement is needed.
- C#, Rust, or C++ for user-space service and tray UI depending on engineer preference.
- Windows Hello for owner-presence approvals.

The Windows implementation should follow the same specs, registry format, audit log format, and threat model, but should use Windows-native primitives.

### Phase 3: v1.0 shared Rust core

After macOS and Windows both have working product surfaces, extract a shared Rust core.

Shared components:

- Agent classifier.
- Audit log canonical JSON and hash-chain verifier.
- Policy decision model.
- Registry parser for `agents.yaml` and protected resource registries.

This timing matters. Extracting too early risks designing abstractions before the second platform teaches us what needs to be shared.

### Phase 4: v1.0+ Linux

Linux support comes after macOS and Windows. The likely design:

- Rust daemon using the shared core.
- `systemd` service.
- `fanotify` for filesystem events and possible permission decisions.
- Landlock for sandbox-style restrictions where applicable.
- AppArmor or SELinux integration for distributions that support it.
- FIDO2 or YubiKey for owner presence where desktop biometrics are inconsistent.

Linux will need a stricter support matrix because filesystem, desktop, and security-module behavior varies widely by distribution.

## 4. What Stays Platform-Native Forever

### 4.1. macOS

The following should remain Swift or native macOS code:

- SwiftUI menu bar app.
- Onboarding window.
- SMAppService install and uninstall.
- LocalAuthentication and Touch ID prompts.
- Endpoint Security event handling.
- FSEvents fallback detection.
- `pf` control and validation.
- Notification Center integration.
- Code-signature and XPC peer verification.

Rust can help with decisions. It should not own the user-facing Mac app.

### 4.2. Windows

Windows should use native Windows primitives:

- Service Control Manager for background service lifecycle.
- Windows Hello for owner presence.
- Minifilter driver for filesystem enforcement.
- Windows Filtering Platform for network policy where needed.
- ETW or native event tracing for telemetry-free local audit.
- Native tray UI framework selected by the Windows team.

Kernel-mode or driver-adjacent code should follow Windows conventions, not a cross-platform abstraction that hides important OS behavior.

### 4.3. Linux

Linux should use:

- `systemd` units.
- `fanotify` for filesystem observation or permission events.
- Landlock where sandbox constraints fit.
- AppArmor or SELinux integration where policy modules are realistic.
- FIDO2, YubiKey, or desktop secret-service integrations for owner approval.

Linux support should be explicit about distribution compatibility.

## 5. What Gets Shared in Rust at v1.0

The Rust feasibility spike at `~/Projects/sanctuary-rust/` validated that pure classifier logic ports well. It does not justify a full macOS rewrite.

Good Rust shared-core candidates:

- `AgentClassifier`: pure process classification from `ProcessIdentity`.
- Registry parser: `agents.yaml`, known extension registry, future protected resource registries.
- Audit canonicalization: deterministic JSON projection.
- Audit hash-chain verification.
- Policy decision engine: given actor, action, resource, and rules, return allow, deny, invisible, prompt, or audit-only.
- Privacy validators: ensure environment variable values and file contents never enter shared audit structures.

Bad Rust shared-core candidates:

- SwiftUI app.
- SMAppService.
- Touch ID UI.
- Endpoint Security message loop before abstractions stabilize.
- Platform-specific filesystem and network event collection.

## 6. FFI Strategy

The v1.0 shared core should expose a C ABI. Swift, C#, C++, and Rust platform hosts can call the same compiled library.

Principles:

- Keep FFI functions coarse-grained.
- Pass explicit JSON or flat C structs at the boundary.
- Avoid exposing Rust-owned collections directly.
- Return owned buffers with explicit free functions.
- Version every public ABI structure.
- Keep policy decisions deterministic and side-effect free.

Candidate API shape:

```text
sanctuary_core_load_registry(path) -> RegistryHandle
sanctuary_core_classify(registry, process_identity_json) -> classification_json
sanctuary_core_evaluate_policy(policy_json, event_json) -> decision_json
sanctuary_core_verify_audit_log(path) -> verification_json
sanctuary_core_free(ptr)
```

This is intentionally boring. Boring FFI is good FFI.

## 7. Why Not Rewrite macOS to Rust Now

A Rust spike was completed at `~/Projects/sanctuary-rust/SPIKE_EVALUATION.md`.

The result:

- The classifier port was successful.
- The Rust version has 53 tests.
- Pure logic maps well to Rust.
- Full macOS feature parity in Rust was estimated at roughly 250-450 hours.

Most of Sanctuary v0.1 is not pure logic. It is platform integration:

- SwiftUI.
- SMAppService.
- FSEvents.
- LocalAuthentication.
- Endpoint Security entitlement and event handling.
- `pf` behavior.
- Code signing and notarization.
- Menu bar UX.

Swift is the platform-native choice for those integrations. Rewriting now would delay launch, increase risk, and replace working code with less-proven code. The correct move is to ship Swift macOS, learn from users, and extract shared Rust only where reuse is real.

## 8. Why Not Write Windows in Swift

Swift on Windows is improving, but it is not the right base for Windows endpoint security.

Reasons:

- Kernel-mode and driver-adjacent Windows work is C/C++ territory.
- Minifilter drivers require Windows-native expertise.
- Windows Filtering Platform examples and tooling are C/C++-first.
- Windows Hello and service lifecycle are best handled through mature Windows stacks.
- Forcing Swift would make hiring and maintenance harder.

The Windows engineer should choose the right Windows stack. The cross-platform contract is the spec, registry format, audit format, and eventually the Rust shared core.

## 9. Coordination Before Shared Core

Before Rust extraction, platforms coordinate through documents and data formats:

- Shared `specs/` directory.
- Shared `agents.yaml` format.
- Shared audit log JSON format.
- Shared threat model.
- Shared coverage gap inventory.
- Shared e2e scenario definitions where possible.
- Shared vocabulary for classification, attribution, decision, denial, invisibility, and approval.

This keeps product behavior aligned without prematurely coupling implementations.

The Windows repo should copy or vendor the specs at first. Once shared-core extraction begins, specs and registry data can move into a separate shared repository or package.

## 10. Decision Log

**Why macOS first:** The beachhead market is crypto-native developers and traders. They over-index on macOS, use local coding agents, and keep high-value wallets, SSH keys, and browser profiles on the same machine.

**Why Windows in parallel:** Customer mix will not stay Mac-only. Windows is important for broader security adoption, trading desktops, and enterprise environments. It should begin after v0.1 launch pressure drops, not after macOS v1.0.

**Why shared Rust core at v1.0:** The classifier spike shows Rust is a good fit for pure logic. It also shows that rewriting native platform code is wasteful. v1.0 is the right point to share logic after at least two platform implementations prove the common shape.

**Why Linux later:** Linux support is valuable but fragmented. Desktop environment, distro, filesystem, and security module differences make it harder to promise a polished consumer experience early.

**Why platform-native surfaces remain:** Security products fail at the edges: prompts, entitlements, service lifecycle, permissions, updates, and system integration. Those edges are OS-native. Sanctuary should share decisions, not pretend the operating systems are the same.

**Why specs are the coordination primitive now:** Specs are cheaper than premature abstractions. They let macOS, Windows, and future Linux implementations agree on behavior while still using the right OS-specific tools.
