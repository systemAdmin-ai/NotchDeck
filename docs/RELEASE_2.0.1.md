# NotchDeck 2.0.1 — download and app identity fixes

- Permanent download names: `NotchDeck.dmg` and `NotchDeck.zip`. The platform can use https://github.com/systemAdmin-ai/NotchDeck/releases/latest/download/NotchDeck.dmg for future releases.
- Release automation verifies checksums and maintains these filenames automatically.
- Finder icon metadata explicitly points to the bundled Retina `.icns` icon. Distribution checks reject a missing or malformed icon.
- **Quit NotchDeck** is available in **Settings → General**, in addition to the menu bar menu. Active screen recording is stopped when quitting.
- In-app language selection remains **Auto / Русский / English** and switches immediately. GitHub documentation remains English by default, with a Russian translation.

Drag NotchDeck.app to Applications to replace the older app. User settings are stored separately and are not included in the installer. The app remains ad-hoc signed without Apple notarization; macOS may ask you to refresh permissions after replacing a build. Use the standard macOS Privacy & Security workflow if launch is blocked.
