# NotchDeck 2 — Profiles Preview

Task-specific panels introduced in 2.0.0 Preview 1.

## Try it

Open the notch, then choose a profile in its top row. The ellipsis opens profile management. The same window is available from the NotchDeck menu or settings.

- **Мой профиль** preserves your existing apps, layout and appearance.
- **Работа** includes apps, CPU, RAM, battery, network, notes, clipboard and downloads.
- **Видео** provides a minimal panel with media controls, battery and network.
- **Запись** includes recording, screenshots, notes and resource indicators with neon styling.

Each profile saves its application shortcuts, visible items, ordering, appearance, compact mode and automatic player preference. Changes save automatically. You can duplicate, rename and delete profiles; the last profile cannot be deleted. “Вернуть исходный…” creates a new profile from the original migration snapshot.

Switching profiles does not launch applications or start recording. Permissions, microphone preferences, clipboard privacy, notes and alert thresholds remain global. Profiles stay in local UserDefaults and are not included in app packages.

## Build the separate Preview

```sh
BUNDLE_ID=com.notchdeck.preview APP_NAME='NotchDeck Preview' ./build.sh
APP_NAME='NotchDeck Preview' ./scripts/check.sh
```

The Preview uses its own preferences and permission identity. Existing NotchDeck preferences are not modified. New installations start with clean defaults; local testing may import a private configuration separately.

## Validation

`--test-profiles` uses an isolated preferences suite to check migration, independent layouts, persistence, duplicate/rename/delete, original snapshot recovery, corrupt storage recovery and isolation of global privacy settings.

## Adaptive appearance

The design picker includes **Авто**, **Светлый**, and **Тёмный** alongside the original styles. Auto uses native behind-window macOS material and follows the system appearance for foreground contrast. It does not sample screen pixels or classify the brightness of individual windows. Light and dark modes override the system theme. The selected design is saved per profile.

## Halo contrast

The neon halo samples a reduced 256×24 strip behind itself while visible, if screen access is already granted. Its own windows are excluded. A bilinear luminance map and temporal smoothing raise local intensity up to 1.7× on light backgrounds. The halo uses floating-point linear RGB before compositing to reduce gradient quantization. Without permission it uses the base glow. No screenshots are saved. `--test-halo` validates gain bounds, the fallback, and actual sampling when permission is available.
