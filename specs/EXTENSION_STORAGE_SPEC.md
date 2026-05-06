# EXTENSION_STORAGE_SPEC

**Component**: `Sources/SanctuaryCore/ExtensionStorage/`
**Status**: spec for v1 implementation
**Owner**: SanctuaryDaemon
**Critical path rank**: 3 of 6 — pairs with CDP guard for the wallet drain-block demo

---

## 1. Purpose

CDP Guard stops agents from driving wallet UIs. Extension Storage Protection stops agents from reading the wallet's encrypted vault directly off disk.

The attack it stops:

```
$ ls "~/Library/Application Support/Google/Chrome/Default/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn"
000003.log  CURRENT  LOCK  LOG  MANIFEST-000001
$ cat "~/Library/.../nkbihfbeogaeaoehlefnkodbefgpgknn/000003.log"
[encrypted MetaMask vault — but: the encryption key is the user's password,
 brute-forceable for weak passwords; structure leaks accounts, balances, transaction history]
```

Even when the vault itself is encrypted, the extension's storage directory leaks:

- Number of accounts and addresses (visible in plaintext in some entries)
- Network activity history (Infura/Alchemy URLs queried)
- Connected dApps and permissions
- Token balances cached in plaintext
- Transaction history

For password managers (1Password, Bitwarden), the extension storage holds session tokens and cached vault metadata that may enable session hijacking even without the master password.

Extension Storage Protection makes these directories return ENOENT or EACCES to agent processes, while remaining fully accessible to the browser itself and to non-agent user processes.

---

## 2. What we protect

### Browser extension storage paths

For each Chromium-based browser, extensions store data under:

```
<USER_DATA_DIR>/<PROFILE_NAME>/Local Extension Settings/<EXTENSION_ID>/
<USER_DATA_DIR>/<PROFILE_NAME>/IndexedDB/chrome-extension_<EXTENSION_ID>_*/
<USER_DATA_DIR>/<PROFILE_NAME>/Sync Extension Settings/<EXTENSION_ID>/
<USER_DATA_DIR>/<PROFILE_NAME>/Extensions/<EXTENSION_ID>/<VERSION>/
<USER_DATA_DIR>/<PROFILE_NAME>/Local Storage/leveldb/   # contains chrome-extension://* origin entries
<USER_DATA_DIR>/<PROFILE_NAME>/Session Storage/         # rare for extensions but possible
```

For Firefox-based browsers (deferred to v0.2):

```
~/Library/Application Support/Firefox/Profiles/<PROFILE>/storage/default/moz-extension+++<UUID>/
~/Library/Application Support/Firefox/Profiles/<PROFILE>/extension-store/
```

### v0.1 protected extensions

Curated list. Each entry maps a friendly name to known extension IDs across Chromium browsers (the IDs are usually identical across Chrome/Brave/Edge/Arc but can differ).

| Friendly name | Chrome/Brave/Edge/Arc ID |
|---|---|
| MetaMask | `nkbihfbeogaeaoehlefnkodbefgpgknn` |
| MetaMask Beta | `pbpjkcldjiffchgbbndmhojiacbgflha` |
| Phantom | `bfnaelmomeimhlpmgjnjophhpkkoljpa` |
| Coinbase Wallet | `hnfanknocfeofbddgcijnmhnfnkdnaad` |
| Rabby | `acmacodkjbdgmoleebolmdjonilkdbch` |
| Rainbow | `opfgelmcmbiajamepnmloijbpoleiama` |
| Backpack | `aflkmfhebedbjioipglgcbcmnbpgliof` |
| Solflare | `bhhhlbepdkbapadjdnnojkbgioiodbic` |
| Trust Wallet | `egjidjbpglichdcondbcbdnbeeppgdph` |
| OKX Wallet | `mcohilncbfahbmgdjkbpemcciiolgcge` |
| Frame | `ldcoohedfbjoobcadoglnnmmfbdlmmhf` |
| 1Password | `aeblfdkhhhdcdjpifhhbdiojplfjncoa`, `dppgmdbiimibapkepcbdbmkaabgiofem` |
| Bitwarden | `nngceckbapebfimnlniiiahkandclblb` |
| Dashlane | `fdjamakpfbbddfjaooikfcpapjohcfmg` |
| LastPass | `hdokiejnpimakedhajhdlcegeplioahd` |

The list ships in-app and updates with Sanctuary releases (same supply-chain reasoning as the agent classifier list — `CLASSIFIER_SPEC §8`). Users can add custom extensions by ID via:

```bash
sanctuary protect-extension <chrome-extension-id>
sanctuary protect-extension <id> --browser brave
```

### Per-extension paths to protect

For a given extension ID `<ID>` in a profile at `<PROFILE_DIR>`:

```
<PROFILE_DIR>/Local Extension Settings/<ID>/
<PROFILE_DIR>/IndexedDB/chrome-extension_<ID>_*/
<PROFILE_DIR>/Sync Extension Settings/<ID>/
<PROFILE_DIR>/Extensions/<ID>/      # the extension code itself
<PROFILE_DIR>/databases/chrome-extension_<ID>_*/
```

`Local Storage/leveldb/` is shared across all origins in the profile so we cannot path-block selectively. Two options:

- **Option A**: protect the entire `Local Storage/leveldb/` directory when ANY protected extension is registered for the profile. Coarse but safe.
- **Option B**: leave `Local Storage/leveldb/` accessible. Accept partial leakage. (Most modern extensions use IndexedDB or `Local Extension Settings/`, not Local Storage. Real wallet metadata in Local Storage is rare.)

**v0.1 decision**: Option B (leave it). Document the gap. Revisit if a wallet is found to actually use Local Storage for sensitive data.

---

## 3. Enforcement layers

The same path can be reached by an agent in three ways. Each needs blocking.

### Layer 1: Direct filesystem read

`cat`, `cp`, `ls`, custom Swift/Python/Node code calling `open()` or `readdir()`.

**Without ES entitlement** (v0.1 default): use FSEvents to observe access. We can't block synchronously — by the time FSEvents fires, the read has already happened. Instead:

- Watch protected extension paths via FSEvents
- When an agent process touches one, log immediately and surface alert
- Mitigation: this layer is detection-only without ES. Documented gap.

**With ES entitlement** (v0.2): subscribe to `ES_EVENT_TYPE_AUTH_OPEN` for protected paths. Deny synchronously when peer is an agent.

This is the layer where `FSEVENTS_DETECTION_SPEC` does the heavy lifting in v0.1.

### Layer 2: CDP read

Agent uses `chrome.storage.local.get()` via injected JS through CDP. CDP Guard (Spec 2) already blocks agent CDP attachment to protected profiles. **No additional work needed in this spec for Layer 2** — CDP Guard handles it.

### Layer 3: Browser-mediated extension messaging

Agent sends Chrome native messaging or extension-to-extension messages. Requires the agent to have its own extension installed in the user's browser. This is a different attack class — out of scope for v0.1. Listed in v0.3 scope as "browser-native integration."

### Summary of v0.1 enforcement

| Layer | v0.1 enforcement | v0.2 upgrade |
|---|---|---|
| Direct filesystem | Detection + alert (FSEvents) | Synchronous deny (ES) |
| CDP | Synchronous deny via CDP Guard | n/a |
| Native messaging | Out of scope | Scope decision |

---

## 4. Storage in the policy DB

```sql
CREATE TABLE protected_extensions (
    id INTEGER PRIMARY KEY,
    profile_path TEXT NOT NULL,
    extension_id TEXT NOT NULL,
    friendly_name TEXT,
    added_at INTEGER NOT NULL,
    UNIQUE(profile_path, extension_id)
);

CREATE INDEX idx_protected_ext_profile ON protected_extensions(profile_path);
```

The daemon at startup:

1. Reads all `protected_extensions` rows
2. For each row, materializes the actual paths from §2 ("per-extension paths")
3. Registers each materialized path with the FSEvents watcher (and ES, if entitlement granted)

When a user runs `sanctuary protect-extension`:

1. Insert row into `protected_extensions`
2. Refresh FSEvents/ES subscriptions for the new paths
3. No browser restart required

---

## 5. CLI surface

```
sanctuary protect-extension <id-or-friendly-name> [--profile <path>] [--browser chrome|brave|edge|arc]
sanctuary unprotect-extension <id-or-friendly-name> [--profile <path>]
sanctuary list-extensions
sanctuary list-extensions --available     # show all installed extensions in protected profiles
```

`<id-or-friendly-name>` accepts both `nkbihfbeogaeaoehlefnkodbefgpgknn` and `metamask` (case-insensitive friendly name lookup against the curated list).

If `--profile` is omitted, applies to all protected browser profiles. If `--browser` is omitted, applies to all running Chromium browsers.

`list-extensions --available` walks each protected profile's `Extensions/` directory and prints the IDs found, with friendly names where known. Useful first run to know what to protect.

---

## 6. Default protected extensions on first run

When the user first installs Sanctuary and protects their first browser profile, the menu bar prompts:

> **Protect wallets and password managers?**
>
> Sanctuary detected the following extensions in your browser. We recommend protecting them so AI agents can't read their data:
>
> ☑ MetaMask
> ☑ Phantom
> ☑ 1Password
> ☐ uBlock Origin (not in protected list)
>
> [Protect Selected] [Skip]

Defaults checked: any extension whose ID is in the curated list AND is currently installed in the profile being protected. User can uncheck individually or hit Skip.

This is the only auto-protection. We never silently protect without consent.

---

## 7. Edge cases

### User updates an extension (new version directory appears)

The extension code lives at `Extensions/<ID>/<VERSION>/`. When Chrome auto-updates an extension, a new `<VERSION>` directory appears alongside the old one. Our path-protection should match the entire `Extensions/<ID>/` parent, not specific version subdirectories. Already handled by §2 path list (we protect `Extensions/<ID>/`, not `Extensions/<ID>/<VERSION>/`).

### User uninstalls a protected extension

The directories disappear. FSEvents watchers handle deletion gracefully (the watcher just stops firing). The DB entry stays — if the user reinstalls, protection resumes automatically. Optionally surface in `sanctuary list-extensions` that the extension is no longer installed.

### User has multiple profiles

Each protected profile is a separate row in `protected_profiles`. Extension protection is per-profile. Common pattern: user has a "personal" profile (protected) and a "dev" profile (unprotected, used with agents).

### Browser profile directory moves or is renamed

Path changes break our watchers. Daemon should monitor `protected_profiles` paths for existence; if a profile path stops existing, surface a menu bar warning. User can `sanctuary unprotect-profile` and re-protect with the new path.

### Hard links to extension storage from outside the profile

`ln /path/inside/profile /tmp/leak`. The hardlink resolves to the same inode but a different path. Our path-based protection misses this if the agent reads via the hardlink path. **Documented gap in v0.1.** ES (when available) operates on inodes via `es_event_open_t`'s file struct, which closes this gap automatically in v0.2.

### Browser running while we install/uninstall protection

No browser restart needed. FSEvents watcher is added/removed live. Browser keeps reading its own files — we only block agent reads, and the watcher's first event after registration captures the state.

---

## 8. Test plan

### Unit tests

1. Friendly name lookup: `metamask` → `nkbihfbeogaeaoehlefnkodbefgpgknn`
2. Friendly name lookup: case-insensitive
3. Path materialization: given profile path + extension ID, returns all 5 paths from §2
4. Path materialization: handles trailing slash on profile path
5. Wildcard expansion: `IndexedDB/chrome-extension_<ID>_*` finds matching directories
6. DB upsert: inserting same (profile, extension) twice doesn't error, updates timestamp
7. CLI parses `--browser chrome` correctly
8. CLI parses positional friendly name `metamask`
9. CLI parses positional ID `nkbihfbeogaeaoehlefnkodbefgpgknn`
10. `list-extensions --available` finds installed extensions in a fixture profile

### Integration tests

11. Real Chrome with MetaMask installed. Run `sanctuary protect-extension metamask --profile <path>`. Verify FSEvents watcher registered for the 5 expected paths.
12. As (11), then `cat <path>/Local\ Extension\ Settings/<ID>/000003.log` from Terminal (non-agent) → succeeds, no alert
13. As (11), then same `cat` from a user-tagged agent process → audit log entry recorded within 200ms (FSEvents latency)
14. Run `sanctuary list-extensions --available` against a Chrome with 5 extensions installed → output lists all 5 with friendly names where known
15. `sanctuary unprotect-extension metamask` → watcher unregistered, no further alerts on access

### Demo path test (paired with CDP_GUARD_SPEC §11 test 21)

16. Combined drain-attack scenario:
    - Real testnet wallet, $10 testnet ETH
    - Agent A: drives MetaMask UI via CDP → blocked by CDP Guard
    - Agent B: reads MetaMask LevelDB directly → detected by Extension Storage Protection (alert + log)
    - Both attacks visible in `sanctuary log`
    - Wallet untouched

This combined test is the actual demo video content.

---

## 9. Definition of done

- [ ] All unit tests in §8 pass
- [ ] Integration tests 11-15 pass against real Chrome
- [ ] Demo path test 16 passes and is recordable
- [ ] First-run prompt (§6) implemented in menu bar
- [ ] CLI commands all functional
- [ ] Curated extension list contains all v0.1 entries from §2
- [ ] FSEvents watcher latency < 200ms in test environment
- [ ] Documented gaps (Local Storage/leveldb, hardlinks) noted in user-facing docs

---

## 10. Open implementation questions

1. **FSEvents granularity**: FSEvents reports directory-level events by default. We need per-file events. Use `kFSEventStreamCreateFlagFileEvents` and verify latency is still under budget.
2. **Directory tree walking on protect**: registering a watcher for `Local Extension Settings/<ID>/` needs the directory to exist. If extension is installed but storage hasn't been initialized yet, the dir may not exist. Watch the parent and watch for child creation.
3. **Extension version detection**: should `list-extensions --available` show currently-installed version? Useful for support but adds complexity. v0.1 default: no, just show ID + name.
4. **Sync extension settings**: `Sync Extension Settings/` is populated only when Chrome Sync is enabled. Always include in the protected paths list — no harm if absent.
