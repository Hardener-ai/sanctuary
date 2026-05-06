# NE_FILTER_SPIKE

**Component**: future `Sources/NEFilterSpike/`
**Status**: architecture-deciding spike
**Owner**: SanctuaryDaemon / macOS system extension track
**Do not run in this commit**: spec only

---

## 1. Decision Posture

Run this spike before committing further CDP Guard or daemon-egress
architecture.

The CDP peer-pid spike rejected public Network.framework metadata as the clean
attribution path. The current fallback is `proc_pidfdinfo` socket enumeration.
That is workable, but it is a polling/enumeration primitive, not a policy
primitive.

NetworkExtension's `NEFilterDataProvider` may collapse three separate problems
into one OS-supported surface:

- CDP Guard peer attribution for loopback TCP
- network egress allowlists for protected contexts
- background daemon and LaunchAgent containment

If `NEFilterDataProvider` gives Sanctuary source process identity for loopback
flows without Endpoint Security entitlement, it becomes the strongest v0.1
candidate after the classifier. If it does not, we keep the current
`proc_pidfdinfo` path and avoid burning time on a false hope.

Security posture:

- do not assume NEFilter works for loopback
- do not assume source app identifier is enough
- do not build policy until identity is proven
- fail closed for protected CDP ports if attribution is uncertain

---

## 2. Question

Can `NEFilterDataProvider` give Sanctuary per-flow source process identity for
loopback TCP connections without Endpoint Security entitlement, using a Network
Extension entitlement that Apple is more likely to grant?

Acceptable identity fields:

- pid
- audit token
- stable token from which pid can be derived
- code-signing identity directly tied to the source process

Potentially useful but insufficient alone:

- `sourceAppIdentifier`
- bundle identifier
- signing identifier without pid

The spike must answer:

- Do inbound loopback TCP flows reach the filter?
- Does the callback include source process identity?
- Is the identity available before allowing or dropping bytes?
- Is lookup fast enough for CDP Guard?
- Is the entitlement path realistic for a consumer security product?

---

## 3. Non-goals

This spike does not:

- implement filtering policy
- test outbound allowlists
- integrate with `AgentClassifier`
- ship a production Network Extension
- replace `proc_pidfdinfo` yet
- inspect HTTP or WebSocket payloads
- parse CDP
- classify browsers
- test Team tier controls

No production architecture changes follow from theory. Only the observed spike
result can move NEFilter into the v0.1 critical path.

---

## 4. Test Harness

Executable target:

```text
sanctuary-ne-filter-spike
```

Extension target:

```text
SanctuaryNEFilterSpikeExtension
```

The harness should:

1. Configure a local `NEFilterManager` profile for the spike extension.
2. Load or activate a minimal `NEFilterDataProvider`.
3. Open a localhost TCP listener on an ephemeral port.
4. Connect to that listener from the same spike process.
5. Send one small payload over the connection.
6. In the filter callback, inspect all public flow identity fields.
7. Emit JSON from the controller process.

Expected JSON:

```json
{
  "expected_pid": 12345,
  "loopback_flow_observed": true,
  "observed_identity_fields": {
    "sourceAppIdentifier": "...",
    "sourceAuditToken": "...",
    "sourcePID": 12345,
    "sourceSigningIdentifier": "..."
  },
  "latency_ms": 0.42,
  "entitlement_status": "available | missing | denied | unknown",
  "conclusion": "success | failure | inconclusive"
}
```

Implementation notes:

- Prefer documented public APIs only.
- Do not use private frameworks.
- Do not log payload contents beyond byte counts.
- If profile installation requires user approval, document every prompt.
- If the extension cannot be loaded from SwiftPM alone, create the smallest
  Xcode project or note that packaging is required for the next session.

The first run may require manual system approval. That is acceptable, but the
output must distinguish "API failed" from "profile not approved".

---

## 5. Success Criteria

The spike succeeds only if all are true:

- loopback TCP flows are visible to `NEFilterDataProvider`
- inbound flow callback includes pid or audit-token-derivable pid
- identity is available before flow allow/drop decision
- identity lookup adds less than 1ms on the callback path
- APIs used are documented and public
- entitlement path appears obtainable for Sanctuary's product category

`sourceAppIdentifier` alone is not success. It may help UI labeling, but CDP
Guard needs process-level attribution because multiple tools can live inside
one bundle or extension host.

---

## 6. Failure Criteria

The spike fails if any are true:

- loopback flows are excluded from filter scope
- callback exposes only bundle-level identity
- callback exposes no source identity
- identity arrives only after bytes are already allowed
- entitlement gating is unrealistic for v0.1
- implementation requires private APIs
- filter adds unacceptable latency or instability

An inconclusive result is treated as failure for v0.1 architecture. Sanctuary
can revisit NEFilter later, but the demo path cannot depend on uncertain
entitlement behavior.

---

## 7. Decision Tree Based On Outcome

### SUCCESS

If the spike succeeds:

- NEFilter becomes the primary primitive for CDP Guard attribution.
- NEFilter also becomes the primary primitive for network egress allowlists.
- `proc_pidfdinfo` becomes fallback or diagnostic.
- Update `CDP_GUARD_SPEC.md`.
- Add `NETWORK_EGRESS_SPEC.md` to v0.1 planning.
- Add `SERVICE_INVENTORY_SPEC.md` to v0.1 planning.
- Apply for Network Extension entitlement in parallel with Endpoint Security.
- Re-evaluate v0.1 critical path ranking only after the spike result is
  committed.

### FAILURE

If the spike fails:

- Continue with `proc_pidfdinfo` for CDP Guard.
- Keep network egress allowlists out of v0.1 enforcement.
- Defer service-level network containment to v0.2 with ES or NE entitlement.
- Still ship Service Inventory in v0.1 as monitoring/inventory only.
- Keep the product promise focused on classifier, CDP guard, extension storage,
  clipboard, and FSEvents detection.

### INCONCLUSIVE

If the spike is blocked by packaging or entitlement setup:

- document the exact blocker
- keep `proc_pidfdinfo` as v0.1 primary
- create an entitlement/application task
- do not block CDP Guard skeleton work

---

## 8. Time Budget

Implementation budget:

- 2 hours to create the smallest runnable harness
- 30 minutes to run and analyze

Stop conditions:

- cannot load an NEFilter extension without an entitlement
- loopback flows are definitely invisible
- identity fields are definitely insufficient
- setup expands beyond a small spike into product infrastructure

The output should be a committed result note, not a polished subsystem.
