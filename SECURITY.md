# Security policy

## Reporting a vulnerability

Open a private report: https://github.com/systemAdmin-ai/NotchDeck/security/advisories/new
(or email the address listed on the GitHub profile).

Please include: app version, macOS version, steps to reproduce, and what you expected.
Do not attach personal notes, recordings, clipboard contents or local logs — a version
number and reproduction steps are enough.

**Russian:** об уязвимостях — приватным отчётом по ссылке выше. Приложите версию
приложения, версию macOS и шаги воспроизведения. Не прикладывайте личные заметки,
записи экрана, содержимое буфера и локальные логи.

## What counts as a vulnerability

- Code execution, privilege escalation, sandbox or TCC bypass.
- Reading files, clipboard, screen or microphone without the user's action and consent.
- Silent network activity: the app has no analytics, no telemetry and no accounts.
- A release asset that does not match the published `SHA256SUMS.txt`.

## What is not a vulnerability

- **Repacks on third-party sites.** NotchDeck is MIT-licensed, so rebuilding and
  redistributing it is allowed. Builds from any site other than the three listed in the
  README are not ours, and problems in them are not problems in NotchDeck.
- The Gatekeeper prompt on first launch. The build is not notarized yet, so macOS asks for
  confirmation once; that is expected behaviour, not a defect.
- The absence of Intel support.

## Response

Best effort within 7 days for the first reply, 90 days for a fix or a public note.
Confirmed reporters are credited in `CHANGELOG.md` unless they ask otherwise.

## Verifying a download

Fast path — the checksum alone:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

A mismatch means the file was modified in transit or by a mirror. Delete it and download
again from https://github.com/systemAdmin-ai/NotchDeck/releases.

Stronger checks, both optional — they prove the file is ours, not merely intact:

```sh
# 1. The checksum file is signed with minisign; the public key is notchdeck.pub in this repo.
minisign -Vm SHA256SUMS.txt -x SHA256SUMS.txt.minisig -P RWTxeYVtAcbWJm9DCTQ9eY/sbTmz789D2/SfZMwsjl+StuA/4LYVoVp8

# 2. GitHub can prove the artifact was produced by this repository's release workflow.
gh attestation verify NotchDeck.dmg --repo systemAdmin-ai/NotchDeck
```

**Русский:** быстрая проверка — `shasum -a 256 -c SHA256SUMS.txt`. Если нужна гарантия,
что файл наш, а не только целый: `minisign` по ключу из `notchdeck.pub` или
`gh attestation verify NotchDeck.dmg --repo systemAdmin-ai/NotchDeck`. Обе проверки
необязательны и на установку не влияют.