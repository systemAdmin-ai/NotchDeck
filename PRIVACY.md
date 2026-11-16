# Privacy

NotchDeck runs locally. The app has no accounts, no analytics, no telemetry, no
cloud sync, and never sends your notes, files or recordings to the developer.

| Data | Where it lives | When it is used |
|---|---|---|
| Settings and chosen apps | Current user's UserDefaults, domain `com.notchdeck.app` | To restore the panel |
| Quick notes | Current user's UserDefaults | When you open or edit notes |
| File references on the shelf | Current user's UserDefaults | After you add files to the shelf |
| Clipboard history | Memory only, up to 30 items | Only after you enable it; cleared when disabled |
| Screenshots and recordings | `~/Desktop/Screenshots` | Only when you start a capture |
| Metrics and VPN status | Read locally | To draw the panel |
| Screen brightness behind the glow | A narrow top strip, downscaled to 256×24; process memory only | While the halo is visible and screen access is already granted; no frames are saved |
| Media and artwork | Metadata from the macOS player, process memory | While something is playing |

The microphone is off by default. You can pick it before recording; macOS asks
for access separately. Launch at login is also opt-in.

The debug log is off by default. Even in debug mode the clipboard contents are
never written to the log. Do not paste personal notes, recordings, file paths or
logs into public issues — the macOS version, app version and reproduction steps
are enough.

Neither the installer nor the repository contains user plists, notes, clipboard
history, links to personal files, screen recordings or local logs. macOS manages
permissions separately; they are not carried over with the app.

Русская версия: [PRIVACY.ru.md](PRIVACY.ru.md)
