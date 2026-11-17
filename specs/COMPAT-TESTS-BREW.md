# Совместимость, тесты в CI, Homebrew — спецификация

Дата: 17.11.2026. Ветка: `main`. Репозиторий: `systemAdmin-ai/NotchDeck`.

## Зачем

Boring Notch (`TheBoredTeam/boring.notch`) требует macOS 14 и работает на Intel, имеет
тесты в CI и установку через `brew install --cask`. NotchDeck требует macOS 26 и
Apple Silicon, тесты существуют только как флаги бинарника, установка — только скрипт
и DMG. Закрываем три разрыва: совместимость, видимость тестов, установка.

## R1. Минимальная версия macOS — 14.0

`LSMinimumSystemVersion` = `14.0`, `swiftc -target arm64-apple-macos14.0`,
фреймворк MediaRemoteAdapter собирается с `-mmacosx-version-min=14.0`.

**Критерий приёмки:** `./build.sh` завершается с кодом 0; в собранном
`Build/NotchDeck.app/Contents/Info.plist` ключ `LSMinimumSystemVersion` равен `14.0`;
`otool -l` по бинарнику и по `MediaRemoteAdapter` показывает `minos 14.0`.

## R2. Нет вызовов API новее 14.0 без проверки доступности

`NSGlassEffectView` (macOS 26) используется только внутри `if #available(macOS 26.0, *)`;
на более старых системах фон инструментов рисуется `NSVisualEffectView` с тем же
радиусом 16 и той же светлой обводкой.

**Критерий приёмки:** `swiftc -target arm64-apple-macos14.0 … -typecheck` по всем
файлам `Sources/**` не выдаёт ошибок доступности; визуально `ToolBackground`
на macOS 26 идентичен прежнему (стекло), на 14–25 — размытие материала.

## R3. Тесты запускаются отдельной задачей CI и видны бейджем

Файлы самопроверок остаются там, где они есть (`Sources/Checks.swift`,
`Sources/ProfileChecks.swift`, `Sources/Keyboard/KeyboardModeChecks.swift`) —
они компилируются в бинарник. Добавляется задача `tests` в
`.github/workflows/build.yml`, которая собирает приложение и прогоняет все
`--test-*` режимы, а также `scripts/check_bundle.py`. В `README.md` и
`README.ru.md` — бейдж статуса сборки.

**Критерий приёмки:** в GitHub Actions появляются две задачи — `build` и `tests`;
обе зелёные на коммите; в README бейдж ведёт на `/actions/workflows/build.yml`;
`./scripts/check.sh` локально возвращает 0.

## R4. Установка через Homebrew

Отдельный tap-репозиторий `systemAdmin-ai/homebrew-notchdeck` с
`Casks/notchdeck.rb`: `version 2.0.1`, `sha256` из `SHA256SUMS.txt` релиза,
`url` на `NotchDeck.dmg`, `app "NotchDeck.app"`, `caveats` про ad-hoc подпись.
Команда установки: `brew install --cask systemAdmin-ai/notchdeck/notchdeck`.

**Критерий приёмки:** `brew audit --cask notchdeck` возвращает 0 без замечаний;
`brew install --cask systemAdmin-ai/notchdeck/notchdeck` устанавливает версию 2.1.0
в `/Applications`; `brew uninstall --cask notchdeck` её удаляет. В README добавлена
строка установки.

**Факт проверки (17.11.2026):** аудит чистый; установлен `2.1.0` с
`LSMinimumSystemVersion 14.0`; карантин Homebrew не снимает автоматически —
поэтому и в cask, и в README указан разовый `xattr -dr com.apple.quarantine`
либо флаг `--no-quarantine`; удаление прошло без остатка в `/Applications`.

## R5. Тексты требований соответствуют коду

README (EN/RU), `docs/index.html`, `Preferences.swift`, `docs/GETTING_STARTED*`
говорят «macOS 14+» вместо «macOS 26+». Упоминание «проверено на macOS 27»
остаётся, но формулируется как «протестировано на macOS 27; сборка
поддерживает macOS 14+».

**Критерий приёмки:** в README и docs нет требования «macOS 26+» как системного
требования (упоминание SDK macOS 26+ в инструкции сборки допустимо); в бейджах
обоих README — `macOS-14%2B`.

## Вне области

- Поддержка Intel (`x86_64`). Сборка остаётся arm64-only, README это прямо
  указывает.
- Developer ID подпись и нотаризация Apple — нет аккаунта, поведение Gatekeeper
  не меняется.
- Публикация cask в официальном `homebrew/cask` — требует нотаризации и
  популярности; ограничиваемся собственным tap.
- Портирование на macOS 13 и ниже.

## Открытые вопросы

1. Нужна ли отдельная сборка под Intel? Ответ пользователя: пока нет.
2. Тесты остаются исполняемыми режимами бинарника, а не XCTest-таргетом:
   перевод на `swift test` требует переезда сборки на SwiftPM, что меняет
   `build.sh` и CI. Отложено до отдельного решения.
