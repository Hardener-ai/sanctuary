# sanctuaryd

`sanctuaryd` is the local daemon process that keeps Sanctuary's detection
surfaces running. In production it is installed from the menu bar app via
`SMAppService` as the bundled LaunchDaemon `ai.hardener.sanctuary.daemon`. For
development and e2e scenarios it can run directly as the current user with the
environment overrides below.

## Installation

Production packaging embeds the daemon binary at:

`SanctuaryMenuBar.app/Contents/Library/LaunchDaemons/ai.hardener.sanctuary.daemon`

The matching plist lives beside it as `ai.hardener.sanctuary.daemon.plist` and is
registered by the menu bar app with:

`SMAppService.daemon(plistName: "ai.hardener.sanctuary.daemon.plist").register()`

Developer builds made by `Sources/SanctuaryMenuBar/scripts/bundle.sh` are
ad-hoc signed when no Developer ID Application identity is available. Those
builds are useful for UI and local daemon testing, but macOS may require manual
approval or refuse the production install path until the app is Developer ID
signed and notarized.

## Startup Order

1. Load protected folders from `ProtectedFolderRegistry`.
2. Load protected extension storage rows from `ProtectedExtensionRegistry` and
   materialize concrete Chromium profile paths.
3. Start `AgentActivityCache`, a short-retention live snapshot of agent
   processes and their open files.
4. Start `ProtectedFolderWatcher`.
5. Start `ExtensionStorageProtectionService`.
6. Start the extension storage read poller, which catches read-only accesses
   that do not produce FSEvents.
7. Start `ServiceInventory` continuous refresh.

The folder watcher, extension watcher, and extension read poller share one
`AuditLog` instance and one `AgentActivityCache`, so short-lived agent file
accesses can still be attributed when FSEvents arrives slightly after the file
descriptor closes. The poller exists because FSEvents does not fire for pure
file reads.

## Environment Overrides

- `SANCTUARY_DB_PATH`: SQLite policy DB path. Used by folder and extension
  registries.
- `SANCTUARY_AUDIT_PATH`: signed JSONL audit path.
- `SANCTUARY_INVENTORY_SNAPSHOT_PATH`: inventory snapshot JSON path.

When an override is not set, all three paths are resolved through
`SanctuaryPaths`: root processes use `/var/db/sanctuary/`, while non-root
development runs use `~/Library/Application Support/sanctuary/`.

These are development and test conveniences. The packaged daemon should use
the production defaults.

## Signals

- `SIGTERM`: clean shutdown.
- `SIGINT`: clean shutdown.

Shutdown stops inventory refresh, extension storage watching, folder watching,
and the agent activity cache. If cleanup does not complete within 5 seconds,
the daemon logs a warning and exits with code 1.

## Logs

- Startup summary is written to stdout.
- Audit append failures are written to stderr with the watcher name.
- Detection events are written to the signed audit log.

## Development Signing Keys

Release builds will store the audit signing key with modern `SecItem` keychain
APIs under Sanctuary's generic-password service. Ad-hoc SwiftPM builds are
treated as development mode and use an ephemeral in-memory signing key instead:

`DEV MODE: using ephemeral signing key; production builds use System keychain`

This avoids repeated macOS keychain dialogs while iterating locally. Audit log
entries are still signed during the process lifetime, but `sanctuary log verify`
will not verify entries across separate ad-hoc processes or daemon restarts
because the ephemeral private key is intentionally not persisted.

For local e2e verification, set `SANCTUARY_AUDIT_DEV_KEY_PATH` to a private key
file under the test working directory. The daemon and CLI will share that
file-backed development key, so `sanctuary log verify` can validate signatures
across processes without touching the System keychain. Production builds do not
use this path.
