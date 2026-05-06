# HUMAN_APPROVAL_SPEC

**Status**: v0.2 architecture spec  
**Owner**: SanctuaryDaemon, SanctuaryMenuBar  
**Related specs**: `CLASSIFIER_SPEC.md`, `CAPABILITY_SCOPING_SPEC.md`, `INVISIBILITY_SPEC.md`, `TAMPER_RESISTANCE_SPEC.md`, `THREAT_MODEL.md`, `COVERAGE_GAPS.md`

---

## 1. Goal

Sanctuary v0.2 needs human-in-the-loop approval for sensitive agent access. The classifier can identify agents. Endpoint Security can pause and authorize filesystem operations. The missing piece is a user decision model that is precise, hard to spoof, auditable, and backed by local owner presence.

The approval flow asks the user before a classified agent gets access to a sensitive resource when no existing policy rule applies. It must answer three questions:

- Which agent is asking?
- What does it want to do?
- Is this access safe in this context?

The design uses hardware-backed authentication for critical and high-risk approvals. On Macs with Touch ID, that means LocalAuthentication and Secure Enclave-backed owner presence. On Macs without Touch ID, the fallback is `deviceOwnerAuthentication`, which may use the user's password through Apple's trusted system prompt.

## 2. Trigger Conditions

The approval flow activates only when all of the following are true:

1. A process is classified as an agent by `CLASSIFIER_SPEC.md`.
2. The process attempts to access a protected resource.
3. No trusted-path rule applies.
4. No user-tagged exception or workspace-scoped exception applies.
5. The resource policy allows prompting rather than automatic denial.
6. The daemon can present a trusted approval request through the menu bar app or a system-owned authentication prompt.

Protected resources include:

- SSH private keys and identities.
- GPG private keys.
- Cloud credentials under `~/.aws`, `~/.azure`, `~/.gcloud`, and related paths.
- Wallet extension storage.
- Password manager extension storage.
- Standalone wallet and password manager app data directories.
- Browser CDP attachment to protected profiles where a future policy allows prompts.

v0.2 should not prompt for every low-value event. Directory enumeration under a protected parent may be handled by invisibility. The approval dialog is reserved for decisions where the user can make a meaningful, narrow grant.

## 3. Approval Dialog UX

The dialog title is concrete:

```text
[Agent name] wants to [action] [resource]
```

Examples:

- "Cursor wants to read `~/.ssh/deploy_key`"
- "Claude Code wants to read MetaMask storage"
- "OpenClaw wants to enumerate `~/.aws`"

The dialog includes a risk indicator:

- **Critical**: wallet private key material, password manager state, seed phrase storage, SSH private keys, GPG private keys.
- **High**: cloud credentials, browser cookies, active wallet browser sessions, deploy keys.
- **Medium**: protected config directories, extension metadata, sensitive project secrets.
- **Low**: protected test fixtures or user-marked low-risk paths.

Risk is derived from the protected resource type, not from model confidence alone. A probable agent touching a wallet is still high risk.

The process chain display shows:

- Agent friendly name.
- Executable path, tilde-collapsed where possible.
- Parent chain summary.
- Code signing status when known.
- Workspace directory if known.

The options are:

- **Allow once**
- **Allow 10 minutes**
- **Allow this session**
- **Allow for this workspace**
- **Deny**
- **Never allow**

"Never allow" creates a negative rule for the same process/resource scope. It should not become a global deny for every agent unless the user explicitly chooses a global scope in advanced settings.

Touch ID is required for Critical and High approvals. Medium approvals may require Touch ID depending on user settings. Low approvals can use a normal confirmation. The default must be conservative.

The dialog times out. If the user does not respond within the daemon's Endpoint Security budget, the operation is denied or made invisible, and the audit log records `APPROVAL_TIMEOUT`.

## 4. macOS Implementation

The menu bar app owns UI presentation. The daemon owns policy and enforcement. Approval requests originate from the daemon and are delivered to the menu bar app over a trusted local channel.

Local owner authentication uses the LocalAuthentication framework:

- `LAContext`
- `canEvaluatePolicy`
- `evaluatePolicy`
- `.deviceOwnerAuthenticationWithBiometrics` for Touch ID-first approval
- `.deviceOwnerAuthentication` for fallback when biometrics are unavailable

The reason string must name the action:

```text
Confirm to allow Cursor to read ~/.ssh/deploy_key for ~/Projects/myapp.
```

Vague prompts like "Authenticate to continue" are not acceptable. The prompt must help the user understand the consequence.

Endpoint Security authorization events have strict response deadlines. The daemon must avoid blocking indefinitely while waiting for UI. The implementation should:

- Pause only operations that can be safely delayed.
- Use a bounded approval timeout.
- Fail closed for Critical and High resources.
- Prefer invisibility over noisy denial when the platform permits it.

## 5. Decision Persistence

Each approval creates either an in-memory decision or a policy row.

Decision forms:

- **Allow once**: in-memory decision keyed by event identity.
- **Allow 10 minutes**: policy row with `expires_at`.
- **Allow this session**: policy row keyed to the agent instance UUID or process start time.
- **Allow for this workspace**: `workspace_scoped_exceptions` row from `CAPABILITY_SCOPING_SPEC.md`.
- **Never allow**: negative policy row with explicit scope.

Every persisted decision records:

- Process identity.
- Resource path or protected resource identifier.
- Action.
- Workspace directory if applicable.
- Expiration.
- Creation timestamp.
- User-visible source.
- Authentication strength used.

The policy DB must never store file contents, environment variable values, seed material, or secret snippets.

## 6. Tamper Resistance

Approval dialogs must not be spoofable by agents. Agents should not be able to create their own windows that look like Sanctuary approvals and trick the user into granting access.

Design rules:

- Approval requests come from `sanctuaryd`, not from the requesting process.
- The menu bar app verifies the daemon peer before showing security UI.
- The daemon verifies menu bar commands before accepting decisions.
- The dialog includes Sanctuary's signed app identity and consistent native UI.
- Critical decisions require LocalAuthentication, which agents cannot fake inside their own UI.

`TAMPER_RESISTANCE_SPEC.md` covers peer monitoring, code signature verification, audit hash chains, and policy DB integrity. Human approval depends on those controls. If peer verification fails, the menu bar must refuse to present an approval dialog.

## 7. Privacy

Approval events are written to the audit log with the existing privacy posture.

Allowed audit fields:

- Agent friendly name.
- Process path, normalized and tilde-collapsed where appropriate.
- Protected resource category.
- Protected resource display name.
- Action.
- Decision.
- Scope and expiration.
- Authentication strength.

Forbidden audit fields:

- Environment variable values.
- File contents.
- Secret fragments.
- Browser cookie values.
- Wallet addresses extracted from storage.
- Password manager item names unless the user explicitly labels the protected resource.

The approval flow must not inspect file contents to make a decision. Classification and policy are based on process identity, resource path, and user-configured metadata.

## 8. Integration With Capability Scoping

The approval dialog is the primary user-facing entry point for capability scoping.

If an agent needs access to a sensitive resource for legitimate work, the user should not have to leave the interruption flow, open settings, and reconstruct context. The dialog already knows the agent, resource, action, and likely workspace. It can offer:

```text
Allow for this workspace
```

Choosing that option writes a workspace-scoped exception. The dialog must show the exact workspace path before saving. If the workspace is unknown, the option is disabled or asks the user to choose a workspace directory.

The UI should make narrow grants easier than broad grants. Global grants belong in advanced settings, not the default approval path.

## 9. Failure Modes

### 9.1. Approval timeout

If the user does not answer in time, the daemon denies or hides the resource and records `APPROVAL_TIMEOUT`. The user can retry the agent action after creating an exception.

### 9.2. Daemon unavailable

If the menu bar app cannot reach the daemon, it must not present approval UI. The dropdown should show daemon-disconnected state from peer monitoring. No policy mutation should occur.

### 9.3. Biometrics fail

If Touch ID fails, the action is denied. If `deviceOwnerAuthentication` fallback is allowed by policy, the system password prompt may be offered. Critical actions should default to requiring successful owner authentication, not a soft UI confirmation.

### 9.4. User cancels

Cancel is Deny. It writes an audit entry but no allow rule.

### 9.5. Unknown workspace

Workspace-scoped options are disabled unless the workspace is known or selected. The user can still allow once.

### 9.6. Repeated prompts

Repeated prompts for the same denied action can become alert fatigue. The daemon should rate-limit identical prompts and offer "Never allow" after repeated denials.

### 9.7. Policy DB write failure

If the daemon cannot persist an allow decision, it may allow once only if the user selected a one-time grant. It must not pretend a persistent exception was saved.

## 10. Implementation Phases

### v0.2: Touch ID and standard scopes

- Add approval request protocol between daemon and menu bar app.
- Add native approval dialog.
- Use LocalAuthentication for Critical and High approvals.
- Implement Allow once, Allow 10 minutes, Allow this session, Deny, and Never allow.
- Integrate `workspace_scoped_exceptions` for "Allow for this workspace".
- Add audit events for request, decision, timeout, and policy creation.
- Add e2e scenarios for approval, denial, timeout, and biometric failure where automation permits.

### v0.3: Sealed-secret state release

- Tie always-protected intent to Secure Enclave-backed state per `TAMPER_RESISTANCE_SPEC.md` §4.6.
- Require owner presence to disable critical protections.
- Add power-user policy review and stale-rule cleanup.
- Add optional hardware-key support for machines without Touch ID.

## 11. Decision Log

**Why human approval exists:** Not every agent access to a protected resource is malicious. Some deployments need keys. Some test suites need fixtures. The user needs a safe way to grant narrow access.

**Why Touch ID for Critical and High:** Removing or bypassing protection for secrets is security-relevant. A plain button click is too easy for malware to socially engineer or UI-spoof.

**Why daemon-originated requests:** The requesting process is untrusted. It cannot be allowed to define the prompt or claim its own identity.

**Why fail closed:** If Sanctuary cannot get a timely trusted answer, the safe decision for secrets is no.

**Why approval is v0.2:** v0.1 does not have synchronous filesystem authorization. The approval flow becomes materially useful once Endpoint Security can pause and enforce decisions.
