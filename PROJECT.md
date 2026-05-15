# Sanctuary

## What This Is

Sanctuary is the security runtime for AI agents on macOS. It gives local agents
capability scoping, human approval, containment, and tamper-resistant audit.

The v0.1 runtime is local-first and open source. Hardener Cloud is the future
commercial enterprise control plane for fleet policy, audit export, SSO, and
compliance reporting.

## Current Status

v0.1 is pre-launch and functionally implemented.

- Public repo: `https://github.com/Hardener-ai/sanctuary`
- License: AGPL v3 plus trademark policy
- Tests: 410 on `main`
- e2e: 8 scenarios, with `pf` scenarios gated by `E2E_PF=1`
- Current blocker: Apple Developer distribution work and ES entitlement
  submission

## Architecture

Sanctuary has:

- `SanctuaryCore`: classifier, policy DB, audit log, detection surfaces, CDP
  Guard, peer monitoring, path resolution.
- `SanctuaryCLI`: command-line policy, inventory, setup, and log tools.
- `SanctuaryDaemon`: local daemon that runs detection and protection services.
- `SanctuaryMenuBar`: SwiftUI menu bar console, onboarding, controls, activity
  feed, and Security Overview.
- `e2e/`: reproducible attack scenarios that produce markdown evidence.

The daemon owns policy, process identity, detection surfaces, and audit logging.
The menu bar app owns first-run UX, status, protection controls, Security
Overview, and future human approval prompts.

## v0.1 Shipping Surface

- Agent classifier with known-agent registry, runtime detection, parent-chain
  inspection, user-tagged agents, and trusted paths.
- Protected folder and extension storage policy DB.
- FSEvents-backed detection for folders and extension storage.
- CDP Guard real-time block for protected Chromium browser profiles.
- Tamper-evident audit log with signatures and SHA-256 hash chain.
- Daemon peer monitoring.
- `pf` rule revalidation and auto-recovery.
- SMAppService daemon install flow.
- Menu bar onboarding, activity feed, protected-resource display, and Security
  Overview.
- End-to-end proof scenarios.

## Deferred From v0.1

- Endpoint Security filesystem enforcement.
- Runtime SDK server.
- Runtime Touch ID approvals for arbitrary capability grants.
- Clipboard mediation.
- Keychain mediation.
- Screen capture and Accessibility mediation.
- Hardener Cloud fleet control plane.

## Roadmap

### v0.1

Ship signed and notarized macOS runtime. Record real demo. Publish source,
release artifacts, and proof scenarios.

### v0.2

Capability runtime:

- SDK surface from `docs/SDK.md`.
- Endpoint Security enforcement.
- Invisibility where Apple APIs permit it.
- Human approval with Touch ID.
- Workspace-scoped exceptions.
- Stronger tamper resistance and policy integrity.

### v0.3

Hardener Cloud:

- Central policy management.
- Fleet audit aggregation.
- SSO/RBAC.
- SIEM export.
- Compliance reports.

### v1.0

Standardization:

- Shared Rust core after multiple platform implementations prove the common
  shape.
- SDK adoption by agent vendors.
- Windows and Linux plans continue from `specs/CROSS_PLATFORM_ARCHITECTURE.md`.

## Critical Path

1. Public repositioning around "AI agent security runtime".
2. Submit Apple Endpoint Security entitlement application.
3. Install Developer ID certificates locally.
4. Land signing and notarization release pipeline.
5. Record real demo against signed build.
6. Publish launch materials and begin agent-vendor outreach.

## Key Files

- Product spec: `SPEC.md`
- Threat model: `specs/THREAT_MODEL.md`
- Coverage gaps: `specs/COVERAGE_GAPS.md`
- ES entitlement application: `specs/APPLE_ES_APPLICATION.md`
- SDK draft: `docs/SDK.md`
- Commercial boundary: `COMMERCIAL.md`
- Bundle script: `Sources/SanctuaryMenuBar/scripts/bundle.sh`
- e2e suite: `e2e/run-all.sh`

## Known Issues / Gotchas

- No Developer ID signing identities are installed locally yet.
- Endpoint Security entitlement can take weeks to months; submit early.
- v0.1 filesystem protection is detection-only without ES.
- `PROJECT.md` and `SPEC.md` should stay aligned with what actually ships;
  avoid reintroducing unshipped clipboard/keychain/screen claims as v0.1.
- Homebrew cask is planned but not published.

## How To Run

```sh
swift test
./Sources/SanctuaryMenuBar/scripts/bundle.sh
./e2e/run-all.sh
```

For `pf` scenarios:

```sh
E2E_PF=1 ./e2e/run-all.sh
```
