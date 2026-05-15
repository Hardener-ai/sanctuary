# Sanctuary SDK

**Status:** Draft. Target shipping with v0.2. Subject to revision before 1.0.

This document describes how AI agents integrate with the Sanctuary runtime to
request capabilities, obtain local human approval, and emit audit events.

## Purpose

Sanctuary mediates the privilege gap between agents and the operating system.
Today, an agent running on a developer's laptop inherits the user's local
privilege. It can read files, connect to services, and execute tools in the
same security context as the user. There is no scoped grant, no local owner
approval, and no durable audit trail that survives the agent process.

The Sanctuary SDK is the cooperative path forward. Instead of relying on raw
user privilege, an agent:

1. Establishes a short-lived session with the local Sanctuary daemon.
2. Requests typed capabilities scoped to a workspace and purpose.
3. Performs work inside granted scopes.
4. Emits audit events as it works.

Integrated agents get better user experience: native approval prompts, scoped
grants, fewer surprise denials, and a clear audit trail. Non-integrated agents
still operate, but fall back to generic observation and interception through
FSEvents, `pf`, and, after entitlement approval, Endpoint Security.

## Runtime Model

Sanctuary runs as a local daemon. Agents connect over a Unix domain socket by
default. A loopback HTTP bridge may be enabled for development and
cross-language prototyping.

- **Recommended production transport:** Unix domain socket at
  `~/Library/Application Support/sanctuary/daemon.sock`. Peer process identity
  is verified with `LOCAL_PEERPID` / `SO_PEERCRED`-style metadata where the
  platform exposes it. The socket is created with `0600` permissions.
- **Development bridge:** `http://127.0.0.1:7878`, disabled by default in
  production policy. It is loopback-only and bearer-token authenticated.

The wire format and endpoint surface are identical across transports. Examples
below use HTTP for readability.

A **session** represents one agent invocation: a coding task, an IDE agent run,
or a Computer Use session. Sessions are short-lived by default.

A **capability** is a typed permission: a verb such as `file.write`, a scope
such as `~/src/auth`, and a duration such as `session`.

A **grant** is an approved capability. Grants are issued by the daemon after
policy evaluation and, when needed, local owner approval through the menu bar
app.

An **audit event** is an immutable record of an operation performed under a
grant. Events are appended to Sanctuary's hash-chained audit log.

## Agent Identity

Every session declares an agent identity.

```json
{
  "agent": {
    "id": "claude-code",
    "version": "0.18.2",
    "vendor": "anthropic",
    "binary_path": "/opt/homebrew/bin/claude",
    "binary_sha256": "..."
  },
  "purpose": "Refactor authentication module",
  "workspace": "/Users/tobias/src/forge-terminal"
}
```

The daemon cross-checks declared identity against the calling process, parent
chain, code signature, binary hash, and known-agent registry. Mismatches are
surfaced to the user and downgrade the trust level applied to capability
requests.

## Capability Taxonomy

The v0.2 capability surface is intentionally small.

| Capability | Scope object |
| --- | --- |
| `file.read` | `{ path, recursive, globs?, exclude_globs? }` |
| `file.write` | `{ path, recursive, globs?, exclude_globs? }` |
| `file.delete` | `{ path, recursive, globs?, exclude_globs? }` |
| `net.connect` | `{ hosts: [string], ports?: [number], protocols?: ["tcp", "udp"] }` |
| `exec.shell` | `{ allowed_commands: [string], cwd, env_passthrough?: [string] }` |
| `exec.app` | `{ bundle_id, args?: [string] }` |
| `system.keychain` | `{ services: [string], accounts?: [string] }` |
| `device.screen` | `{ displays?: [number] }` |

All capabilities take an optional `duration`: `one_shot`, `session`, or
`persistent`. Persistent grants require explicit local owner approval and are
revocable from the menu bar app.

Protected resources such as `~/.ssh`, `~/.aws`, wallet extension storage, and
browser credential stores are never implicitly granted. They require explicit
policy or user approval.

### `exec.shell` Is Restricted

`exec.shell` is not a generic "run any shell" primitive. v0.2 supports only:

- **Explicit command families:** `allowed_commands` is required and is matched
  against the invoked binary name. Wildcards are not honored.
- **Scoped working directory:** `cwd` must be inside the session workspace.
  Parent traversal is rejected.
- **Sanitized environment:** only variables listed in `env_passthrough` are
  forwarded.
- **Trusted-agent policy:** the agent must be classified as trusted for
  `exec.shell` to be eligible for grant.

Broad grants such as `bash -c <arbitrary>`, `sudo`, or full environment
passthrough are out of scope. Agents that need richer execution should declare
specific tools through `exec.app` or request a capability extension.

## API Surface

### `POST /v1/sessions`

Establish a session.

```json
{
  "agent": { "id": "claude-code", "version": "0.18.2", "vendor": "anthropic" },
  "purpose": "Refactor authentication module",
  "workspace": "/Users/tobias/src/forge-terminal",
  "ttl_seconds": 3600
}
```

```json
{
  "session_id": "ses_01HQT8...",
  "token": "snc_sk_...",
  "expires_at": "2026-05-15T16:00:00Z",
  "policy_hint": "trusted"
}
```

### `POST /v1/capabilities/request`

Request a capability within a session.

```json
{
  "session_id": "ses_01HQT8...",
  "capability": "file.write",
  "scope": {
    "path": "~/src/forge-terminal",
    "recursive": true,
    "exclude_globs": [".env", "*.pem", "*.key"]
  },
  "duration": "session",
  "rationale": "Apply refactor to auth/ subtree"
}
```

Auto-approved by policy:

```json
{
  "grant_id": "grt_01HQT8...",
  "status": "approved",
  "approval_method": "policy",
  "expires_at": "2026-05-15T16:00:00Z"
}
```

Touch ID required:

```json
{
  "grant_id": "grt_01HQT8...",
  "status": "pending",
  "approval_method": "touch_id",
  "approval_handle": "apr_01HQT8..."
}
```

Denied:

```json
{
  "grant_id": null,
  "status": "denied",
  "reason": "scope_intersects_protected_path",
  "details": { "protected_path": "~/.ssh" }
}
```

Agents poll `GET /v1/approvals/{approval_handle}` or subscribe to `/v1/events`
for resolution. The menu bar app renders approval UI; agents never present
their own security prompts.

### `POST /v1/audit`

Emit an audit event.

```json
{
  "session_id": "ses_01HQT8...",
  "grant_id": "grt_01HQT8...",
  "operation": "file.write",
  "target": "~/src/forge-terminal/auth/login.ts",
  "metadata": {
    "bytes": 4821,
    "sha256_before": "...",
    "sha256_after": "..."
  }
}
```

```json
{
  "audit_id": "aud_01HQT8...",
  "chain_index": 18472,
  "chain_hash": "..."
}
```

### `DELETE /v1/sessions/{session_id}`

End a session and revoke session-scoped grants.

## Human Approval Flow

When a capability requires local owner approval, the menu bar app presents a
native prompt:

```text
Claude Code wants to write files in ~/src/forge-terminal

Purpose:  Refactor authentication module
Scope:    ~/src/forge-terminal (recursive)
Excludes: .env, *.pem, *.key
Duration: This session

[ Deny ]                         [ Approve with Touch ID ]
```

Approval methods:

1. **Policy:** pre-approved for this agent, workspace, and scope.
2. **Touch ID:** interactive local owner approval.
3. **Admin policy:** future Hardener Cloud fleet policy.

Denials are sticky for the session. Repeated requests for the same denied
capability are rate-limited.

## Workspace-Scoped Grants

Most grants should be workspace-scoped. A workspace is a project root such as a
Git repository or IDE workspace directory. Grants for one workspace do not
transfer to another workspace.

This is the primary defense against an agent reading secrets while working in
an unrelated project.

## Audit Event Schema

Every event in the chain carries:

- `audit_id`
- `chain_index`
- `prev_chain_hash`
- `chain_hash`
- `session_id`
- `grant_id`
- `agent.id`
- `operation`
- `target`
- `outcome`
- `timestamp`
- `signature`

The chain is verified on read. Hardener Cloud will export audit batches to SIEM
systems with chain continuity guarantees.

## Non-Goals

- Cross-platform parity in v0.2.
- TLS interception.
- Generic application sandboxing.
- Multi-agent orchestration in the local runtime.
- Cloud round-trip in the hot path.

All approval and enforcement decisions are local. Cloud policy sync and audit
export are asynchronous enterprise features.

## Reference Integration

```python
import os
import requests
import subprocess

SNC = "http://127.0.0.1:7878"

session = requests.post(f"{SNC}/v1/sessions", json={
    "agent": {"id": "claude-code", "version": "0.18.2", "vendor": "anthropic"},
    "purpose": "Refactor authentication module",
    "workspace": os.getcwd(),
    "ttl_seconds": 3600,
}).json()

headers = {"Authorization": f"Bearer {session['token']}"}

for capability, scope in [
    ("file.read", {"path": os.getcwd(), "recursive": True}),
    ("file.write", {
        "path": os.getcwd(),
        "recursive": True,
        "exclude_globs": [".env", "*.pem", "*.key"],
    }),
    ("exec.shell", {
        "cwd": os.getcwd(),
        "allowed_commands": ["git", "swift", "xcodebuild"],
    }),
]:
    response = requests.post(f"{SNC}/v1/capabilities/request", headers=headers, json={
        "session_id": session["session_id"],
        "capability": capability,
        "scope": scope,
        "duration": "session",
    }).json()
    if response["status"] == "denied":
        raise SystemExit(f"Capability denied: {capability}: {response['reason']}")

proc = subprocess.run(["claude", "code", "refactor", "auth/"], capture_output=True)

requests.post(f"{SNC}/v1/audit", headers=headers, json={
    "session_id": session["session_id"],
    "operation": "agent.run",
    "target": "claude code refactor auth/",
    "metadata": {"exit_code": proc.returncode},
})

requests.delete(f"{SNC}/v1/sessions/{session['session_id']}", headers=headers)
```

Swift, TypeScript, and Go client libraries are planned after the v0.2 API
stabilizes.

## Versioning

The SDK is preview until v0.2 ships. The API is versioned through `/v1/`.
Post-1.0 breaking changes require a new major path and a deprecation window.

## Feedback

If you ship an agent on macOS and want to integrate, open an issue tagged
`sdk-integration` or contact `hello@hardener.ai`.
