# Sanctuary Menu Bar Screenshot Instructions

Codex can build and launch the app, but it cannot safely take the tight
manual screenshots needed for visual approval. Please capture these directly
on the Mac.

1. Open Terminal.
2. Run:

   ```sh
   cd ~/Projects/sanctuary
   ./Sources/SanctuaryMenuBar/scripts/bundle.sh
   open dist/SanctuaryMenuBar.app
   ```

3. Look at the top-right of the screen. A shield icon should be visible in the
   macOS menu bar, near other menu bar apps such as Bluetooth, Wi-Fi, or
   battery.
4. Take the light-mode icon screenshot:
   - Press `Cmd+Shift+4`.
   - Drag a tight rectangle around just the shield icon.
   - Save it in this folder as `menubar-icon-light-real.png`.
5. Click the shield icon. The Sanctuary dropdown should open.
6. Take the light-mode dropdown screenshot:
   - Press `Cmd+Shift+4`.
   - Drag a tight rectangle around just the dropdown panel.
   - Save it in this folder as `dropdown-light-real.png`.
7. Switch to dark mode:
   - Open System Settings.
   - Go to Appearance.
   - Select Dark.
   - Wait 2 seconds for the menu bar app to update.
8. Repeat steps 4 and 6, saving:
   - `menubar-icon-dark-real.png`
   - `dropdown-dark-real.png`
9. Click the shield icon again and choose Quit.

The `*-real.png` files are the source of truth for visual approval. The
`synthetic-do-not-use/` folder contains earlier generated review images that
are preserved only for comparison history.
