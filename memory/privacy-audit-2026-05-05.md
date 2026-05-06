# Privacy Audit — 2026-05-05

Command run:

```sh
rg -i "envvar|env\s*=\s*|env_var|environment" Sources/
```

Matches reviewed:

- `Sources/SanctuaryCore/AgentClassifier.swift`
  - `ProcessIdentity.environmentVars` stores a `Set<String>` of environment variable names.
  - `environmentKeys` is a backward-compatible alias for tests/fixtures and is unioned into the same names-only set.
  - `agentApiKeyEnvironment` is a static set of sensitive variable names such as `OPENAI_API_KEY`.
  - `hasAgentAPIKey` checks set intersection against names only.
  - Finding: no values are read, stored, logged, or transmitted.

- `Sources/SanctuaryCore/ProcessIdentityCollector.swift`
  - Assigns `environmentVars: procArgs?.environmentVarNames ?? []`.
  - Finding: collector only receives names from `ProcArgsParser`; no value-bearing API is exposed from the collector.

- `Sources/SanctuaryCore/Darwin/ProcArgsParser.swift`
  - Documents that `KERN_PROCARGS2` buffers contain environment strings and values must not leave the parser.
  - `ProcArgs.environmentVarNames` exposes names only.
  - `readEnvironmentName(_:)` scans bytes until the first `=` and materializes only the left side.
  - The parser does not build an intermediate `[String]` containing full environment entries.
  - Unit test `privacyAuditNamesNeverContainEqualsOrValues` covers API-key-like values, including values with additional `=` characters.
  - Finding: values are present only in the kernel-provided buffer needed for `KERN_PROCARGS2`; the parser does not return, log, persist, or store them in Swift strings.

- `Sources/SanctuaryCore/ExtensionStorage/ProtectedExtensionRegistry.swift`
  - Uses `ProcessInfo.processInfo.environment["SANCTUARY_DB_PATH"]` as a test/development database-path override.
  - Finding: unrelated to process identity collection; reads one Sanctuary-specific configuration value for local test isolation.

Conclusion:

- Process identity collection honors the privacy boundary: environment variable names are used for classification; values are not exposed by any public type or stored in `ProcessIdentity`.
- Follow-up: when audit logging moves from `/tmp` JSONL to signed persistent logs, keep `ProcessIdentity.environmentVars` out of audit payloads unless explicitly redacted to names only.
