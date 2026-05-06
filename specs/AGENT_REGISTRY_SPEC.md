# AGENT_REGISTRY_SPEC

**Component**: `agents.yaml`
**Status**: v0.1 registry contract
**Owner**: SanctuaryCore
**Bundling**: compile-time only

---

## 1. Purpose

Sanctuary's first trust claim is coverage.

The modal user does not ask only, "Does this stop Claude Code?"
They ask, "Can I run whatever agent stack is fashionable this month
without accidentally giving it my wallet, keys, browser profile, and
clipboard?"

`agents.yaml` is the public, versioned, PR-able registry of agent
identities Sanctuary understands.

Coverage breadth is not trivia. It is the marketing wedge:

- Foreground coding agents are the demo-visible class.
- Background services are the day-to-day risk class.
- Browser agents directly exercise the CDP and extension-storage attack
  surfaces.
- MCP servers inherit an agent's blast radius and must be inventoried.
- Runtime fingerprints catch the long tail of custom Python and Node loops.

The registry makes this visible. A user can inspect the repo, search for the
agent they use, and know whether Sanctuary will classify it before installing
the product. New agents are added deliberately, reviewed publicly, and shipped
in signed releases.

---

## 2. Schema

The registry is YAML at the repository root:

```text
agents.yaml
```

Top-level schema:

```yaml
version: 1
updated: YYYY-MM-DD
entries:
  - id: string
    friendly_name: string
    category: foreground-coding | background-service | browser-agent | mcp-server | runtime-fingerprint
    executable_names: [string]
    bundle_identifiers: [string]
    team_identifiers: [string | null]
    code_signing_identifiers: [string]
    install_paths: [string]
    runtime_fingerprint:
      python_modules: [string]
      node_packages: [string]
    launchd_plist_patterns: [string]
    confidence_when_signed: high | medium | low
    confidence_when_unsigned: high | medium | low
    reference_url: string
    notes: string
```

Field rules:

- `version` is the schema version, not the application version.
- `updated` is the date of the latest intentional registry change.
- `entries` is sorted by category, then by product importance.
- `id` is stable, lowercase, kebab-case, and never reused for a different
  product.
- `friendly_name` is user-facing and may change for branding corrections.
- `category` controls classifier behavior and menu bar grouping.
- `executable_names` are basename matches only, never shell globs.
- `bundle_identifiers` are exact macOS bundle identifiers.
- `team_identifiers` are Apple Team IDs when verified; use `null` when unknown.
- `code_signing_identifiers` are exact signing identifiers when verified.
- `install_paths` are common absolute locations, used for hints and tests.
- `runtime_fingerprint.python_modules` contains import/module names.
- `runtime_fingerprint.node_packages` contains package names from dependency
  manifests or module resolution.
- `launchd_plist_patterns` contains glob-like filename hints for indexing plist
  labels and program paths; they are not sufficient alone for auto-block.
- `confidence_when_signed` is normally `high`.
- `confidence_when_unsigned` is normally `medium` for executable matches and
  runtime fingerprints.
- `reference_url` points to first-party docs or a source repository when known.
- `notes` records classification caveats in plain language.

Validation rules: unknown Team IDs are `null`, not guessed; empty lists are
preferred over omitted fields; runtime-fingerprint entries have empty
`executable_names`; URLs may be empty if no stable canonical reference is
known; the parser rejects unknown top-level fields.

---

## 3. Compile-time Loading

`agents.yaml` is loaded at build time and embedded into the signed binary.

There is no runtime fetch, update check, CDN pull, or remote registry merge.

Intended build flow:

1. A Swift Package plugin or build phase reads `agents.yaml`.
2. The loader validates the schema and fails the build on malformed entries.
3. The loader normalizes entries into a generated Swift file or packaged
   resource.
4. The classifier uses the embedded copy at runtime.
5. The menu bar and CLI expose the embedded registry version and update date.

Implementation constraints:

- Build-time validation must not call the network.
- The generated artifact must be deterministic.
- The generated artifact must be covered by `.gitignore` unless checked in
  deliberately.
- Tests should be able to load the source YAML and compare it to the embedded
  registry.

Runtime behavior:

- `sanctuary agents list` displays the bundled registry.
- `sanctuary agents add <path>` remains a local user override.
- User overrides do not modify `agents.yaml`.
- User overrides are stored in the policy database and clearly marked as local.

---

## 4. Update Cadence

Registry updates ship with application releases.

Normal cadence:

- Minor releases include accumulated registry additions.
- Patch releases may include registry-only corrections if risk warrants it.
- Out-of-band hotfix releases are allowed for high-volume new agents.

High-volume means:

- The agent is widely used by Sanctuary's target user base.
- The agent has an active local process with filesystem/browser/clipboard reach.
- Missing coverage would materially weaken the product promise.

Release notes include added entries, removed entries, confidence changes, Team
ID or signing ID changes, and false-positive fixes. Removing an entry is rare;
prefer lowering confidence or adding caveats unless the previous entry was
factually wrong.

---

## 5. Community PR Process

The registry is public and PR-able.

Required issue or PR fields:

- Agent name.
- Agent category.
- Official URL or repository.
- Installation method.
- Executable names.
- Common install paths.
- Bundle identifier, if macOS app.
- Team ID, if submitter can verify it.
- Code signing identifier, if submitter can verify it.
- Whether it can run as a LaunchAgent or LaunchDaemon.
- Whether it starts MCP servers.
- Whether it drives browsers or CDP.
- Evidence: command output, screenshots, docs links, or source references.

Review SLA:

- Maintainers acknowledge within 5 business days.
- Security-sensitive entries may take longer, but the delay must be explained.

Maintainer review checklist:

- Confirm product exists and is agent-like.
- Confirm category is correct.
- Verify executable names.
- Verify bundle/signing fields if present.
- Leave unknown signing fields as `null` instead of guessing.
- Add notes for ambiguous extension-host cases.
- Add or update tests if the entry exercises new classifier behavior.

Maintainer signing:

- A maintainer signs off on registry changes in the PR.
- The release tag signs the bundled registry.
- Attribution credit is included in the changelog unless the contributor opts
  out.

Spam entries are closed. Malicious attempts to remove coverage are treated as
security reports. Disputed entries remain conservative until verified.

---

## 6. Verification

Users must be able to verify that their installed Sanctuary coverage matches
the public registry.

CLI requirements:

```sh
sanctuary agents registry-version
sanctuary agents list --bundled
sanctuary agents verify --against ./agents.yaml
```

Expected output includes schema version, registry updated date, Sanctuary app
version, build commit if available, count by category, and hash of the bundled
normalized registry.

Verification hash:

- Normalize YAML by sorting object keys and preserving entry order.
- Exclude comments.
- Include all security-relevant fields.
- Hash with SHA-256.

The GitHub release page should publish the normalized registry hash. The CLI
should show the same hash for the installed binary.

---

## 7. Threat Model

No auto-fetch. Ever, unless a future major version introduces a signed,
auditable update protocol and a clear rollback story.

Why: a registry is a security boundary. A compromised update server could remove
an attacker-controlled agent, lower confidence for a dangerous runtime, or add
broad false-positive entries and make Sanctuary unusable.

Bundled-only behavior matches `CLASSIFIER_SPEC.md` §8:

- new coverage requires a release
- local user overrides cover urgent cases
- release signing protects the artifact
- users can inspect exactly what they run

Local policy can add agents faster than releases, but local policy is explicitly
owned by the user and never presented as upstream coverage.

---

## 8. Migration

Schema migrations must be boring.

Rules:

- Increment `version` for breaking schema changes.
- Additive fields do not require a new version if old binaries ignore them.
- Removing or renaming a field requires a new version.
- Older binaries must fail closed on unsupported schema versions during build.
- Runtime binaries only use their embedded registry, so migration primarily
  affects source builds and CI.

Forward-compatible additions include new categories, runtime fingerprint
families, platform-specific fields, confidence explanations, and protocol
fingerprints.

Migration plan for a new field:

1. Add field as optional in the build-time parser.
2. Populate it for a small number of entries.
3. Ship a release that understands both old and new forms.
4. Make it required only in a later schema version.

Historical registries stay in git. Do not rewrite old registry commits to hide
mistakes; fix forward and document why.
