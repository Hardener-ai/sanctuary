# CLASSIFIER_SPEC

**Component**: `Sources/SanctuaryCore/AgentClassifier.swift`
**Status**: spec for v1 implementation
**Owner**: SanctuaryCore
**Test target**: `Tests/SanctuaryCoreTests/AgentClassifierTests.swift`

---

## 1. Purpose

The agent classifier answers one question for every process Sanctuary's enforcement layers see:

> Is this process an AI agent?

This is the foundational primitive of the entire product. Every enforcement decision (deny file open, drop CDP connection, blank clipboard, hide keychain item) routes through this classifier. If the classifier is wrong, the product is wrong.

There are two failure modes, both existential:

| Failure | Effect |
|---|---|
| **False positive** (classify normal process as agent) | User's actual workflow breaks. Sanctuary blocks Terminal, IDE, Spotlight indexer, Time Machine. User uninstalls within 24h. |
| **False negative** (classify agent as normal) | Agent silently accesses protected resources. Demo video doesn't work. Trust dies. |

The classifier must be **conservative on auto-block** (only block when high-confidence) and **liberal on prompt** (escalate ambiguous cases to a UI prompt with Touch ID override).

---

## 2. Classification verdicts

The classifier returns one of three verdicts, never a boolean.

```swift
public enum AgentVerdict: Equatable {
    case agent(reason: AgentReason, confidence: Confidence)
    case suspicious(reason: SuspicionReason)
    case notAgent
}

public enum Confidence: Equatable {
    case high   // explicit list match, signed by known vendor
    case medium // process tree match, runtime fingerprint
    case low    // heuristic only
}
```

| Verdict | Action |
|---|---|
| `.agent(_, .high)` | Auto-block protected resource access. Log. |
| `.agent(_, .medium)` | Auto-block. Log. UI badge. |
| `.agent(_, .low)` | Treated as `.suspicious` for v0.1. Reserved for future tightening. |
| `.suspicious` | Don't auto-block. Surface UI prompt with Touch ID override. Log either way. |
| `.notAgent` | Allow. Fast path. |

---

## 3. Inputs

The classifier takes a `ProcessIdentity` and returns a verdict. `ProcessIdentity` is built once per process and cached for the process lifetime.

```swift
public struct ProcessIdentity {
    let pid: pid_t
    let executablePath: String          // resolved real path
    let bundleIdentifier: String?       // if app bundle
    let codeSigningIdentifier: String?  // from SecCodeCopySigningInformation
    let teamIdentifier: String?         // Apple Team ID
    let parentChain: [pid_t]            // up to 8 ancestors
    let environmentVars: Set<String>    // names only, not values
    let cwd: String?
    let arguments: [String]
}
```

### Sources for each field

| Field | Source | Reliability |
|---|---|---|
| `pid` | ES event / proc_listpids | trivial |
| `executablePath` | proc_pidpath + realpath | high (kernel-supplied) |
| `bundleIdentifier` | NSRunningApplication.bundleIdentifier | medium (apps only) |
| `codeSigningIdentifier` | SecCodeCopySigningInformation | high; nil if unsigned |
| `teamIdentifier` | SecCodeCopySigningInformation | high; nil if unsigned |
| `parentChain` | proc_pidinfo PROC_PIDPARENTAUDITINFO | high |
| `environmentVars` | proc_pidinfo PROC_PIDREGIONPATHINFO + KERN_PROCARGS2 | medium (env vars must be enumerated, not value-read) |
| `arguments` | KERN_PROCARGS2 | high |

**Privacy note**: the classifier reads env var **names** but NOT values. This is non-negotiable. Logging the value of `ANTHROPIC_API_KEY` is exactly the kind of credential exfil Sanctuary exists to prevent.

---

## 4. Classification rules (in order of precedence)

Rules are evaluated top-to-bottom. First match wins.

### Rule 1: Explicit user allowlist

```
if executablePath ∈ user's "never classify as agent" list:
    return .notAgent
```

User can mark binaries as forever-trusted via `sanctuary trust <path>`. Rare but necessary escape hatch.

### Rule 2: Explicit user agent-list

```
if executablePath ∈ user's "always classify as agent" list:
    return .agent(.userTagged, .high)
```

Set via `sanctuary agents add <path>`.

### Rule 3: Known agent binary list (curated)

The curated list is a Swift array shipped with each release. Updates ship in app updates, NOT auto-fetched from a remote (security boundary). Each entry has:

```swift
struct KnownAgent {
    let executableNames: [String]      // e.g. ["claude", "claude-code"]
    let bundleIdentifiers: [String]    // e.g. ["com.anthropic.claude-code"]
    let codeSigningIdentifiers: [String]
    let teamIdentifiers: [String]      // Apple Team IDs
    let displayName: String
}
```

A process matches if (executableName matches AND it's signed by the expected team) OR (bundleIdentifier matches AND signed appropriately). **Unsigned binaries with matching names match only on path, with downgraded confidence to medium.**

#### v0.1 known agent list

The known agent list is loaded from `agents.yaml` at the repo root. See `AGENT_REGISTRY_SPEC.md` for schema and update process. The list is bundled into the binary at compile time, not fetched at runtime.

Verdict: `.agent(.knownList(displayName), .high)` if signed-and-matches, `.agent(.knownList(displayName), .medium)` if path-matches-only.

### Rule 3.5: LaunchAgent / LaunchDaemon origin

If process is parented to `launchd` AND the loading plist's `ProgramArguments` or `Program` reference a known agent binary, runtime, or signature → `.agent(.serviceLaunch, .high)`.

Plist locations checked:

- `~/Library/LaunchAgents/`
- `/Library/LaunchAgents/`
- `/Library/LaunchDaemons/`
- `~/Library/LaunchDaemons/`

Plist matching is done by walking the directories at daemon start and on FSEvents change, parsing each plist, and indexing by `Label`, `ProgramArguments[0]`, and any embedded module specifier such as `-m hermes_cli.main` in `ProgramArguments`. When a process is classified and its parent chain ends at `launchd`, the index is consulted. A match on `Label`, `Program` path, or argv module pattern returns `.agent(.serviceLaunch, .high)`.

### Rule 4: Process tree contains known agent

If any ancestor in `parentChain` matches Rule 3 (recursively), this process is an agent too.

Verdict: `.agent(.parentChain(ancestor), .high)` (inherits from parent verdict, downgraded one level if ancestor was medium).

**Critical exception**: `launchd` (pid 1) and `bash`/`zsh` shells in the chain don't propagate. We track the **first non-shell, non-launchd ancestor**. Otherwise launching a non-agent tool from an agent's spawned shell would incorrectly classify the tool as an agent in a way the user can't escape.

Wait — we WANT that propagation actually. If Claude Code spawns a shell which spawns `cat ~/.ssh/id_rsa`, the `cat` is acting on the agent's behalf and should be blocked. Re-stating: parent chain propagation is **on by default** including through shells. The exception is only `launchd` itself (everything has launchd in its chain — would classify the world).

### Rule 5: Runtime fingerprint — Python

A Python process whose imported modules include known agent SDKs is a probable agent.

```
if executable matches python3.x AND
   (loaded dylibs / sys.modules contains 'anthropic' OR 'openai' OR 'langchain' OR
    'langgraph' OR 'crewai' OR 'autogen' OR 'smolagents' OR 'mastra')
:
    return .agent(.pythonRuntime, .medium)
```

Implementation: read `/proc`-equivalent loaded modules via `proc_pidinfo PROC_PIDREGIONPATHINFO`. If a `.dylib` matching `anthropic*.so` or `openai*.so` is loaded, fingerprint matches.

Caveat: Python is also used for unrelated work. Don't auto-block at high confidence. Medium is correct here.

### Rule 5.5 — Python argv module / venv path inspection

If executable matches `python3.x` AND any of:

- argv contains `-m <module>` where `<module>` matches a registry runtime-fingerprint `python_modules` entry
- argv[0] resolves to a path under `<venv>/bin/<name>` where `<name>` matches a registry runtime-fingerprint `executable_names` entry
- process `cwd` or `executablePath` contains a known agent install path prefix from the registry (e.g. `~/.hermes/`, `~/.claude/`)
- `<venv>/lib/python*/site-packages/` contains a directory matching a registry `python_modules` entry

Verdict: `.agent(.pythonRuntime, .high)` on argv module or venv console script match, `.agent(.pythonRuntime, .medium)` on install path or site-package match.

### Rule 6: Runtime fingerprint — Node

Same idea for Node:

```
if executable matches node AND
   (require.cache or imported packages contains '@anthropic-ai/sdk' OR
    'openai' OR '@modelcontextprotocol/sdk' OR 'ai' (Vercel AI SDK))
:
    return .agent(.nodeRuntime, .medium)
```

For Node, inspecting the package cache from outside the process is harder than Python. Approximation: walk the cwd for a `package.json` listing those deps. Imperfect but cheap.

### Rule 6.5 — Node argv script / package.json inspection

If executable matches `node` AND any of:

- argv[1] resolves to a path under `<node_modules>/<package>/<entrypoint>` where `<package>` matches a registry runtime-fingerprint `node_packages` entry
- the cwd or argv[1] parent's `package.json` declares a dependency matching a registry `node_packages` entry

Verdict: `.agent(.nodeRuntime, .high)` on direct `node_modules` entrypoint match, `.agent(.nodeRuntime, .medium)` on package manifest dependency match.

### Rule 7: Heuristic — env vars + spawn pattern

```
if process has env var name in {ANTHROPIC_API_KEY, OPENAI_API_KEY,
                                 OPENROUTER_API_KEY, GEMINI_API_KEY,
                                 GROQ_API_KEY, MISTRAL_API_KEY} AND
   process spawned a child shell within last 60s
:
    return .suspicious(.envVarsPlusShellSpawn)
```

This is the most ambiguous rule. Many legitimate developer workflows have these env vars set globally (`.zshenv`). Spawning a shell while having them set is common. Therefore: never auto-block. Always escalate to UI prompt.

### Rule 8: Default

```
return .notAgent
```

---

## 5. Required test cases

These tests must all pass before classifier v1 is considered done. Total: 65 tests.

### Group A: Explicit allowlist / agent-list (4 tests)

1. User-trusted path → `.notAgent` even if name matches Claude Code
2. User-tagged path → `.agent(.userTagged, .high)`
3. Allowlist takes precedence over agent-list (allow wins)
4. Removing from agent-list reverts to default classification

### Group B: Known agent list, signed (17 tests)

5. Signed Claude Code at canonical path → `.agent(.knownList, .high)`
6. Signed Cursor → `.agent(.knownList, .high)`
7. Signed Codex CLI → `.agent(.knownList, .high)`
8. Signed Goose → `.agent(.knownList, .high)`
9. Signed Hermes → `.agent(.knownList, .high)`
10. Cline running inside signed VSCode (Code) → `.agent(.knownList, .high)` based on parent + extension marker
11. Continue running inside signed VSCode → `.agent(.knownList, .high)`
12. Aider (unsigned) at canonical path → `.agent(.knownList, .medium)`
13. ClawdBot (unsigned) user-tagged → `.agent(.userTagged, .high)`
14. OpenClaw (unsigned) user-tagged → `.agent(.userTagged, .high)`
15. Binary named `claude` but signed by unknown team → `.agent(.knownList, .medium)` (name match only)
16. Binary named `claude` with no signature → `.agent(.knownList, .medium)`
53. Process matched via LaunchAgent plist with known agent binary → `.agent(.serviceLaunch, .high)`
54. Process matched via LaunchDaemon plist (system-level) → `.agent(.serviceLaunch, .high)`
55. Process parented to launchd but plist not present (deleted after launch) → falls through to other rules
56. Process matching agents.yaml runtime-fingerprint entry (python-anthropic-sdk) → `.agent(.pythonRuntime, .medium)`
57. Process matching agents.yaml runtime-fingerprint entry (node-mcp-sdk) → `.agent(.nodeRuntime, .medium)`
58. Python process with `-m hermes_cli.main` → `.agent(.pythonRuntime, .high)`
59. Python process with `-m anthropic` → `.agent(.pythonRuntime, .high)`
60. Python process with `-m unrelated.thing` → `.notAgent`
61. Python process launched through `<venv>/bin/hermes` → `.agent(.pythonRuntime, .high)`
62. Node process with argv script under `/node_modules/openclaw/` → `.agent(.nodeRuntime, .high)`
63. Node process whose `package.json` depends on `@anthropic-ai/sdk` → `.agent(.nodeRuntime, .medium)`
64. Process executable or cwd under `~/.hermes` install path → `.agent(.knownList, .medium)`
65. LaunchAgent label/module match for `ai.hermes.gateway` / `hermes_cli.main` → `.agent(.serviceLaunch, .high)`

### Group C: Bypass resistance (10 tests)

17. Renamed Claude Code binary (`/usr/local/bin/foo`) but with valid Anthropic signature → still `.agent(.knownList, .high)` via signing identifier
18. Renamed unsigned Claude Code → `.notAgent` via path; but if user tags it, `.agent(.userTagged, .high)`
19. Symlink to Claude Code at `/tmp/x` → resolves to real path, classified correctly
20. Hardlink to Claude Code → realpath catches it, classified correctly
21. Process with stripped/replaced code signature → `.notAgent` on signing path; falls to other rules
22. Agent runs `exec /bin/cat` with `posix_spawn` → child `cat` inherits via parent chain rule, classified as agent
23. Agent runs `nohup setsid cat &` → still parented to agent, classified as agent
24. Agent runs `launchctl bootstrap` to spawn outside its tree → caught by env-var heuristic if API key env vars passed; otherwise `.notAgent` (acknowledged gap)
25. Agent forks a python interpreter that uses `os.execve` to drop env vars and spawn `cat` → caught by parent chain, classified as agent
26. Agent uses `dyld_insert_libraries` to inject into a notAgent process → injected process keeps original parent and identity, classified as `.notAgent`. **This is a known gap. Document, don't fix in v0.1.**

### Group D: Process tree (8 tests)

27. Direct child of Claude Code (zsh) → `.agent(.parentChain, .high)`
28. Grandchild of Claude Code (zsh → cat) → `.agent(.parentChain, .high)`
29. 8-deep descendant → still classified via chain
30. Process whose parent chain contains launchd only → `.notAgent`
31. Process whose parent died (orphaned, reparented to launchd) → use audit token to recover original parent if available; otherwise `.notAgent`
32. zsh launched directly from Terminal.app (parent: Terminal, then launchd) → `.notAgent`
33. zsh launched from Claude Code → `.agent`
34. Cursor's helper renderer process → `.agent` via bundle id match (Cursor bundles helpers)

### Group E: Runtime fingerprint — Python (5 tests)

35. `python3 myscript.py` where script imports `anthropic` → `.agent(.pythonRuntime, .medium)`
36. `python3 myscript.py` where script imports `openai` → `.agent(.pythonRuntime, .medium)`
37. `python3 myscript.py` with no AI SDK imports → `.notAgent`
38. `python3` interactive REPL with no imports yet → `.notAgent` (snapshot at start)
39. Jupyter kernel with `anthropic` imported in a notebook cell → `.agent(.pythonRuntime, .medium)`

### Group F: Runtime fingerprint — Node (4 tests)

40. `node script.js` in a project whose `package.json` lists `@anthropic-ai/sdk` → `.agent(.nodeRuntime, .medium)`
41. `node script.js` in a project whose `package.json` lists `openai` → `.agent(.nodeRuntime, .medium)`
42. `node script.js` in a project with no AI deps → `.notAgent`
43. Global `npx claude-code` → caught by Rule 3 (binary name) before Node fingerprint runs

### Group G: Env-var + shell-spawn heuristic (5 tests)

44. Process with `ANTHROPIC_API_KEY` set, has spawned no children → `.notAgent`
45. Process with `ANTHROPIC_API_KEY` set, spawned a shell 30s ago → `.suspicious(.envVarsPlusShellSpawn)`
46. Process with `OPENAI_API_KEY` set, spawned a shell 90s ago → `.notAgent` (outside 60s window)
47. Process with both `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`, no children → `.notAgent`
48. Shell directly invoked from Terminal with API keys in environment → `.notAgent` (parent chain shows Terminal, no agent ancestor; shell spawn requirement is about the process spawning a shell, not being a shell)

### Group H: False positive resistance (4 tests)

49. Spotlight indexer (`mds_stores`) → `.notAgent`
50. Time Machine backup (`backupd`) → `.notAgent`
51. Xcode build process → `.notAgent` (even though it spawns many shells)
52. Homebrew install (`brew`) → `.notAgent` (env vars OK, but no API keys)

---

## 6. Performance budget

The classifier runs synchronously in the hot path of every protected resource access. Budget:

- First classification of a new pid: < 5ms (involves syscalls to fetch identity)
- Cached re-classification: < 50µs (in-memory dict lookup)
- Cache invalidation: on `exec` event from ES, on TTL expiry (5 min)

If we exceed 5ms on first classification, the enforcement layers must time out and **fail open** (allow the access). Logging this as `CLASSIFIER_TIMEOUT` is mandatory. We never block based on partial classification.

---

## 7. Caching

```swift
struct ClassifierCache {
    var entries: [pid_t: CacheEntry]
    static let ttl: TimeInterval = 300
}

struct CacheEntry {
    let identity: ProcessIdentity
    let verdict: AgentVerdict
    let computedAt: Date
}
```

Invalidation triggers:
- `ES_EVENT_TYPE_NOTIFY_EXEC` for the pid → invalidate (process replaced its image)
- `ES_EVENT_TYPE_NOTIFY_EXIT` → remove
- TTL expiry (300s) → recompute on next access
- User changes agent-list or trust-list → invalidate everything

---

## 8. Update path for the known agent list

The list is bundled with the app, not fetched at runtime. Updates ship via app updates only. This is intentional:

- A remote-fetched list is a supply chain attack vector. An attacker who compromises the update server can drop entries to disable classification of their malicious agent.
- An attacker with local privileges who can modify the bundled list has already won; we're not defending that.
- Trade-off: new agents (e.g. some new LLM CLI gets popular) require a Sanctuary release to be auto-classified. Mitigation: users can `sanctuary agents add <path>` immediately.

Cadence: ship known-list updates with every minor release. Out-of-band hotfix release if a new high-volume agent emerges.

---

## 9. Open implementation questions

1. **Code signature retrieval cost**: `SecCodeCopySigningInformation` involves disk I/O. Confirm < 5ms budget holds on first access. If not, we need an async pre-warm path on `ES_EVENT_TYPE_NOTIFY_EXEC`.
2. **Python `sys.modules` inspection from outside the process**: `PROC_PIDREGIONPATHINFO` returns mapped libraries. This catches `.dylib` form but not pure-Python imports. For pure-Python detection we may need a fallback path: scan the script file referenced in `argv[1]` for `import anthropic`. Imperfect — script can be obfuscated. Acceptable for medium confidence.
3. **VSCode extension detection (Cline / Continue)**: VSCode runs each extension in a child Node process. Identifying which extension is in which child requires either parsing VSCode's IPC channel or matching on the `--extensionDevelopmentPath` argv. Confirm one approach during implementation.
4. **Audit token vs pid**: pids can be reused. ES gives us audit tokens which are unique. The cache should key on audit token, not pid. Update spec when wiring ES.

---

## 10. Definition of done

Classifier v1 is done when:

- [ ] All 65 tests in §5 pass via `swift test`
- [ ] Performance budget in §6 met on a 2024 M3 MacBook Pro
- [ ] No env var **values** are read by any code path (audited)
- [ ] No network calls are made by the classifier (audited)
- [ ] Cache invalidation paths in §7 are wired
- [ ] Known agent list in §4 Rule 3 has at least the v0.1 entries
- [ ] `sanctuary agents list/add/remove` and `sanctuary trust add/remove` CLI commands work end-to-end

---

## 11. Implementation wisdom

### 11.1 — Matcher narrowing

When a rule matches via a generic host (`python`, `node`, `bash`, `electron`),
require a strong secondary signal before classifying. A bare match on "process
is python and parented to launchd" is too broad — every macOS install has
Python LaunchAgents for unrelated work. Require either a registry-level
`executable_names` match, an argv module pattern match, an `install_paths`
prefix match, or a launchd plist `Label` registry match before returning
`.agent`.

Production dogfood caught this twice: a broad launchd walk classified unrelated
launchd children as `.agent(.serviceLaunch)`, and generic `node` entries could
make a real Hermes/OpenClaw service display as a foreground editor extension.
Keep the matcher narrow so future contributors do not re-broaden it.

### 11.2 — Current-process exclusion

Any subsystem that uses fd-set or proc-listing attribution must exclude its own
process and its known helper processes. The Sanctuary daemon opens fds against
protected resources by definition. Without exclusion, attribution falsely
targets the daemon and the audit log becomes unusable.

Use `CurrentProcessExclusion` as the shared primitive. Do not open-code
`getpid()` checks in individual enforcement layers unless the shared helper
cannot express the case.

### 11.3 — Verification before scope expansion

Architecture decisions (NEFilter vs `proc_pidfdinfo`, pf vs Network Extension,
`/etc/pf.conf` modification vs Apple anchor namespace) must be spike-tested on
real hardware before architecture commits. Three of the four major architecture
decisions in v0.1 were validated by spikes; the one that was not, the initial
`pf.conf` approach, cost three commits to fix.

Future architectural commits follow the spike-first pattern.

### 11.4 — Path defaults must agree across components

When daemon, CLI, and UI components resolve defaults for shared state such as
the policy DB path, audit log path, or inventory snapshot path, they MUST use a
single shared resolver. Independent default-resolution code is a correctness bug
waiting to happen: tests usually set explicit paths, so the mismatch stays
invisible, then production breaks when no env vars are set.

The canonical resolver is `SanctuaryPaths`. New components must call it instead
of inventing local fallbacks.
