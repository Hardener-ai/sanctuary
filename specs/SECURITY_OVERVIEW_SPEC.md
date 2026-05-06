# SECURITY_OVERVIEW_SPEC

**Status**: v0.2 architecture spec  
**Owner**: SanctuaryMenuBar  
**Related specs**: `CLASSIFIER_SPEC.md`, `FSEVENTS_DETECTION_SPEC.md`, `EXTENSION_STORAGE_SPEC.md`, `CAPABILITY_SCOPING_SPEC.md`, `HUMAN_APPROVAL_SPEC.md`, `COVERAGE_GAPS.md`, `THREAT_MODEL.md`

---

## 1. Goal

Sanctuary v0.1 onboarding shows a one-time scan of detected sensitive resources. After onboarding, the menu bar shows protection state and recent activity, but it does not show the full picture of what exists on the machine and what is protected.

v0.2 adds a Security Overview view: a persistent dashboard that answers one user question:

```text
What sensitive things exist on my Mac, and are they protected?
```

The user should be able to glance at this view and understand their attack surface and Sanctuary's coverage without reading audit logs or scanning settings. The overview is not a compliance dashboard, a scorecard, or an antivirus console. It is a calm map of sensitive local resources, their protection state, and any coverage gaps Sanctuary knows about.

The primary audience is a crypto-native developer running AI coding agents on a Mac that also contains wallets, SSH keys, cloud credentials, browser profiles, and password manager state. The secondary audience is the security-aware friend, family member, or colleague helping that user set up the machine.

## 2. Background

A local security tool's value depends on the user trusting that what should be protected actually is protected. v0.1's onboarding flow handles initial coverage setup. The menu bar then shows current protection state and recent activity. That is enough to launch, but it is not enough for long-term user confidence.

Real users accumulate sensitive resources over time:

- New wallet extensions installed after onboarding.
- New cloud credentials added during work.
- Existing protections that may have been disabled.
- Resources in non-default paths the discovery engine missed.
- Resources the user dismissed during onboarding but should reconsider.
- Browser profiles created after the first setup flow.
- Project-specific deploy keys and service-account files.

Without a persistent overview, users cannot easily see what is covered, what was dismissed, what was added since onboarding, or where Sanctuary has blind spots. They also cannot hand the same view to another person during setup help and say, "Does this look right?"

The Security Overview UI fills that gap. It turns discovery and policy state into an understandable model of the user's local attack surface.

## 3. Information Architecture

The view is organized by resource category, not by file path. The goal is comprehension, not file management.

Categories shown:

- SSH identities and deploy keys.
- Cloud provider credentials: AWS, GCP, Azure, and related CLIs.
- GPG keys.
- Browser wallet extensions.
- Browser password manager extensions.
- Standalone wallet apps.
- Standalone password manager apps.
- Browser profile sessions protected by CDP Guard.
- Custom user-added resources.
- Shell history and terminal state, lower priority.

Each category row shows:

- How many resources of that type exist on the machine.
- How many are protected.
- How many are dismissed.
- How many are not covered.
- Risk level: Critical, High, Medium, or Low.
- Most recent activity timestamp, if known.
- Quick action: "Protect now" or "Review".

The default collapsed row uses plain text:

```text
Wallet extensions
3 detected, 2 protected, 1 needs review
High
```

Expanded detail shows resource rows. A row may be:

- `Protected`: covered by the active policy database.
- `Needs review`: discovered but not protected.
- `Dismissed`: explicitly ignored by the user.
- `Unsupported`: known sensitive category but not covered by current release.
- `Missing`: still in policy, but the path no longer exists.
- `Inactive`: protected but not recently seen in the audit log.

The view should prefer grouping and counts over raw paths. Paths appear only after the user expands a category.

## 4. Visual Treatment

The overview should not be alarming. Sanctuary is not antivirus. It is a precise containment and visibility product. The visual language is calm, factual, and clear.

Color coding:

- Green: protected.
- Yellow: not yet protected, recommended.
- Gray: dismissed by user, can be reconsidered.
- Red: active `TAMPER_DETECTED` states only.

Avoid:

- Score gamification such as "Your security is 73%."
- Shame-based phrasing such as "You are exposed."
- Marketing fluff.
- Hidden complexity.
- Red as a general warning color for normal setup gaps.

Prefer:

- Plain phrasing: "3 wallet extensions detected, 2 protected."
- Direct actions.
- Honest gaps: "This category is not yet supported in v0.2."
- Optional detail expansion.
- Small native controls that match the menu bar app's existing visual language.

The Security Overview should feel like a native macOS security sheet, not a SaaS dashboard. It can be a menu bar secondary panel, a compact window, or a settings-style pane. The final form should be chosen after v0.1 users interact with the onboarding flow.

## 5. Data Sources

The view consumes data already available to v0.1 and v0.2:

- `ResourceRegistry`: protected resources known to the daemon.
- `DiscoveredResources`: results of the last discovery scan.
- `KnownExtensions`: registry of wallet and password manager extensions.
- `DismissedResources`: resources the user explicitly dismissed.
- `AuditLog`: recent activity per category.
- `PolicyDB`: protected folders, protected extensions, user-tagged agents, trusted paths, and future exception rules.

The view must not trigger new disk scans on every render. Discovery runs on a schedule:

- Initial onboarding.
- Weekly background scan.
- On-demand "Re-scan" action.
- Targeted scan after browser profile or extension-install signals.

The Security Overview reads cached discovery results. If data is stale, the UI says so. It does not block the view while scanning.

The cache should include:

- Discovery timestamp.
- Discovery version.
- Category identifier.
- Tilde-collapsed display path.
- Full path, stored locally and shown only when requested.
- Protection state.
- Dismissal reason, if any.
- Last activity timestamp, if any.

## 6. Privacy Posture

The overview follows Sanctuary's existing privacy invariants:

- No environment variable values.
- No file contents.
- No secret material.
- Tilde-collapsed paths in display.
- Optional "show full path" toggle for power users.
- No telemetry by default.
- No cloud account required.

The overview is local-only. It is not exported by default. A future "Export setup summary" feature may share an anonymized summary with security advisors, but only on explicit user action.

An exported summary must avoid:

- Full paths by default.
- Wallet extension storage paths.
- Browser profile directory names if they contain user identifiers.
- Audit log entries containing process paths unless the user opts in.

Safe export examples:

```text
Wallet extensions: 3 detected, 3 protected.
SSH identities: 2 detected, 2 protected.
Cloud credentials: AWS detected and protected; GCP not detected.
Unsupported categories: Clipboard, screen capture, Accessibility.
```

## 7. Interaction Patterns

The user can:

- Click a category to see resources in it.
- Click an unprotected resource to protect it through the existing add-resource flow.
- Click a dismissed resource to re-evaluate it.
- Trigger a re-scan.
- View "what is missing" from `COVERAGE_GAPS.md`.
- Filter by risk level.
- Filter by "needs attention".
- Open recent audit activity for a category.
- See workspace-scoped exceptions relevant to the category.

The user cannot from this view:

- Disable protection.
- See secret material.
- Trigger destructive actions.
- Edit low-level policy rows directly.
- Create broad trust rules without going through the approval or settings flow.

Disabling protection is intentionally excluded. That action is security-relevant and belongs in settings with stronger friction and owner authentication. The overview answers "what is covered?" not "how do I turn this off?"

## 8. Integration With Onboarding

v0.2 onboarding flows back into Security Overview.

After initial setup, the user lands on the overview instead of a generic status screen. This teaches the user what categories exist and shows the result of the choices they just made.

The overview also handles post-onboarding discovery:

```text
2 new resources discovered since setup.
Review now?
```

Examples:

- MetaMask installed after onboarding.
- A new `~/.aws` credentials file appears.
- A new Chrome profile with a wallet extension is created.
- A custom folder previously missing now exists.

The overview should preserve dismissed state. If a user dismissed a resource during onboarding, it appears under "Dismissed" rather than returning as a new urgent item every scan.

## 9. Integration With Capability Scoping and Human Approval

`CAPABILITY_SCOPING_SPEC.md` defines workspace-scoped exceptions. When the user grants one, the Security Overview shows it explicitly. The user should never have to dig through hidden settings to find their granted exceptions.

Example:

```text
SSH identities
2 protected
1 workspace exception

Cursor may read ~/.ssh/deploy_key only while working in ~/Projects/myapp.
Expires: this session
```

`HUMAN_APPROVAL_SPEC.md` defines approval prompts. When a user approves an access request, the resulting policy rule appears in the relevant category:

- Allow once: shown in recent activity only.
- Allow 10 minutes: shown as temporary access.
- Allow this session: shown as session access.
- Allow for this workspace: shown as a workspace-scoped exception.
- Never allow: shown as a denial rule.

This makes human decisions auditable and reversible. It also prevents a common UX failure: users approve something under pressure and later cannot find what they approved.

## 10. Failure Modes

### 10.1. Daemon unavailable

The overview shows cached state with a clear "Daemon disconnected" banner. It does not pretend everything is fine.

Cached state must be visually distinct from live state. The banner should include the last successful daemon contact timestamp and a link to troubleshooting.

### 10.2. Discovery scan failed

The view shows the last successful scan timestamp. The user can trigger a manual re-scan.

Failure text should be specific:

```text
Last scan failed. Protected resources are still protected, but discovery may be stale.
```

### 10.3. Resource appears in registry but path no longer exists

The row is shown as "Path missing" rather than silently hidden. The user can choose to remove the stale protection or locate the moved resource.

Silent hiding would create false confidence. A missing path may mean the user moved a wallet, deleted a profile, or mounted a drive differently.

### 10.4. Resource has not been seen in audit log for 30+ days

The row is shown as "Inactive" but remains protected. Sanctuary must not auto-disable protection based on inactivity.

Inactivity is information, not a policy decision.

### 10.5. Unsupported category detected

If a category is known sensitive but not supported, show it under "Not covered yet" and link to `COVERAGE_GAPS.md`.

Example:

```text
Clipboard access
Not covered in v0.2
See Coverage Gap 3
```

This is uncomfortable, but it is the correct trust posture.

## 11. Implementation Phases

### v0.2 baseline

- Category groupings.
- Protected, unprotected, dismissed, unsupported, and missing counts.
- Risk-level color coding.
- Click-through to existing add-resource and audit views.
- "What is missing" section pulled from `COVERAGE_GAPS.md`.
- Re-scan action.
- Cached discovery results.
- Last successful scan timestamp.

### v0.3 additions

- Anonymized export of setup summary.
- Trend view showing resources added over time.
- Per-resource last-access timestamp.
- Suggested protections from new wallet extension installs.
- Comparison view: "this Mac vs recommended baseline."
- Better integration with browser profile lifecycle events.

### v1.0 additions

- Cross-platform category model shared with Windows and Linux.
- Organization policy overlays for teams.
- Advisor-friendly setup reports.

## 12. Why v0.2, Not v0.1

The overview depends on richer data than v0.1 collects:

- Workspace-scoped exception data from `CAPABILITY_SCOPING_SPEC.md`.
- Approval rule history from `HUMAN_APPROVAL_SPEC.md`.
- Stable per-resource activity attribution improved by Endpoint Security.
- Mature discovery-cache schema.
- Real feedback from v0.1 onboarding.

It is also a substantial SwiftUI surface. Building it in v0.1 would block launch on UI work that should follow validated user behavior.

v0.1 onboarding handles initial setup. The menu bar handles day-to-day status and activity. The Security Overview becomes valuable after the user has been running Sanctuary long enough for resources, exceptions, dismissals, and new installs to accumulate.

## 13. Decision Log

**Why category-first, not path-first:** Users think in categories: wallets, SSH keys, cloud credentials. A path-first view turns the overview into a file manager.

**Why no security score:** Single-number scores create perverse incentives and false confidence. Sanctuary's value is precise, not gamified.

**Why honest about gaps:** `COVERAGE_GAPS.md` exists for a reason. Hiding gaps in a "looks fine" UI undermines the threat-model honesty that is core to Sanctuary's trust posture.

**Why no disable controls:** The overview is for understanding coverage. Turning protection off is a high-stakes action that belongs in settings with explicit confirmation and owner authentication.

**Why deferred to v0.2:** v0.1 onboarding handles initial setup. The overview is most valuable after the user has been using Sanctuary for some time and after Endpoint Security can give precise per-resource activity. v0.1 can ship without it.

