# First launch

After installing, hover the cutout at the top of the screen. The NotchDeck icon in
the menu bar opens the panel too. A short onboarding appears until you finish it
once and can be replayed from the app menu.

## Permissions

| Feature | Access | How to enable |
|---|---|---|
| Panel, metrics, shortcuts | No extra permission | Works immediately |
| Replacing the system brightness/volume HUD | Accessibility; on macOS 27 — "Device management and data access" | System Settings → Privacy & Security → the matching section → NotchDeck |
| Screenshots, screen recording, system audio | Screen & System Audio Recording | Same place → Screen & System Audio Recording → NotchDeck |
| Glow adapting to the background | Screen & System Audio Recording | Reuses access already granted; without it the glow runs without sampling |
| Voice in recordings | Microphone | Pick a microphone before recording and allow the system prompt |
| Controlling individual players | Automation, if macOS asks | Approve access to that player only |

macOS keyboard access is a broad permission. NotchDeck uses it to handle the
brightness and volume keys. Onboarding never grants permissions for you. Do not
grant access if you do not need the feature.

If macOS asks you to relaunch the app after a permission change — relaunch it.
A permission is bound to the app's signature: the Preview release keeps it across
updates, while a source build does so only after you create the local certificate
(`scripts/setup-signing.sh`, see the README). If the key handling still goes silent
after an update, remove exactly NotchDeck from that list, add the current copy from
Applications and relaunch it. Other apps are not affected.

## Recording

Open the notch and press the record button. Choose the whole main display or a
region, system audio, and "No microphone" / "Microphone — system input". The
input device itself is changed in the system sound settings. For a region, drag
to select it; Esc cancels the selection. Recording then starts: the red button
shows elapsed time, pressing it again stops and saves the file.

Files land in `~/Desktop/Screenshots`. The timer counts from capture start and
can differ slightly from the file duration because of encoder startup.

## Setup and removal

Apps are added by hand in Settings. There is no preinstalled personal set.
Clipboard history is off by default; enable it in "Behavior" and its button in
"Buttons". History lives in memory until you quit.

To remove NotchDeck, quit it from its own menu, turn off launch at login (if you
enabled it), then move the app from Applications to the Trash. Recordings and
notes are not deleted with the app. Settings and notes live in the user
UserDefaults domain `com.notchdeck.app`; that is separate local data.

## Profiles and appearance

In the top row of the expanded notch pick "My profile", "Work", "Video" or
"Recording". The "…" button opens duplication, renaming and deletion. App,
button, order and design changes are saved into the active profile. Permissions
and microphone settings stay global. Switching profiles never starts a recording.

"Settings → Design" offers "Auto", "Light" and "Dark" alongside the earlier
styles. "Auto" follows the macOS theme; the neon halo brightness is adapted
separately from the background. With macOS Reduce Motion on, the low-battery
pulse is disabled.

To replace the system HUD, enable "Settings → Behavior → Replace the system
brightness and volume indicator" and grant the keyboard access listed above.

Русская версия: [GETTING_STARTED.ru.md](GETTING_STARTED.ru.md)

## Quit the app

Use the NotchDeck menu bar icon → **Quit**, or **Settings → General → Quit NotchDeck**. Interface language remains selectable: Auto, Русский, English.
