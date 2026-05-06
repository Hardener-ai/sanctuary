# Daemon wiring diagnosis - 2026-05-06

Input: e2e run at `memory/results-20260505T064732Z.md`.

## Findings

1. `sanctuaryd` does honor `SANCTUARY_DB_PATH` for protected folders. In the
   failed filesystem scenario, the daemon log showed `watching 1 protected
   folder(s)` after the CLI wrote the protection into the e2e SQLite DB.
   The folder failure is therefore not a simple default-DB-vs-temp-DB split.

2. `sanctuaryd` does honor `SANCTUARY_AUDIT_PATH` at construction time via
   `AuditLog`, but audit append errors are currently swallowed in watcher
   code with `try?`. The e2e audit file stayed empty even though live agents
   were running, so a failed append is indistinguishable from a missed
   FSEvents callback. The fix should make daemon audit failures observable.

3. `ExtensionStorageProtectionService` is not started by `sanctuaryd`. The
   daemon only starts `ProtectedFolderWatcher` and `ServiceInventory`, so
   extension storage protections registered by the CLI can never emit daemon
   audit entries. This directly explains the MetaMask fixture scenario.

4. The filesystem e2e fixture writes and exits quickly. The in-process
   integration test keeps a separate holder process with the vnode open while
   the event is delivered. The daemon path needs a small process snapshot
   cache so a recently-running agent can still be correlated/probably
   attributed when FSEvents arrives after the fd has closed.

5. The e2e suite runs `sanctuaryd` as the invoking user, while production is a
   root LaunchDaemon. The scripts intentionally use `SANCTUARY_*` overrides,
   so the daemon should remain usable in this dev mode; fixes should not rely
   on root-only behavior.

## Fix plan

- Add a daemon runtime object that starts folder watching, extension storage
  watching, and service inventory from the same env-overridden DB/audit paths.
- Share a single `AuditLog` instance between daemon watchers.
- Add observable audit-error logging instead of silently dropping append
  failures.
- Add a recent-agent snapshot cache to the Darwin agent snapshot provider so
  short-lived fixture agents survive the FSEvents delivery window.
