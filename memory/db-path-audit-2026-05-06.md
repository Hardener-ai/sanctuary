# DB path audit - 2026-05-06

## Current default path behavior

### Protected folder registry

`ProtectedFolderRegistry.defaultDatabasePath()` uses:

1. `SANCTUARY_DB_PATH` when set.
2. Otherwise `FileManager.default.homeDirectoryForCurrentUser/.sanctuary/sanctuary.sqlite`.

For the normal user this resolves to `/Users/tg/.sanctuary/sanctuary.sqlite`.
For a root LaunchDaemon this resolves to `/var/root/.sanctuary/sanctuary.sqlite`.

### Protected extension registry

`ProtectedExtensionRegistry.defaultDatabasePath()` uses the same logic as the
folder registry:

1. `SANCTUARY_DB_PATH` when set.
2. Otherwise `FileManager.default.homeDirectoryForCurrentUser/.sanctuary/sanctuary.sqlite`.

So CLI/menu bar and a root daemon disagree when no env override exists.

### Audit log

`AuditLog` defaults to `/var/db/sanctuary/audit.log`, then overrides with
`SANCTUARY_AUDIT_PATH` if set. This already follows the production path
convention, but the env/default logic is implemented locally rather than via a
shared resolver.

### Inventory snapshot

`ServiceInventory` defaults `snapshotPath` to `SANCTUARY_INVENTORY_SNAPSHOT_PATH`
when set, otherwise `nil`. `SanctuaryDaemonRuntime.live()` separately uses
`SANCTUARY_INVENTORY_SNAPSHOT_PATH ?? /var/db/sanctuary/inventory.json`.
The daemon and generic inventory type therefore do not share a canonical default.

### Menu bar

`MenuBarDataSource` reads folder and extension registries through their default
constructors, so it follows the current-user home DB unless `SANCTUARY_DB_PATH`
is inherited by the app process. It does not search `/tmp`; stale e2e data can
only appear if the app process inherited an e2e `SANCTUARY_DB_PATH` or if an old
app instance is displaying cached values.

## Why the defaults diverged

Each subsystem grew its own default path when it was introduced. Tests and e2e
runs set explicit `SANCTUARY_*` paths, so the mismatch stays hidden there. In
production, no env vars are set and the effective default changes with the
process user. A root daemon and a user CLI/menu bar therefore read different
SQLite files.

## Canonical default

Use one shared resolver in `SanctuaryPaths`:

1. If the corresponding `SANCTUARY_*` environment variable is set, use it.
2. Otherwise, if running as root, use `/var/db/sanctuary/<file>`.
3. Otherwise, use `~/Library/Application Support/sanctuary/<file>`.

The canonical files are:

- Policy DB: `policy.sqlite`
- Audit log: `audit.log`
- Inventory snapshot: `inventory.json`

If both production and user policy DBs exist, prefer the user DB and log a
warning. That preserves user-configured protections from the historical bug and
makes the state visible to CLI/menu bar during development.
