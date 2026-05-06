# Menu Bar Foundation Reference Notes — 2026-05-06

## Local Reference Availability

- `1Password.app`: not found in `/Applications`, `/System/Applications`, or Spotlight metadata.
- `Bartender.app`: not found in `/Applications`, `/System/Applications`, or Spotlight metadata.
- `Ice.app`: not found in `/Applications`, `/System/Applications`, or Spotlight metadata.
- `Tot.app`: not found in `/Applications`, `/System/Applications`, or Spotlight metadata.
- `Things.app`: not found in `/Applications`, `/System/Applications`, or Spotlight metadata.
- `System Settings.app`: available as the local macOS baseline.

No online reference images were used.

## Comparison Notes

- The Sanctuary status item uses a single SF Symbol in template rendering,
  matching the visual weight expected of Sonoma+ menu extras and avoiding
  branded color in the menu bar.
- The dropdown uses system typography only: 15 pt semibold title, 13 pt body,
  and 11 pt secondary text. This aligns with compact macOS utility surfaces
  rather than a web-style panel.
- Row height is held at a 28 pt minimum with 12 pt content padding. The result
  sits closer to System Settings and small utility popovers than to a full app
  sidebar.
- Colors are all system colors. Green/gray status dots are intentionally quiet;
  red remains reserved for active denials.
- The dropdown background uses regular material. It is softer than a flat
  opaque panel but avoids custom shadows or decorative styling.

## Screenshot Method

The running app was built and launched successfully. Accessibility automation
for clicking the menu extra was blocked by macOS for this shell, and broad
full-screen capture was rejected to avoid exposing private desktop content.

The committed SwiftUI view was therefore mirrored into a local renderer to
produce deterministic 2x review artifacts for the icon and dropdown in light
and dark appearances.
