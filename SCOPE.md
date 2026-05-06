# Project Scope — Sanctuary

## Identity
You are working on Sanctuary, an AI agent shield for macOS that protects local resources from compromised or overreaching agent processes.

## Boundaries
- Working directory: ~/Projects/sanctuary/
- You may read and write files inside this directory.
- You may NOT modify files outside this directory unless TGG explicitly asks. This includes ~/.openclaw/, /Applications/, any other project folder, system files, anything in /etc.
- You may NOT modify, deploy, or restart services that are not part of this project. The Tencent server, Forge Terminal, PHANTOM ARB, and other agents are out of bounds.

## Stack
- Language: Swift
- Framework: Swift Package Manager first; Xcode project required later for Endpoint Security, System Extension, signing, notarization, and menu bar packaging.
- Database: SQLite for policy store; append-only JSONL for audit log.
- Deploy target: macOS direct download package, Homebrew cask, GitHub releases. No App Store.

## Conventions
- Prefer OS-enforced controls over advisory wrappers.
- Keep false positives low: explicit agent list can block; heuristics should prompt before blocking.
- Hardware override must use presence checks such as Touch ID or hardware keys, never password-only fallback.
- Protected resources should look absent to agent processes where feasible.

## Locked surfaces
Anything marked // LOCKED or # LOCKED in code is not yours to modify.
If a task seems to require touching a locked surface, stop and ask.

## How to run
- Tests: `swift test`
- Dev server: not applicable
- Build: `swift build`
- Deploy: not defined yet

## Out-of-scope tasks
- Linux and Windows support before macOS MVP.
- Screen capture filtering before v0.2.
- Cloud audit sync, team management, and custom policy DSL before later roadmap phases.
