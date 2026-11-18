# 2.1.1 · Neon survives sleep and updates

- The media-key interceptor no longer dies silently. It now checks that its event tap is
  still alive every 3 seconds and rebuilds the tap after sleep or a system timeout, so the
  neon brightness/volume readout stops falling back to the system overlay.
- The bundle is signed with a stable local certificate instead of ad-hoc: the code
  requirement is tied to the certificate rather than the build hash, so the Accessibility
  permission survives version updates. One re-approval is required for this first build.

# 2.1.0 · macOS 14, CI tests, Homebrew

- The bundle now targets macOS 14 (Sonoma) instead of macOS 26. Liquid Glass stays on
  macOS 26+, older systems use a blur material with the same radius and outline.
- Separate `tests` job in CI runs every self-check before packaging; build badge in both READMEs.
- Install through Homebrew: `brew install --cask systemAdmin-ai/notchdeck/notchdeck`.

# 2.0.1 · Distribution fixes

- Permanent `NotchDeck.dmg` and `NotchDeck.zip` release assets, with checksum verification and automatic alias publication.
- Visible **Quit NotchDeck** button in Settings → General, localized in English and Russian.
- Explicit Finder icon metadata and bundle checks for the embedded 1024px Retina icon.
- English default GitHub documentation; Auto / Русский / English language selection remains available in the app.

# Changelog

Все заметные изменения NotchDeck. Формат — «версия, дата, что изменилось».

## 2.0.0-preview.2 — 16.11.2026

Английский интерфейс и выбор языка.

Новое:
- Локализация RU/EN: все строки интерфейса вынесены в слой перевода, английская таблица — `Resources/en.lproj/Localizable.strings`.
- Выбор языка в первом экране знакомства и в новой вкладке «Общие» настроек: «Авто» (по языку системы), «Русский», «English».
- Смена языка применяется сразу: меню в строке состояния, панель и вкладки настроек пересобираются без перезапуска приложения.

Ограничения прежние: Apple Silicon и macOS 26+, подпись ad-hoc без нотариализации, системные запросы доступа (микрофон, Apple Events) пока на русском.

## 0.1.0 — 14.11.2026 (Preview)

Первый публичный предпросмотр.

Новое:
- Панель в чёлке: раскрывается при наведении курсора, сворачивается при уходе.
- Показатели: память, батарея, процессор, температура, сеть приёма и передачи, диск; набор плиток и порядок настраиваются.
- Неоновый индикатор яркости и громкости вместо системного (после выдачи доступа к клавишам).
- Зелёный импульс при подключении питания и красные предупреждения по настраиваемым порогам заряда и нагрузки.
- Компактный плеер при воспроизведении музыки и видео, с возможностью развернуть панель.
- Запись экрана: выбор области, микрофона и системного звука, красная кнопка с таймером, файлы в папке Screenshots.
- Быстрые заметки с локальным хранением; закреплённые приложения для запуска из панели.
- История буфера обмена — по желанию, только в памяти до закрытия приложения.
- Пять оформлений: Стекло, Графит, Полночь, Сияние, Неон.
- Знакомство при первом запуске в четырёх шагах; автозапуск и история буфера выключены по умолчанию.

Известные ограничения предпросмотра:
- Сборка для Apple Silicon, требуется macOS 26 и новее; Intel не поддерживается.
- Подпись ad-hoc, без Developer ID и нотариализации: первый запуск подтверждает пользователь в системных настройках.
- Температура и управление яркостью зависят от модели Mac; метаданные плееров и статус VPN — от установленных приложений.
- Для медиа используется частный системный интерфейс через mediaremote-adapter; поведение может измениться после обновления macOS.
