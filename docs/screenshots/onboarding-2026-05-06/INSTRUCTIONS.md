# Onboarding Screenshot Instructions

Use these after the M5 onboarding build lands.

1. `cd ~/Projects/sanctuary`
2. `./Sources/SanctuaryMenuBar/scripts/bundle.sh`
3. Reset the onboarding sentinel:

   ```sh
   defaults delete ai.getsanctuary.SanctuaryMenuBar onboardingCompleted 2>/dev/null || true
   defaults delete ai.getsanctuary.SanctuaryMenuBar onboardingDismissed 2>/dev/null || true
   defaults delete ai.getsanctuary.SanctuaryMenuBar onboardingStep 2>/dev/null || true
   ```

4. `open dist/SanctuaryMenuBar.app`
5. Capture each onboarding step with `Cmd+Shift+4`, dragging around the onboarding window only:
   - `01-welcome.png`
   - `02-how-it-works.png`
   - `03-install-protection.png`
   - `04-choose-folders.png`
   - `05-choose-wallets.png`
6. Walk through the flow manually.
7. On Step 3, Developer ID signing may not be available yet. If install shows the approval-required state, capture that state and use "Continue anyway."
8. Click "Finish" on Step 5.
9. Click the menu bar shield and capture the configured dropdown as `06-configured-dropdown.png`.

Do not include Terminal windows, API keys, browser tabs, or other private screen contents in these screenshots.
