#!/bin/bash
# Ставит MeetingBRDAgent на новый Mac: зависимости, конфиг, сертификат подписи,
# сборка, автозапуск. Можно запускать повторно — уже сделанные шаги пропускаются.
cd "$(dirname "$0")"
PROJECT="$PWD"
LOG="$PROJECT/install.log"
exec > >(tee "$LOG") 2>&1

CERT="MeetingBRDAgent Local Signing"
LABEL="com.btsanalyst.meetingbrdagent"
CONF_DIR="$HOME/.meeting-brd-agent"
CONF="$CONF_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

fail() { echo; echo "!! $1"; echo "!! Пришли файл install.log в чат с Claude."; read -n 1 -s -r -p "Нажми любую клавишу, чтобы закрыть…"; exit 1; }
step() { echo; echo "== $1 =="; }

# 1. Инструменты разработчика (Swift, git, python3)
step "1/7 Инструменты разработчика Xcode"
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install
  echo "Откроется окно установки. Дождись окончания и запусти этот файл ещё раз."
  read -n 1 -s -r -p "Нажми любую клавишу, чтобы закрыть…"; exit 0
fi
echo "есть"

# 2. Homebrew
step "2/7 Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  [ -x /opt/homebrew/bin/brew ] || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || fail "Homebrew не установился"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
fi
echo "есть: $(brew --version | head -1)"

# 3. ffmpeg, pandoc, OBS
step "3/7 ffmpeg, pandoc, terminal-notifier, OBS"
for p in ffmpeg pandoc terminal-notifier; do brew list "$p" >/dev/null 2>&1 || brew install "$p" || fail "не поставился $p"; done
[ -d "/Applications/OBS.app" ] || brew install --cask obs || fail "OBS не установился"
echo "готово"

# 4. Конфиг с ключами
step "4/7 Конфиг ~/.meeting-brd-agent/config.json"
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF" ]; then
  for src in "$PROJECT/config.json" "$HOME/Downloads/config.json" "$HOME/Desktop/config.json"; do
    if [ -f "$src" ]; then cp "$src" "$CONF"; echo "взял конфиг из $src"; break; fi
  done
fi
if [ -f "$CONF" ]; then
  # Путь к папке протоколов — под нового пользователя
  /usr/bin/python3 - "$CONF" "$HOME" <<'PY'
import json, re, sys, os
path, home = sys.argv[1], sys.argv[2]
d = json.load(open(path))
out = d.get("outputFolder", "")
if not out or out == "CHANGE_ME":
    out = home + "/Documents/MeetingDocs"
d["outputFolder"] = re.sub(r"^/Users/[^/]+", home, out)
os.makedirs(d["outputFolder"], exist_ok=True)
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2)
print("папка протоколов:", d["outputFolder"])
PY
  chmod 600 "$CONF"
else
  echo "конфига нет — при первом запуске приложение создаст его с CHANGE_ME,"
  echo "потом впиши ключи (меню иконки → открыть конфиг)."
fi

# 5. Сертификат подписи (чтобы не слетало разрешение «Запись экрана»)
step "5/7 Сертификат «$CERT»"
if security find-identity -p codesigning | grep -q "$CERT"; then
  echo "есть"
else
  TMP=$(mktemp -d)
  cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$CERT
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1 || fail "не создался сертификат"
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT" -out "$TMP/cert.p12" -passout pass:mbrd >/dev/null 2>&1 || fail "не упаковался сертификат"
  security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P mbrd -T /usr/bin/codesign \
    || fail "не импортировался сертификат в связку ключей"
  echo "Сейчас macOS попросит пароль от Mac, чтобы доверять сертификату для подписи кода."
  security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem" \
    || echo "доверие не выдано — не страшно, подпись всё равно сработает"
  rm -rf "$TMP"
  echo "создан"
fi

# 6. Сборка и подпись
step "6/7 Сборка MeetingBRDAgent"
swift build -c release || fail "сборка не удалась"
codesign --force --deep --sign "$CERT" --identifier "$LABEL" .build/release/MeetingBRDAgent || fail "подпись не удалась"
echo "собрано и подписано"

# 7. Автозапуск при входе в систему
step "7/7 Автозапуск"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$PROJECT/.build/release/MeetingBRDAgent</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>/tmp/meeting-brd-agent.log</string>
    <key>StandardErrorPath</key><string>/tmp/meeting-brd-agent.err</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
launchctl bootstrap "gui/$(id -u)" "$PLIST" || fail "автозапуск не включился"
echo "агент запущен — ищи 🟡 в строке меню"

echo
echo "== ГОТОВО. Осталось руками (1 раз): =="
echo "1. «Запись экрана»: включи MeetingBRDAgent (откроется само)."
echo "2. OBS → Tools → WebSocket Server Settings: включить, порт 4455, пароль как obsPassword в конфиге."
echo "3. OBS → Settings → Output → Recording: формат mp4; добавь источники звука/экрана."
[ -f "$CONF" ] && grep -q CHANGE_ME "$CONF" && echo "4. В конфиге остались CHANGE_ME — впиши ключи: open $CONF"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
read -n 1 -s -r -p "Нажми любую клавишу, чтобы закрыть…"
