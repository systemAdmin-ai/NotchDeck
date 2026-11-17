# Keyboard mode · SDD

## Request
Add a separate keyboard button to NotchDeck, highlight it when working, toggle by click, and automatically enable on an external keyboard connection.

## Behavior
- External USB/Bluetooth keyboards use the proven DeskBridge native Alt+Shift and left Ctrl→Command implementation. Built-in and unknown transports are excluded; right Ctrl is preserved.
- One owner controls both features. A running standalone DeskBridge blocks activation; NotchDeck does not silently modify its maps. Close DeskBridge before enabling the integrated mode.
- Auto defaults on. A manual override persists across reconnect/restart until the user toggles again or explicitly resets automatic mode.
- Green means an external device exists, HID access is open and at least one native service map is verified. Permission failures, conflicts and waiting states are never green. Terminal exceptions are amber; Alt+Shift remains enabled there.
- Settings and recovery journal use the host bundle’s own Application Support namespace. No DeskBridge user profiles are imported implicitly.
- Input Monitoring must be granted to the actual NotchDeck bundle. A DeskBridge grant does not transfer.
- On disable/normal exit, native maps restore through the ownership-aware recovery journal.
- Button is available in the notch action row and visibility preferences. Settings include an automatic toggle and explicit permission action, in Russian and English.

## Acceptance
Automated: policy vectors for connect/manual off/reconnect/auto reset; device scope; confirmed-map active status; errors/permissions never green; action visibility and visual glow; all existing NotchDeck checks.
Manual: separate button in real notch, on/off, permission, actual Ctrl+A/C/V and Alt+Shift, external connect/disconnect, same-device multiple interfaces, terminal exception, close/exit and coexistence with standalone DeskBridge. Auto detection with Bluetooth remains hardware-dependent and requires physical acceptance.

No exact Windows navigation or driver is introduced in this change. Existing profiles and unrelated notch behavior must remain compatible.

## Validation — 2026-11-17
Preview bundle: com.notchdeck.keyboard-preview, version 2.1.0 (223). All 25 keyboard checks and existing bundle/profile/brightness/layout/key-routing/halo/HUD checks pass; strict codesign verification passes. Live UI confirms a separate action, standalone-conflict status, and waiting state with no external keyboard. Input Monitoring was explicitly authorized and enabled for this preview, then the app restarted. Physical external-keyboard on/off, Ctrl shortcuts, Alt+Shift and Bluetooth reconnection remain pending user acceptance.
