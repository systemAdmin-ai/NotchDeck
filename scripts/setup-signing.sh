#!/bin/bash
# Создаёт локальный сертификат подписи кода «NotchDeck Self-Signed».
#
# Зачем: designated requirement тогда привязан к сертификату, а не к cdhash сборки,
# поэтому разрешение «Универсальный доступ» переживает обновления приложения.
# Без sudo и без диалогов пароля. Приватный ключ живёт только в вашей связке ключей.
#
# Использование:
#   scripts/setup-signing.sh           # создать, если ещё нет
#   scripts/setup-signing.sh --force   # пересоздать (потребуется заново выдать разрешение)
#
# Спека: specs/2026-11-18-локальный-сертификат-для-любого-мака.md

set -euo pipefail

CERT_NAME="NotchDeck Self-Signed"
ORG="NotchDeck"
DAYS=3650
KEYCHAIN="${ND_SIGN_KEYCHAIN:-${HOME}/Library/Keychains/login.keychain-db}"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "setup-signing: неизвестный аргумент $arg" >&2; exit 2 ;;
  esac
done

say() { printf 'setup-signing: %s\n' "$*"; }
die() { printf 'setup-signing: ОШИБКА: %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || die "нет openssl"
command -v security >/dev/null 2>&1 || die "нет утилиты security"
[ -f "$KEYCHAIN" ] || die "не найдена связка $KEYCHAIN"

# R2: уже есть рабочая identity — ничего не делаем.
existing_hash() {
  security find-certificate -a -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null \
    | sed -n 's/.*SHA-1 hash: //p' | head -1
}

has_identity() {
  security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""
}

if [ "$FORCE" -eq 0 ]; then
  if has_identity; then
    say "сертификат «${CERT_NAME}» уже есть — пересоздавать не нужно"
    say "SHA-1: $(existing_hash)"
    say "пересоздать принудительно: $0 --force"
    exit 0
  fi
  # Сертификат в связке есть, но не доверен для подписи кода — чиним доверие, не ключ.
  if [ -n "$(existing_hash)" ]; then
    say "сертификат найден, но не доверен для подписи кода — выдаю доверие"
    TMP_EXIST="$(mktemp -d "${TMPDIR:-/tmp}/ndsign.XXXXXX")"
    trap 'rm -rf "$TMP_EXIST"' EXIT
    security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$TMP_EXIST/cert.pem" 2>/dev/null
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP_EXIST/cert.pem" \
      || die "не удалось выдать доверие сертификату"
    has_identity || die "сертификат так и не стал валидной identity"
    say "готово. SHA-1: $(existing_hash)"
    exit 0
  fi
fi

if [ "$FORCE" -eq 1 ]; then
  OLD_HASH="$(existing_hash)"
  if [ -n "$OLD_HASH" ]; then
    say "удаляю прежний сертификат $OLD_HASH"
    security delete-identity -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1 || true
    security delete-certificate -Z "$OLD_HASH" "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
fi

# R3: ключи только во временном каталоге 700, удаляется на любом выходе.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ndsign.XXXXXX")"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
O = $ORG
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

say "создаю ключ и самоподписанный сертификат (RSA-2048, $DAYS дней, EKU codeSigning)"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1 \
  || die "openssl не смог создать сертификат"

# Пароль p12 одноразовый и живёт только в этом процессе.
P12PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -out "$TMP/nd.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CERT_NAME" -passout "pass:$P12PASS" >/dev/null 2>&1 \
  || die "не удалось собрать p12"

say "импортирую в связку $KEYCHAIN"
security import "$TMP/nd.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null 2>&1 \
  || die "не удалось импортировать сертификат"

say "выдаю доверие корневому сертификату для подписи кода (только этот пользователь)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" \
  || die "не удалось выдать доверие сертификату"

# R4: без рабочей identity выходим с ошибкой, а не «тихим успехом».
if ! has_identity; then
  die "сертификат создан, но codesign его не видит как валидную identity"
fi

HASH="$(existing_hash)"
[ -n "$HASH" ] || die "не удалось прочитать SHA-1 созданного сертификата"

cat <<EOF

Готово. Подпись кода доступна локально.

  identity : $CERT_NAME
  SHA-1    : $HASH
  связка   : $KEYCHAIN
  срок     : $DAYS дней

Сборка подхватит его автоматически (build.sh ищет эту identity).
Разрешение «Универсальный доступ» после первой такой подписи нужно выдать заново —
один раз. Дальше обновления его сохраняют.

Удалить: $0 --force
EOF
