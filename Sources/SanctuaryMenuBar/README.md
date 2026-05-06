# SanctuaryMenuBar

`SanctuaryMenuBar` is Sanctuary's accessory app. It has no Dock icon and owns
the menu bar dropdown, first-run install prompt, and the user-facing protection
toggle.

## Bundle Structure

The SwiftPM executable does not behave like a normal menu bar app when launched
directly from `.build/release`. Use the bundle script:

`./Sources/SanctuaryMenuBar/scripts/bundle.sh`

It produces:

```text
dist/SanctuaryMenuBar.app/
  Contents/
    Info.plist
    MacOS/SanctuaryMenuBar
    Library/LaunchDaemons/
      ai.hardener.sanctuary.daemon
      ai.hardener.sanctuary.daemon.plist
```

`Info.plist` sets `LSUIElement = true`, which is the key that makes the app an
accessory menu bar app instead of a Dock app.

## SMAppService

The menu bar app registers the bundled daemon with:

`SMAppService.daemon(plistName: "ai.hardener.sanctuary.daemon.plist")`

The dropdown's "Sanctuary protection" switch calls the install and uninstall
paths. Enabling or disabling the daemon requires Touch ID because it changes
whether Sanctuary is actively watching protected resources.

## Signing

The bundle script looks for a Developer ID Application certificate. If one is
available, it signs the app and daemon with hardened runtime options. Otherwise
it ad-hoc signs and prints a warning. Ad-hoc builds are fine for local visual
review, but the production SMAppService flow requires Developer ID signing and
notarization.
