# Sanctuary Product Spec

**Status:** v0.1 pre-launch, v0.2 in design
**Product:** Sanctuary by Hardener
**Positioning:** security runtime for AI agents on macOS

## 1. Executive Summary

Sanctuary is a local macOS runtime that contains AI agent behavior through
process classification, protected-resource policy, local approval workflows,
and tamper-resistant audit.

The runtime is open source under AGPL v3. It runs standalone on a single Mac.
Hardener Cloud is the future commercial control plane for central policy,
fleet audit, SSO, and compliance reporting.

The wedge is concrete: companies and security-conscious developers are
deploying Claude Code, Cursor agents, Codex-style CLIs, and Computer Use on
machines that also contain SSH keys, cloud credentials, browser profiles,
password managers, and wallet state. They need to answer:

```text
What did the agent touch, was it approved, can we revoke it, and can we prove it?
```

Sanctuary is built to answer those questions locally first, then across fleets.

## 2. Threat Model

Sanctuary assumes AI agents may become over-permissive, prompt-injected,
maliciously extended, or compromised. It does not try to solve prompt injection
inside the model. It contains the blast radius on the local machine.

Primary v0.1 surfaces:

- Agent attempts to attach to a protected Chromium browser profile via Chrome
  DevTools Protocol.
- Agent reads or writes protected folders such as `~/.ssh`, `~/.aws`, and
  `~/.gnupg`.
- Agent reads or writes known wallet and password manager extension storage.
- Agent tampering with Sanctuary's audit log, daemon peer, or `pf` rules.

Out of scope for v0.1:

- Clipboard mediation.
- Keychain query mediation.
- Screen capture mediation.
- Accessibility automation mediation.
- General network egress filtering.
- Full filesystem prevention through Endpoint Security.

See `specs/THREAT_MODEL.md` and `specs/COVERAGE_GAPS.md` for the canonical
security boundaries.

## 3. v0.1 Shipping Surface

v0.1 is a local macOS runtime with one real-time block and several detection and
audit surfaces.

### Implemented

- Agent classifier with known-agent registry, code-signing signals, runtime
  fingerprints, LaunchAgent/LaunchDaemon origin, parent-chain attribution,
  user-tagged agents, and trusted path overrides.
- SQLite policy DB for protected folders, protected extensions, user-tagged
  agents, and trusted paths.
- FSEvents-backed protected-folder detection.
- Browser extension storage detection for known wallet and password manager
  extensions.
- CDP Guard using `pf` redirect and process attribution to block agent access
  to protected Chromium debug sessions.
- Signed, hash-chained JSONL audit log.
- Audit tail reader and plain-language activity feed.
- Peer monitoring between menu bar app and daemon.
- `pf` rule revalidation and auto-reload.
- SMAppService LaunchDaemon install flow.
- SwiftUI menu bar console with onboarding, protected-resource display,
  activity feed, controls, and Security Overview.
- Reproducible e2e scenarios with markdown evidence.

### Explicitly Deferred

- Endpoint Security enforcement and filesystem invisibility.
- Runtime capability SDK server.
- Runtime Touch ID prompts for arbitrary agent capability grants.
- Clipboard mediation.
- Keychain mediation.
- Screen capture and Accessibility mediation.
- Hardener Cloud fleet control plane.

## 4. v0.2 Direction

v0.2 turns Sanctuary from a local detection/blocking runtime into a capability
runtime.

Planned v0.2 work:

- Endpoint Security client entitlement and ES-backed enforcement.
- Invisibility for protected filesystem and extension-storage resources where
  Apple APIs permit it.
- Capability scopes for agent operations.
- Human approval flow with Touch ID for sensitive grants.
- Workspace-scoped exceptions.
- Policy integrity and stronger tamper resistance.
- SDK server described in `docs/SDK.md`.

The v0.2 model is documented in:

- `specs/APPLE_ES_APPLICATION.md`
- `specs/ES_CLIENT_ARCHITECTURE.md`
- `specs/INVISIBILITY_SPEC.md`
- `specs/CAPABILITY_SCOPING_SPEC.md`
- `specs/HUMAN_APPROVAL_SPEC.md`
- `specs/TAMPER_RESISTANCE_SPEC.md`

## 5. Architecture

```text
Agent / IDE / Computer Use
        |
        v
Sanctuary local runtime
        |
        +-- process classifier
        +-- policy DB
        +-- protected folder detection
        +-- extension storage detection
        +-- CDP Guard
        +-- audit log
        +-- menu bar console
        +-- daemon peer monitoring
        |
        v
Hardener Cloud control plane (future)
```

The runtime must remain useful without Hardener Cloud. Cloud policy and audit
export are enterprise features, not local enforcement dependencies.

## 6. Signed Targets and Bundle IDs

Sanctuary is built as three separately signed targets. The split exists for
security boundary reasons (each target has the minimum entitlements it needs)
and for Apple review reasons (Endpoint Security clients are reviewed as their
own binary with a tightly scoped entitlement).

| Target | Bundle ID | Role |
| --- | --- | --- |
| Menu bar app | `ai.hardener.sanctuary.menubar` | SwiftUI menu bar UX, onboarding, activity feed, approval prompts. |
| Daemon | `ai.hardener.sanctuary.daemon` | Privileged local runtime, installed via SMAppService LaunchDaemon. |
| Endpoint Security client (v0.2+) | `ai.hardener.sanctuary.endpointsecurity` | ES event subscriber. Gated on Apple ES entitlement approval. |

### Signing and Entitlements

All three targets are signed with the JULC Limited Developer ID Application
certificate (Team ID `N5BS88PDXP`) and notarized via `notarytool` before
distribution. Hardened runtime is enabled for all three.

Entitlements per target:

- `menubar`: standard hardened runtime, no privileged entitlements.
  Communicates with the daemon over a Unix domain socket.
- `daemon`: SMAppService LaunchDaemon registration. Owns the policy DB, audit
  log, and capability decision engine.
- `endpointsecurity`: `com.apple.developer.endpoint-security.client` (pending
  Apple approval, Request ID `D9D8KA6NTK` submitted 2026-05-15). Subscribes to
  the narrow ES event set documented in `specs/APPLE_ES_APPLICATION.md` and
  forwards decisions to the daemon.

### IPC Boundary

The menu bar app and the ES client both communicate with the daemon over a Unix
domain socket at `~/Library/Application Support/sanctuary/daemon.sock`. The
daemon is the single source of truth for policy, grants, and audit. UI and ES
subscription are clients of the daemon, not peers.

This split means the ES client can be updated, replaced, or temporarily
disabled without affecting the daemon's policy state, and the menu bar app can
be killed and relaunched without losing in-flight grants.

## 7. Build and Distribution

Current source build:

```sh
swift build -c release
./Sources/SanctuaryMenuBar/scripts/bundle.sh
open dist/SanctuaryMenuBar.app
```

Developer ID signing and notarization are next. The intended release pipeline:

1. Build `SanctuaryMenuBar` and `sanctuaryd`.
2. Bundle the daemon inside the app.
3. Sign daemon and app with Developer ID Application and hardened runtime.
4. Create signed installer package.
5. Submit to notarization with `notarytool`.
6. Staple and verify.
7. Publish GitHub release and direct download.

Homebrew cask distribution is planned after the first notarized release.

## 8. Business Model

Sanctuary runtime:

- AGPL v3.
- Inspectable, forkable, and auditable.
- Suitable for individual developers, researchers, and open-source
  integrations.

Hardener Cloud:

- Commercial enterprise control plane.
- Central policy management.
- Fleet audit aggregation.
- SSO/RBAC.
- Compliance reporting.
- SIEM export.

Commercial runtime licensing is available for proprietary embedding. See
`COMMERCIAL.md`.

## 9. Current Verification State

- `swift test`: 410 tests on `main`.
- `./e2e/run-all.sh`: 6 PASS / 2 SKIP without `E2E_PF=1`.
- `E2E_PF=1 ./e2e/run-all.sh`: expected 8 PASS with scoped sudoers configured.
- `bundle.sh`: produces `dist/SanctuaryMenuBar.app`.

## 10. Immediate Next Steps

1. Submit Apple Endpoint Security entitlement application using
   `specs/APPLE_ES_APPLICATION.md`.
2. Install Developer ID Application and Installer certificates locally.
3. Add signed and notarized release pipeline.
4. Record real demo against signed build.
5. Prepare launch post and agent-vendor outreach around `docs/SDK.md`.

## 11. Decision Log

**Runtime framing over consumer helper:** The buyer and long-term moat are in
agent security infrastructure. Wallet and SSH-key protection remain the
developer wedge, not the whole company story.

**macOS first:** The beachhead audience over-indexes on macOS, and Apple's
platform gives the deepest local enforcement primitives.

**Swift first:** Swift is the native path for SwiftUI, SMAppService,
LocalAuthentication, FSEvents, `pf`, and Endpoint Security.

**AGPL runtime plus commercial cloud:** The runtime must be trusted and
inspectable. The fleet plane is operational tooling and can be commercial.

**Endpoint Security is the long pole:** v0.1 ships without ES. v0.2 enforcement
depends on Apple granting the entitlement.
