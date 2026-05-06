# MCP_PROTECTION_SPEC

**Component**: SanctuaryCore classifier extensions and SanctuaryDaemon inventory
**Status**: v0.1 monitoring and identity inheritance spec
**Owner**: SanctuaryCore / SanctuaryDaemon / Menu Bar

---

## 1. Purpose

MCP servers are part of the agent blast radius.

Model Context Protocol servers are loaded by agents to extend capability:

- read files
- query databases
- call APIs
- drive browsers
- inspect repos
- reach internal services
- wrap command-line tools

A malicious MCP server does not need to compromise the model. It runs as a
local process with the loading agent's practical permissions and can receive
agent-supplied secrets, paths, commands, and user context.

Sanctuary's core assumption is that agents become compromised. That assumption
must include their tool servers.

Therefore:

- an MCP server loaded by an agent inherits the agent verdict
- running MCP servers appear in the agent inventory
- protected resources are denied to MCP servers the same way they are denied to
  the loading agent
- v0.1 treats MCP traffic content inspection as out of scope

MCP is becoming the standard local capability layer for agent ecosystems. If
Sanctuary ignores MCP, it protects the prompt-facing agent while leaving the
tool layer free to touch the user's machine.

---

## 2. Detection

MCP detection has two transport families:

- stdio
- socket

Both matter.

### Stdio MCP

Stdio MCP is launched as a child process by an agent or agent host.

Typical shape:

```text
Claude Code / Cursor / Codex / custom agent
  └── mcp-server-filesystem
        stdin/stdout JSON-RPC messages
```

Detection signals:

- parent process is `.agent` or `.suspicious`
- child process has inherited stdio pipes
- process arguments contain common MCP server names or flags
- executable path matches an `agents.yaml` entry in category `mcp-server`
- package or module fingerprint matches MCP SDK usage
- early bytes on stdin/stdout follow JSON-RPC framing

The classifier must not block waiting to inspect stdio traffic. The hot-path
rule is parent identity first.

Recommended v0.1 stdio detector:

1. Observe process launch.
2. Fetch parent identity.
3. If parent verdict is `.agent`, mark child as MCP-candidate if:
   - executable or argv contains `mcp`, or
   - runtime fingerprint includes MCP SDK, or
   - parent config says it launched this child as an MCP server.
4. Inherit parent verdict for enforcement.
5. Add inventory metadata that this process is likely an MCP server.

### Socket MCP

Socket MCP is a process listening on a local TCP port or Unix socket and serving
the MCP protocol to one or more agents.

Detection signals:

- process listens on localhost or a Unix domain socket
- first application messages are JSON-RPC 2.0
- method names include MCP initialization or tool/resource calls
- process executable or package fingerprint matches MCP SDKs
- connecting client is an agent process

Recommended v0.1 socket detector:

1. Inventory listening processes with local sockets.
2. If a listening process matches `agents.yaml` category `mcp-server`, mark it
   as MCP.
3. If an agent connects to a listening process and protocol hints match MCP,
   associate the server with that agent.
4. Inherit the agent verdict for the server while the association is active.

V0.1 should avoid full MITM parsing. It can use shallow protocol hints and
process identity without intercepting all traffic.

### Protocol Hints

MCP uses JSON-RPC style messages.

Useful shallow hints:

- `"jsonrpc": "2.0"`
- `"method": "initialize"`
- `"method": "tools/list"`
- `"method": "tools/call"`
- `"method": "resources/list"`
- `"method": "resources/read"`
- `"method": "prompts/list"`
- `"method": "prompts/get"`

These hints are not sufficient for high-confidence classification by
themselves. Many local services speak JSON-RPC. Use them only with process or
parent context.

---

## 3. Identity Inheritance

An MCP server inherits the verdict of the agent that loaded it.

Rules:

```swift
if parent.verdict == .agent(reason, confidence):
    child.verdict = .agent(.mcpServer(parent: parentIdentity), confidence)
```

For v0.1, the inherited confidence should not exceed the parent confidence.

Examples:

- Claude Code launches filesystem MCP over stdio:
  - Claude Code is `.agent(.knownList("Claude Code"), .high)`
  - filesystem server becomes `.agent(.mcpServer(parent: "Claude Code"), .high)`

- Custom Python agent launches MCP server:
  - Python process is `.agent(.pythonRuntime, .medium)`
  - MCP server becomes `.agent(.mcpServer(parent: "Python agent runtime"), .medium)`

- Suspicious process launches MCP-like child:
  - parent is `.suspicious(.envVarsPlusShellSpawn)`
  - child is suspicious, not auto-blocked, unless other rules classify it as
    agent

- Agent connects to long-running socket MCP server:
  - server inherits the strongest connected agent verdict while association is
    active
  - inventory records all connected agent clients

Association lifetime:

- stdio association lasts for child process lifetime
- socket association lasts while an agent connection is open
- long-running socket server may have multiple associations
- if any active association is `.agent`, enforcement treats the server as
  `.agent`

Fail-safe:

- if a protected resource access comes from a known MCP child of an agent,
  block as agent
- if attribution is uncertain, prompt or inventory rather than silently allow
  broad access

---

## 4. Menu Bar Surface

MCP servers should be visible.

The menu bar agent inventory includes:

- running foreground agents
- running background services
- running MCP servers
- suspicious runtimes

MCP row fields:

- server process name
- pid
- executable path
- transport: stdio, TCP, Unix socket, unknown
- loaded by: agent name and pid
- verdict inherited from parent
- confidence
- first seen timestamp
- last activity timestamp
- protected-resource denials

User actions:

- reveal process path
- trust this server
- classify this server as agent
- view recent denials
- terminate process, if allowed by OS permissions

Trusting an MCP server should be rare and explicit. The UI must make clear that
trusting the server may allow it to access protected resources even when loaded
by an agent. Default recommendation: trust the parent app only if the user
understands the consequences.

Audit log additions:

```json
{
  "action": "MCP_SERVER_DETECTED",
  "server": {"pid": 1234, "path": "/usr/local/bin/filesystem-mcp"},
  "transport": "stdio",
  "loaded_by": {"pid": 1200, "path": "/usr/local/bin/claude"},
  "verdict": "agent",
  "confidence": "high"
}
```

---

## 5. Out Of Scope For v0.1

Content-level MCP traffic inspection is out of scope for v0.1.

Reasons:

- stdio MITM requires wrapping or injecting between parent and child
- agents may spawn MCP servers directly without a Sanctuary wrapper
- content inspection risks logging secrets
- schema-specific traffic analysis can become brittle quickly

Deferred to v0.3:

- optional MCP traffic proxy for configured servers
- tool-call allowlists
- prompt/resource content inspection
- per-tool audit controls
- policy templates for common MCP servers

V0.1 goal:

- identify MCP server processes
- inherit agent identity
- show inventory
- apply protected-resource enforcement based on inherited verdict

That prevents the most damaging local blast-radius failures without turning
Sanctuary into an MCP firewall too early.

---

## 6. Test Cases

Minimum unit tests for v0.1:

1. **Stdio child inherits high-confidence agent**
   - parent: Claude Code `.agent(.knownList, .high)`
   - child argv contains `mcp-server-filesystem`
   - expected: child `.agent(.mcpServer, .high)`

2. **Stdio child inherits medium-confidence runtime**
   - parent: Python runtime `.agent(.pythonRuntime, .medium)`
   - child executable contains `mcp`
   - expected: child `.agent(.mcpServer, .medium)`

3. **Suspicious parent does not auto-block child**
   - parent: `.suspicious(.envVarsPlusShellSpawn)`
   - child argv contains MCP hints
   - expected: child suspicious or inventory-only, not high-confidence agent

4. **Non-agent parent with MCP-looking child is inventory-only**
   - parent: Terminal `.notAgent`
   - child argv contains `mcp`
   - expected: no auto-block unless registry or runtime rules match

5. **Socket server inherits from connected agent**
   - server process is listening on localhost
   - Claude Code connects
   - expected: server associated with Claude Code and treated as agent while
     connection is active

6. **Socket server with only non-agent clients stays notAgent**
   - server process speaks JSON-RPC
   - only Terminal-launched client connects
   - expected: inventory-only or notAgent

7. **Multiple agent clients choose strongest verdict**
   - Cursor high-confidence and custom Python medium-confidence connect
   - expected: server effective verdict high-confidence agent

8. **Association ends when socket closes**
   - agent disconnects from socket MCP server
   - no other agent connections remain
   - expected: inherited verdict expires after association cleanup

9. **MCP SDK runtime fingerprint**
   - Node process has `@modelcontextprotocol/sdk`
   - expected: `.agent(.nodeRuntime, .medium)` or MCP candidate depending on
     parent context

10. **No protocol-only false positive**
    - unrelated JSON-RPC service with no agent parent or MCP SDK
    - expected: `.notAgent`

11. **Audit event includes loaded-by identity**
    - MCP server detected from stdio child
    - expected: audit event records parent pid/path and inherited confidence

12. **Menu inventory groups MCP separately**
    - active agent and two MCP children
    - expected: MCP servers appear under MCP section with parent labels

---

## 7. Security Notes

MCP protection is identity protection first.

Sanctuary should not pretend it understands every tool call in v0.1. The secure
thing is to recognize that an MCP server loaded by an agent is acting on behalf
of that agent, then apply the same protected-resource policy.

This keeps the model simple:

- parent agent compromised
- MCP server becomes part of compromised execution graph
- protected resources stay protected

The implementation should avoid logging MCP payloads by default. Tool calls may
contain prompts, tokens, filesystem paths, database rows, or credentials. Audit
metadata is enough for v0.1.
