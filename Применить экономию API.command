#!/bin/bash
# Пересобирает MeetingBRDAgent с экономными настройками Claude API и перезапускает его и Project Hub.
cd "$(dirname "$0")"
LOG="$PWD/rebuild.log"
exec > >(tee "$LOG") 2>&1
echo "== Сборка MeetingBRDAgent =="
swift build -c release || { echo "!! СБОРКА НЕ УДАЛАСЬ — пришли rebuild.log в чат"; exit 1; }
codesign --force --deep --sign "MeetingBRDAgent Local Signing" --identifier com.btsanalyst.meetingbrdagent .build/release/MeetingBRDAgent \
  || { echo "!! ПОДПИСЬ НЕ УДАЛАСЬ — пришли rebuild.log в чат"; exit 1; }

echo "== Перезапуск MeetingBRDAgent =="
if launchctl list | grep -q com.btsanalyst.meetingbrdagent; then
  launchctl kickstart -k gui/$(id -u)/com.btsanalyst.meetingbrdagent && echo "перезапущен через LaunchAgent"
else
  pkill -x MeetingBRDAgent; sleep 1
  nohup .build/release/MeetingBRDAgent >/tmp/meetingbrdagent.log 2>&1 &
  echo "запущен заново (PID $!)"
fi

echo "== Перезапуск Project Hub =="
if [ ! -d "$HOME/Проекты/project-hub" ]; then
  echo "Project Hub не установлен на этом Mac — пропускаю"; echo "== ГОТОВО =="; exit 0
fi
if launchctl list | grep -q com.btsanalyst.projecthub; then
  launchctl kickstart -k gui/$(id -u)/com.btsanalyst.projecthub && echo "перезапущен через LaunchAgent"
else
  pkill -f "python3 server.py"; sleep 1
  (cd "$HOME/Проекты/project-hub" && nohup python3 server.py >/tmp/project-hub.manual.log 2>&1 &)
  echo "запущен заново"
fi
sleep 3
curl -s -o /dev/null -w "Project Hub отвечает: HTTP %{http_code}\n" http://127.0.0.1:8765/api/projects
echo "== ГОТОВО =="
