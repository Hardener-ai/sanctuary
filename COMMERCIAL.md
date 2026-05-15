# Commercial Licensing

Sanctuary is dual-licensed. This document explains the boundary between the
open-source runtime and Hardener's commercial offering.

## Open Source Runtime

The Sanctuary runtime in this repository is licensed under the GNU Affero
General Public License, version 3. See [`LICENSE`](LICENSE).

You may use, modify, and redistribute Sanctuary under the AGPL. The central
obligation is source availability: if you modify Sanctuary and make it available
to users, including as part of a network service, those users must be able to
receive the corresponding source under the AGPL.

This license is intentional. Security runtimes should be inspectable, forkable,
and auditable.

## Hardener Cloud

Hardener Cloud is the commercial enterprise control plane for teams deploying
Sanctuary across fleets of Macs. It is separate from the AGPL runtime.

Hardener Cloud provides:

- Central policy management.
- Fleet audit aggregation.
- SSO and role-based access control.
- Compliance reporting.
- SIEM export.
- Admin dashboards for agent activity, denials, tamper events, and policy drift.
- Priority support and SLA.

The local runtime remains fully functional standalone. Hardener Cloud is for
teams that need central management, audit export, or compliance workflows.

## When AGPL Works

AGPL is usually appropriate when:

- You run Sanctuary on your own laptop or workstation.
- You deploy the unmodified runtime internally and comply with the AGPL.
- You integrate Sanctuary with an AGPL-compatible open-source project.
- You are doing security research or evaluation.

## When a Commercial License Is Needed

A commercial license may be appropriate if you want to:

- Embed Sanctuary in a proprietary product.
- Ship Sanctuary as part of a closed-source SDK or runtime.
- Operate a modified proprietary version as a service.
- Avoid AGPL source-disclosure obligations for proprietary integration work.

Commercial licenses are offered case by case. Contact `hello@hardener.ai` with
a short description of your intended use.

## Contributions

Hardener intends to use either a Contributor License Agreement or a Developer
Certificate of Origin process before accepting substantial external
contributions. The purpose is to keep the licensing model clear for both the
AGPL runtime and commercial licensing.

Until that process is finalized, maintainers may ask contributors to confirm
authorship and licensing rights explicitly in pull requests.

## Trademarks

"Sanctuary", "Hardener", and "Hardener Cloud" are trademarks of Hardener,
operated by JULC Limited. The AGPL grants no trademark rights. See
[`TRADEMARKS.md`](TRADEMARKS.md).

## Legal Entity

Hardener is operated by JULC Limited.

- Country of incorporation: Cayman Islands
- Company registration number: OI-390525
- Registered address: Vistra (Cayman) Limited, 31119 Grand Pavilion, Hibiscus
  Way, 802 West Bay Road, Grand Cayman, KY1-1205, Cayman Islands

## Questions

For commercial licensing, partnership, or procurement questions, contact
`hello@hardener.ai`.
