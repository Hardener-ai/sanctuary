# Contributing to Sanctuary

## Welcome

Sanctuary by Hardener is open source in the Hardener-ai GitHub organization.
Contributions are welcome, especially work that closes clearly documented
coverage gaps without weakening privacy or user trust.

## Branding

Contributions to this repository are licensed under AGPL v3. The
"Sanctuary" and "Hardener" names and branding are trademarks of Hardener and
not granted to forks. See `TRADEMARKS.md`.

## Before contributing

- Read `specs/THREAT_MODEL.md`, `specs/COVERAGE_GAPS.md`, and the relevant component spec for the area you want to work on.
- For coverage gaps, reference the gap number from `specs/COVERAGE_GAPS.md`.
- For new features, open a GitHub issue first to discuss the approach.

## Development setup

- macOS 13+ is required for SMAppService, FSEvents, and menu bar app support.
- Install Xcode command line tools.
- Use Swift 5.9 or newer.
- Optional: Apple Developer ID certificate for production install-flow testing.

## Build and test

```sh
swift test
```

Runs the unit test suite.

```sh
./e2e/run-all.sh
```

Runs end-to-end attack scenarios.

```sh
E2E_PF=1 ./e2e/run-all.sh
```

Enables the pf-gated CDP scenarios. This requires sudo configured per the repo's scoped sudoers entry.

```sh
./Sources/SanctuaryMenuBar/scripts/bundle.sh
```

Produces a local `.app` bundle at `dist/SanctuaryMenuBar.app`.

## PR guidelines

- One concern per PR.
- Update or add the relevant spec when changing behavior.
- Add tests for the smallest meaningful slice.
- Reference `specs/COVERAGE_GAPS.md` gap numbers when applicable.
- Privacy: do not introduce code that captures secret values, inspects file contents, or phones home.

## Code review standards

- Process identity collection must never read environment variable values.
- Audit logging must never include file contents or secret values.
- Be careful with paths under protected resources. Prefer tilde-collapsed or policy-level descriptions in UI surfaces.
- Anything touching Endpoint Security, Network Extension, TCC, Keychain, or Secure Enclave gets strict review.

## Reporting security issues

Do not file public GitHub issues for vulnerabilities.

Email: hello@hardener.ai

See `SECURITY.md` for the full policy.
