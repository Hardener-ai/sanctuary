# Sanctuary

## What this is

Sanctuary is a macOS security product for people running local AI agents. It assumes an agent may become compromised and limits the blast radius by making sensitive local resources invisible or unreachable to known agent processes.

The beachhead user is the crypto-native developer or trader who runs tools like Claude Code, Cursor, Cline, Aider, OpenClaw, or Codex on a machine that also contains wallets, browser profiles, SSH keys, API credentials, and clipboard secrets.

## Architecture

Sanctuary has a root daemon, a CLI, a menu bar app, and OS enforcement components. The daemon owns policy, process identity, hardware-gated overrides, and append-only audit logging. CDP guard, clipboard sentinel, and extension storage protection are layered as separate modules. Endpoint Security is the strongest filesystem enforcement path but not the v0.1 blocker; FSEvents-based detection is the ship-now alternative.

## File layout

```
.
├── Package.swift
├── README.md
├── SCOPE.md
├── PROJECT.md
├── SPEC.md
├── agents.yaml
├── specs/
│   ├── AGENT_REGISTRY_SPEC.md
│   ├── CLASSIFIER_SPEC.md
│   ├── CDP_GUARD_SPEC.md
│   ├── MCP_PROTECTION_SPEC.md
│   ├── NE_FILTER_SPIKE.md
│   ├── EXTENSION_STORAGE_SPEC.md
│   ├── DEMO_SCRIPT.md
│   ├── FSEVENTS_DETECTION_SPEC.md
│   ├── CDP_PEER_PID_SPIKE.md
│   └── APPLE_ES_APPLICATION.md
├── Sources/
│   ├── SanctuaryCLI/
│   ├── SanctuaryCore/
│   ├── SanctuaryDaemon/
│   └── SanctuaryMenuBar/
├── SystemExtensions/
│   └── SanctuaryEndpointSecurity/
└── Tests/
    └── SanctuaryCoreTests/
```

## Critical path for v0.1 (re-ranked)

The demo video is the launch. Critical path is whatever makes the demo work end-to-end. Endpoint Security entitlement is **not** on the critical path — it's a side task that ships into v0.2 hardening if/when Apple approves.

1. **Agent classifier robustness** — everything depends on this being right. See `specs/CLASSIFIER_SPEC.md`.
2. **CDP guard implementation** — the demo's enforcement layer. See `specs/CDP_GUARD_SPEC.md`.
3. **Browser extension storage protection** — pairs with CDP guard for the wallet drain-block demo. See `specs/EXTENSION_STORAGE_SPEC.md`.
4. **Demo video production** — the entire launch is this video. See `specs/DEMO_SCRIPT.md`.
5. **FSEvents-based filesystem detection** — works without ES entitlement, ships in v0.1 as detection-with-alert. Upgrades to enforcement when entitlement lands. See `specs/FSEVENTS_DETECTION_SPEC.md`.
6. **Apple ES entitlement** — submit and forget. See `specs/APPLE_ES_APPLICATION.md`. ~4 hours of writing, then move on.

## Roadmap after v0.1

v0.2 is the first post-launch hardening release. It assumes Apple Endpoint Security entitlement is available and focuses on filesystem/extension-storage enforcement, invisibility where the platform permits it, human-in-the-loop approval for sensitive agent access, and workspace-scoped exceptions for legitimate project workflows. A Security Overview UI showing the user what sensitive resources exist on their Mac and how Sanctuary covers them is included in v0.1. See `specs/INVISIBILITY_SPEC.md`, `specs/HUMAN_APPROVAL_SPEC.md`, `specs/CAPABILITY_SCOPING_SPEC.md`, and `specs/SECURITY_OVERVIEW_SPEC.md`.

Cross-platform expansion is intentionally staged. macOS remains Swift-native through launch and v0.2. Windows work can proceed in a separate repo with a Windows-native stack. A shared Rust core is deferred to v1.0 after the classifier spike proved pure logic ports well but a full macOS rewrite is not justified. See `specs/CROSS_PLATFORM_ARCHITECTURE.md`.

## Key decisions and why

- macOS first because the beachhead audience is concentrated there and the platform exposes the deepest enforcement primitives.
- Swift first because Endpoint Security, System Extensions, LocalAuthentication, SwiftUI, and packaging all align with native macOS development.
- OS-level protection over wrappers because direct syscalls, child shells, and non-wrapped libraries bypass advisory controls. Where ES is unavailable in v0.1, FSEvents detection + alert is the honest fallback.
- Free OSS core plus paid Pro/Team tiers because trust and inspectability matter for crypto-native adoption.
- Sanctuary is the product under Hardener, with GitHub org `Hardener-ai` as the repository home.

## Known issues / gotchas

- Apple ES entitlement may take 4-12 weeks. v0.1 ships without it on the FSEvents detection path. ES is a v0.2 hardening upgrade.
- Keychain interception is implementation-uncertain; a Sanctuary-managed encrypted vault is the v0.1 fallback if interception proves blocked.
- CDP guard process attribution for localhost WebSocket clients is the trickiest piece in v0.1. See `specs/CDP_GUARD_SPEC.md` §4.
- False positives are existential for UX; heuristics prompt, never auto-block.

## Where to look for X

- Product definition: `SPEC.md`
- Scope and boundaries: `SCOPE.md`
- Component specs: `specs/`
- Swift package targets: `Package.swift`
- Shared primitives: `Sources/SanctuaryCore/`
- CLI entry point: `Sources/SanctuaryCLI/`
- Daemon entry point: `Sources/SanctuaryDaemon/`
- Menu bar placeholder: `Sources/SanctuaryMenuBar/`
- Endpoint Security notes: `SystemExtensions/SanctuaryEndpointSecurity/`

## Active work

- Classifier foundation now has registry loading, LaunchAgent / LaunchDaemon origin classification, MCP identity inheritance, and 56 passing tests
- Build `proc_pidfdinfo`-based `PeerProcessAttributor` for CDP Guard
- Stand up CDP guard skeleton against `CDP_GUARD_SPEC.md`
- Continue remaining classifier hardening against real macOS process identity collection and cache invalidation
- Submit Apple ES entitlement application using `APPLE_ES_APPLICATION.md` narrative

## Status

🚧 just started
