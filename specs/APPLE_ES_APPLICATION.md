# APPLE_ES_APPLICATION

**Purpose**: Pre-formatted narrative content to paste into Apple's Endpoint Security entitlement application. Submit, then move on. Sanctuary v0.1 ships without ES; this entitlement is a v0.2 hardening upgrade.

**Time investment**: ~4 hours total (90 min to refine narrative below + 90 min for supporting evidence package + 60 min form-filling).

**Submission path**: Apple Developer Program member portal → Contact Us → Endpoint Security → Request Entitlement. (Form path may change; check developer.apple.com when submitting.)

---

## 1. What Apple is looking for

Apple grants `com.apple.developer.endpoint-security.client` to applicants who can demonstrate:

1. **Legitimate security purpose** — protecting users, not surveilling them
2. **Specific scope** — exact ES events needed, not a blank check
3. **Vendor competence** — track record or credible bench
4. **Defensive use only** — read-and-deny, not modify or exfiltrate
5. **Transparency** — open source helps; published threat model helps more

Common rejection reasons:

- Generic "we're a security product" framing without specifics
- Asking for events not justified by the product
- No public-facing artifacts (no website, no docs, no GitHub)
- Vendor unknown to Apple, no signed apps with Developer ID history

The narrative below addresses each.

---

## 2. The application narrative

### Company / applicant

**Sanctuary** (working name; final brand TBD before submission)
Operating entity: [Tobias's Dubai entity name]
Apple Developer Program member ID: [TBD on enrollment]
Primary technical contact: [Tobias name + email]
Secondary technical contact: [Co-founder / contractor name once recruited]
Public website: https://sanctuary.app *(or final domain)*
GitHub organization: https://github.com/sanctuary-app

### Product summary (1 paragraph)

Sanctuary is a consumer macOS security application that protects users running local AI coding agents (Claude Code, Cursor, Cline, Aider, OpenClaw, Codex, Goose, and similar) from supply-chain attacks via malicious agent skills, prompt injection, and credential exfiltration. Sanctuary identifies AI agent processes and prevents them from reading user-designated sensitive resources — wallet keystores, SSH keys, cloud credentials, password manager extensions — even when the agent has the user's filesystem permissions. The product is single-user, runs entirely locally, makes no outbound network connections in its enforcement path, and is open source.

### Why we need Endpoint Security

Sanctuary's core function is to deny filesystem access to a class of processes (AI agents) for a class of paths (user-designated sensitive folders) **synchronously** — before the read completes. This requires intercepting the syscall before it returns data to the agent.

Available alternatives we have evaluated and found insufficient:

- **TCC**: too coarse. TCC operates at app-bundle and folder-class granularity. Sanctuary needs per-process, per-path policy with the ability to identify "is this process an AI agent?" — a question TCC has no concept of.
- **FSEvents**: asynchronous and post-hoc. The read has completed by the time we hear about it. We ship a v0.1 that uses FSEvents for detection-and-alert, but enforcement requires ES.
- **Sandbox profiles**: require the agent to opt in by being launched through `sandbox-exec`. Users will not remember to do this; the product cannot be "you have to remember to wrap every agent invocation."
- **DTrace, kauth**: deprecated paths.

ES is the only API that gives us synchronous, kernel-level deny capability with the privacy and stability guarantees Apple requires.

### Specific events requested

We request `com.apple.developer.endpoint-security.client` to subscribe to the following events. Each is justified below.

**AUTH events** (we will deny when policy matches):

- `ES_EVENT_TYPE_AUTH_OPEN` — to deny file open by agent processes for user-protected paths. Core to the product.
- `ES_EVENT_TYPE_AUTH_READDIR` — to make protected directories appear empty/missing to agent processes. Without this, even if file open is blocked, the agent can still enumerate.
- `ES_EVENT_TYPE_AUTH_GETATTRLIST` — to prevent agents from probing existence of files via stat-like calls.

**NOTIFY events** (we observe only):

- `ES_EVENT_TYPE_NOTIFY_EXEC` — to maintain our process classifier index. We classify a process as agent/non-agent at exec time.
- `ES_EVENT_TYPE_NOTIFY_FORK` — to track parent-child relationships for agent process attribution.
- `ES_EVENT_TYPE_NOTIFY_EXIT` — to clean up our process classifier cache.
- `ES_EVENT_TYPE_NOTIFY_OPEN` — to populate our open-fd attribution index for events from non-AUTH paths (used in audit logging and UI).

We do **not** request:

- File content reading from ES (we never read file contents through ES — we only deny or allow)
- Process memory inspection
- Network event subscription (out of v1 scope)
- Authentication or authorization events
- Any event involving user keystrokes or passwords

### Defensive use only — explicit commitments

We commit publicly that the Sanctuary ES extension will:

1. Never read file contents via ES events. We use ES purely to deny or allow.
2. Never transmit any ES event data, file path, or process metadata to a remote server. Sanctuary's enforcement path is fully local.
3. Never log file contents in our audit log. The audit log records the decision (allow/deny) and the metadata (process identity, file path), nothing about the file contents.
4. Open source the entire ES extension code under the AGPL v3 license. The source will be public on GitHub from the day the entitlement is approved.
5. Publish our threat model and bypass disclosure policy publicly.

### Track record / credentials

[Tobias's relevant background: independent developer with portfolio of production projects in trading systems, AI agent infrastructure, and security-adjacent tooling. Specific public references: link to public repos / projects that demonstrate platform competence.]

[Once a contractor / co-founder is hired with prior macOS security experience: include their bio. CrowdStrike / SentinelOne / Jamf alumni or Apple platform team alumni dramatically strengthen the application.]

### Threat the product addresses

This is the published evidence we cite for the product's necessity:

- **Cisco Talos research (2025)**: AI coding agents fail decisively against malicious skills. Hidden instructions in emails and webpages successfully hijack agent behavior across major frameworks.
- **Permiso / Rufio research (2025)**: built and demonstrated a credential-stealing skill for a major coding agent registry. Mapped command-and-control infrastructure operated by attackers actively targeting agent users.
- **Snyk research (2025)**: 13.4% of public agent skills audited by Snyk contain critical security issues, including credential-exfil capability.
- **Oasis Security (2025)**: 40,000+ exposed AI agent instances reachable from the public internet; any visited webpage can hijack a vulnerable agent.

Real-world impact: Zerion lost $100,000 from hot wallets in a 2025 incident attributed to agent-related social engineering. CertiK reports ~$600M lost industry-wide to crypto exploits in 2026 with AI-augmented attacks identified as a top escalating threat.

The user population at risk runs local AI coding agents alongside cryptocurrency wallets, SSH keys, cloud credentials, and password managers — all on the same machine, all readable by any agent process at the user's permission level. There is no current macOS-native consumer-grade defense for this attack surface.

### Why a consumer security product, not enterprise

Sanctuary is positioned for individual developers and small teams. The user base most affected by the threats above — independent developers, traders, researchers running local agents — falls between what enterprise EDRs (CrowdStrike, SentinelOne) target and what consumer antivirus addresses. Existing EDR products are priced and packaged for enterprise procurement and do not have AI-agent-specific intelligence. Existing consumer products do not address process-level threats from agents the user themselves installed.

Our user base will overlap meaningfully with Apple's developer customer base and with users of Apple's own security-conscious features (FileVault, Lockdown Mode, Keychain). Sanctuary is complementary to those.

### Distribution

- Direct download (signed, notarized .pkg) from sanctuary.app
- Homebrew cask
- GitHub releases
- **Not** the Mac App Store — System Extension entitlements are incompatible with App Store sandboxing. We acknowledge this and accept it.

### Privacy posture

- No telemetry. None. Not opt-in, not opt-out — none.
- Audit log stays on user's machine. Optional cloud sync (E2E encrypted) is a future feature behind explicit user opt-in, post-v0.2.
- No accounts required for the free tier. Pro tier authenticates only at install time for license validation; runtime is fully offline.

This privacy posture is a hard product commitment, not a marketing line. We will publish our network behavior with traffic captures.

### Schedule

- Entitlement requested: [submission date]
- Sanctuary v0.1 ships without ES (FSEvents detection only): [target ship date]
- Sanctuary v0.2 ships with ES enforcement: 4-8 weeks after entitlement granted
- Public open source release on GitHub: at v0.1 ship

We are prepared to engage in extended technical review with Apple's Endpoint Security team. We will provide source access to the ES extension code and answer specific questions about syscall handling, denial behavior, and resource cleanup before approval if requested.

---

## 3. Supporting evidence package

Submit alongside the application:

1. **Sanctuary product specification** — the public SPEC.md
2. **Threat model document** — published version of SPEC §2
3. **Architecture diagram** — daemon / extension / CLI / menu bar relationships
4. **List of ES events with per-event justification** — the table from §2 above, expanded
5. **Privacy commitment letter** — single-page formal commitment matching the bullets above, signed by the legal entity holder
6. **Resume / portfolio of technical contacts** — Tobias + contractor bios with links to relevant past work
7. **Code sample (when v0.1 lands)** — link to the public GitHub repo with the FSEvents implementation already shipped, demonstrating both that we can ship competent macOS systems code and that we will treat the ES code with the same discipline

---

## 4. After submission

1. Mark internally as "submitted on [date]" — do not block anything else on this
2. Continue building Sanctuary v0.1 entirely on FSEvents Detection per `FSEVENTS_DETECTION_SPEC`
3. Apple may respond with technical questions in 2-8 weeks. Have a designated responder; respond within 48h to keep the application alive
4. Approval typically comes 4-12 weeks after a clean technical review
5. On rejection: ask for the specific concern, address it, resubmit. Rejections are usually scope-related (asking for too many events) or vendor-trust-related (too new, too thin). Both are addressable.

---

## 5. Resubmission strategy if rejected

If the first application is rejected, the strongest single thing we can do is:

- Ship v0.1 publicly with FSEvents Detection
- Accumulate at least 5,000 users and a published security disclosure record
- Get one independent security researcher to publicly endorse the product
- Resubmit with this evidence

Apple is more willing to grant ES to vendors with a track record than to vendors with only a plan. v0.1's job is to build the track record.

---

## 6. Submission checklist

- [ ] Apple Developer Program enrollment confirmed (paid, active)
- [ ] Public website live at sanctuary.app
- [ ] Public GitHub org with at least the SPEC.md visible
- [ ] Privacy commitment letter signed and dated
- [ ] Technical contact details verified
- [ ] All §2 narrative sections customized with final names, dates, contacts
- [ ] Supporting evidence package assembled
- [ ] Submitted via developer.apple.com support channel
- [ ] Submission date recorded internally
- [ ] Calendar reminder for Day 30 (status check), Day 60 (escalation if no response)
