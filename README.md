# Sanctuary
by Hardener · https://hardener.ai

Stop AI agents from accessing your wallets, SSH keys, and secrets.
Even when they have full system access.

> Status: v0.1 in development. Not yet ready for public use.
> Launch coming soon.

## What it does

Sanctuary by Hardener is a macOS background service plus menu bar app that
detects and (for browser-based attacks) blocks AI agent access to sensitive
resources on your machine. Protected surfaces include:

- Folders you choose (default: `~/.ssh`, `~/.aws`, `~/.gnupg`, common wallet
  directories)
- Browser wallet extensions (MetaMask, Phantom, OKX, Trust, Rabby, and 30+
  others)
- Browser CDP attacks against active wallet sessions

Sanctuary identifies AI agent processes via a registry of 41+ known agents
(Codex, Cursor, Claude Code, Hermes, OpenClaw, etc.) plus runtime fingerprinting
and parent-chain analysis.

## Architecture

See `specs/` for detailed architecture documents. Key reads:

- `CLASSIFIER_SPEC.md` - how agents are identified
- `CDP_GUARD_SPEC.md` - how browser sessions are protected
- `FSEVENTS_DETECTION_SPEC.md` - how filesystem accesses are detected

## Verify it works

The `e2e/` directory contains reproducible attack scenarios. After building:

    ./e2e/run-all.sh

Expected: 6 PASS, 2 SKIP (the pf-gated CDP scenarios require sudo).

With sudo:

    E2E_PF=1 ./e2e/run-all.sh

Expected: 8 PASS.

## License

GNU Affero General Public License v3.0. See [LICENSE](LICENSE).

The names "Sanctuary" and "Hardener" are trademarks of Hardener. See
[TRADEMARKS.md](TRADEMARKS.md) for the trademark policy.

## Status

v0.1 ships detection-only with one real-time block (browser CDP).
v0.2 will add full enforcement once Apple grants the Endpoint Security
entitlement.
