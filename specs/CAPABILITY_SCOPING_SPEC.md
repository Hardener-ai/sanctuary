# CAPABILITY_SCOPING_SPEC

**Status**: v0.2 architecture spec  
**Owner**: SanctuaryDaemon, SanctuaryCLI, SanctuaryMenuBar  
**Related specs**: `CLASSIFIER_SPEC.md`, `FSEVENTS_DETECTION_SPEC.md`, `INVISIBILITY_SPEC.md`, `HUMAN_APPROVAL_SPEC.md`, `TAMPER_RESISTANCE_SPEC.md`, `COVERAGE_GAPS.md`

---

## 1. Goal

Sanctuary v0.1 protects sensitive resources with a deny-list model: known sensitive folders, wallet extension storage, password manager storage, and CDP debug ports are protected from classified agents. That is the right default. Coding agents need broad access to ordinary project files. They do not need automatic access to wallet storage, SSH keys, cloud credentials, browser secrets, or password manager state.

v0.2 adds a capability scoping layer on top of this deny-list model. The user can grant precise exceptions scoped to a specific process, resource path, and workspace directory. A scoped exception says: "this agent may access this sensitive resource only while working in this workspace."

Example:

> Allow Cursor to read `~/.ssh/deploy_key` while working in `~/Projects/myapp`.

The goal is to keep the default protection strong without making legitimate developer workflows impossible. Sanctuary should block or hide sensitive resources by default, but it should also let the user intentionally grant narrow, auditable capabilities.

## 2. Background

A pure allow-list model would deny everything except explicitly approved files. That model is attractive on paper, but it is wrong for coding agents. Agents are useful because they read and modify project trees, inspect dependencies, run tests, open generated files, and follow code references. A strict allow-list would turn every ordinary coding session into a permissions exercise.

A pure allow-list also pushes users toward unsafe workarounds. If an agent cannot read normal project files without constant prompts, users will disable the security tool, grant broad directory access, or run the agent outside the protected environment. A security product that fights the user's main workflow loses.

A pure deny-list is the right v0.1 default. It protects known sensitive surfaces while leaving project work ergonomic. The protected surfaces are not arbitrary. They map to high-risk resources from `THREAT_MODEL.md`: wallet keys, SSH identities, GPG keys, cloud credentials, browser extension storage, password managers, and browser CDP sessions.

The deny-list model still needs overrides. Some legitimate workflows require narrow access to sensitive material:

- A deployment agent needs one SSH deploy key for one repository.
- A cloud automation agent needs one AWS profile while working on infrastructure code.
- A local build tool needs a signing key for a specific app workspace.
- A user intentionally wants a trusted coding agent to inspect a protected test fixture.

Global exceptions are too broad. "Allow Cursor to read `~/.ssh`" is effectively a permanent bypass for every project. Workspace-scoped exceptions preserve least privilege while respecting real work.

## 3. Model

### 3.1. Default deny for sensitive resources

The baseline remains the current behavior. If a classified agent accesses a protected resource and no exception applies, Sanctuary detects, denies, or makes the resource invisible depending on the protection tier available.

In v0.1, filesystem and extension storage access is detection-only through FSEvents. CDP attachment is denied through CDP Guard. In v0.2, with Endpoint Security, filesystem and extension storage move toward denial or invisibility as described in `INVISIBILITY_SPEC.md`.

### 3.2. Scoped exception tuple

A capability exception is scoped to:

- `process`: the classified agent identity or executable path.
- `resource_path`: the protected file or directory being accessed.
- `workspace_directory`: the project or working directory where the access is permitted.
- `action`: read, write, enumerate, CDP attach, or a future action family.
- `expiration`: session, time-bounded, or permanent.

All fields matter. If Cursor is allowed to read `~/.ssh/deploy_key` while working in `~/Projects/myapp`, that does not allow Cursor to read the same key while working in `~/Downloads/random-repo`. It also does not allow Claude Code, OpenClaw, or a renamed unknown binary to read that key.

### 3.3. Workspace detection

Sanctuary determines workspace context from the process identity. The first implementation uses conservative signals:

- Current working directory from `ProcessIdentity.cwd`.
- Parent-chain working directories where available.
- Known IDE workspace arguments when they are explicit and stable.
- User-selected workspace directory from the approval dialog.

v0.2 should not guess aggressively. If the workspace is unknown, Sanctuary should treat the exception as non-matching and trigger approval. Wrongly granting access is worse than requiring a prompt.

v0.3 can add dynamic workspace detection. Examples include editor workspace metadata, `.git` root discovery, IDE-specific open-folder state, and XPC integration with the menu bar app. Those are convenience improvements, not prerequisites for v0.2.

### 3.4. Expiration modes

Exceptions auto-expire by user choice:

- **Allow once**: one access decision, no persistent exception.
- **Allow 10 minutes**: useful for a short command sequence.
- **Allow this session**: valid until the agent process exits or its startup UUID changes.
- **Permanent for this workspace**: persistent policy row, but still scoped to process, resource, and workspace.

Permanent should never mean global. The UI must make the scope visible in plain language.

## 4. Storage

The policy database gains a new table:

```sql
CREATE TABLE workspace_scoped_exceptions (
    id INTEGER PRIMARY KEY,
    process_identity TEXT NOT NULL,
    executable_path TEXT,
    signing_identifier TEXT,
    team_identifier TEXT,
    resource_path TEXT NOT NULL,
    workspace_directory TEXT NOT NULL,
    action TEXT NOT NULL,
    expiration_kind TEXT NOT NULL,
    expires_at INTEGER,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER,
    source TEXT NOT NULL
);

CREATE INDEX idx_workspace_exceptions_lookup
ON workspace_scoped_exceptions(process_identity, resource_path, workspace_directory, action);

CREATE INDEX idx_workspace_exceptions_expiry
ON workspace_scoped_exceptions(expires_at);
```

The table stores enough process identity to survive ordinary path changes while still avoiding overbroad matching. A signed app can match on signing identity and team identifier. A CLI tool can match on canonical executable path. User-tagged agents can match on their stored tag.

Rows should be covered by the policy database integrity mechanism planned in `TAMPER_RESISTANCE_SPEC.md` §4.5. A root adversary should not be able to silently add a broad exception without creating tamper evidence.

## 5. UX

Users can grant exceptions in three places.

CLI:

```text
sanctuary allow --agent Cursor \
  --resource ~/.ssh/deploy_key \
  --workspace ~/Projects/myapp \
  --action read \
  --duration session
```

Menu bar settings:

- Select protected resource.
- Select agent.
- Select workspace.
- Select duration.
- Confirm with Touch ID for critical resources.

Approval dialog:

- The user sees an attempted access.
- The dialog offers "Allow once", "Allow 10 minutes", "Allow this session", and "Allow for this workspace".
- The workspace grant writes a `workspace_scoped_exceptions` row.

The UI must avoid vague permissions. It should say exactly which agent, resource, workspace, action, and duration are being granted.

## 6. Interaction With Human Approval

`HUMAN_APPROVAL_SPEC.md` defines the approval flow. Capability scoping is the persistence model behind that flow.

When a classified agent touches a sensitive resource and no matching exception exists, the daemon asks the user for a decision. If the user denies, no row is written. If the user allows once, a short-lived in-memory decision is enough. If the user allows for a time window, session, or workspace, the daemon writes an exception row with the selected scope.

Critical and high-risk resources require hardware-backed authentication before a persistent exception is created. That includes SSH private keys, wallet storage, password manager state, GPG private keys, and cloud credential files.

## 7. Implementation Phases

### v0.2: Basic exceptions

- Add `workspace_scoped_exceptions` table.
- Add policy lookup in the daemon before denial or invisibility.
- Support CLI create/list/remove.
- Support approval-dialog creation of scoped exceptions.
- Use conservative workspace detection from current working directory and explicit user choice.
- Add audit entries for exception creation, use, expiration, and removal.

### v0.3: Dynamic workspace detection

- Infer Git repository roots.
- Read stable IDE workspace metadata where privacy-safe.
- Add UI to review and clean stale exceptions.
- Add per-workspace summaries in the menu bar.
- Add policy DB integrity for exception rows if not already shipped.

## 8. Decision Log

**Why deny-list-with-overrides over pure allow-list:** Coding agents need broad project access. A pure allow-list would create constant prompts and push users to disable protection. Sensitive-resource deny-listing preserves the useful workflow while protecting the resources that matter.

**Why workspace-scoped over global:** Global exceptions are too powerful. A project-specific deploy key should be accessible only in the project that needs it. Workspace scope turns a dangerous bypass into a narrow capability.

**Why user-driven exceptions:** Sanctuary should not silently infer that an agent deserves access to secrets. The user must grant capability intentionally.

**Why expiration is part of the model:** Permanent rules accumulate risk. Time and session scopes make the safe path easy for temporary work.

**Why this waits for v0.2:** The model is most useful when Endpoint Security can enforce decisions synchronously. v0.1 can store policy, but it cannot reliably block filesystem reads before the agent sees data.
