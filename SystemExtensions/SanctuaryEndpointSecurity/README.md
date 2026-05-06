# Sanctuary Endpoint Security Extension

This directory is reserved for the Endpoint Security system extension target.

The production target will require:
- `com.apple.developer.endpoint-security.client`
- code signing and notarization
- Xcode project wiring for the system extension and containing app

Until Apple grants the entitlement, prototype enforcement logic should stay isolated behind interfaces in `SanctuaryCore` so the fallback implementation and ES implementation can share policy and process identity behavior.
