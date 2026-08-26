#!/bin/bash
# Build, sign, install and launch on every iPhone this Mac can reach.
#
#   tools/deploy_ios.sh            # all connected devices
#   tools/deploy_ios.sh --list     # just show what is reachable
#
# Signing is automatic in the sense that Xcode does it: the team in the
# project signs the build, and any device already in the provisioning profile
# accepts it. What no script can do is put a *new* device into that profile
# without it being attached to this Mac at least once — Apple requires the
# device's identifier to be registered before a profile will include it, and a
# free account has no distribution route (no TestFlight, no Ad Hoc) at all.
#
# So this removes the manual loop for devices you have. A phone in another
# city is a different problem, and the answer to it is a paid account.

set -uo pipefail
cd "$(dirname "$0")/.."

WORKER_URL="${QUICKSHARE_WORKER_URL:-https://directdrop-worker.directdrop-worker.workers.dev}"
BUNDLE_ID="com.mrgraimon.directdrop"

devices() {
  xcrun devicectl list devices 2>/dev/null \
    | awk '/iPhone|iPad/ && ($4 == "connected" || $4 == "available") {print $3 "\t" $1 " (" $4 ")"}'
}

echo "== устройства =="
FOUND=$(devices)
if [ -z "$FOUND" ]; then
  echo "  ничего не найдено."
  echo "  Подключи кабелем, либо убедись что телефон разблокирован и в той же сети."
  exit 1
fi
echo "$FOUND" | sed 's/^/  /'
[ "${1:-}" = "--list" ] && exit 0

echo
echo "== профиль подписи =="
PROFILE=build/ios/iphoneos/Runner.app/embedded.mobileprovision
if [ -f "$PROFILE" ]; then
  security cms -D -i "$PROFILE" 2>/dev/null > /tmp/dd_profile.plist
  EXPIRES=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" /tmp/dd_profile.plist 2>/dev/null)
  echo "  истекает: $EXPIRES"
  EXP_EPOCH=$(date -j -f "%a %b %d %T %Z %Y" "$EXPIRES" +%s 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ "$EXP_EPOCH" -gt 0 ]; then
    DAYS=$(( (EXP_EPOCH - NOW) / 86400 ))
    if [ "$DAYS" -lt 3 ]; then
      echo "  ⚠ осталось $DAYS дн. — после этого приложение перестанет запускаться,"
      echo "    пока не переустановишь этим же скриптом"
    else
      echo "  осталось $DAYS дн."
    fi
  fi
fi

echo
echo "== сборка =="
if ! flutter build ios --profile --dart-define=QUICKSHARE_WORKER_URL="$WORKER_URL" 2>&1 | tail -3; then
  echo "  сборка не прошла"
  exit 1
fi

FAILED=0
while IFS=$'\t' read -r UDID LABEL; do
  [ -z "$UDID" ] && continue
  echo
  echo "== $LABEL =="

  # Two attempts, and the error is printed rather than swallowed. A wireless
  # device reports itself "available" long before its tunnel is actually up,
  # and the first install then dies on a timeout that says nothing useful if
  # it is hidden behind a grep.
  INSTALLED=0
  for ATTEMPT in 1 2; do
    OUTPUT=$(xcrun devicectl device install app --device "$UDID" \
        build/ios/iphoneos/Runner.app 2>&1)
    if grep -q "databaseSequenceNumber" <<< "$OUTPUT"; then
      INSTALLED=1
      break
    fi
    [ "$ATTEMPT" = 1 ] && { echo "  попытка 1 не прошла, повторяю…"; sleep 5; }
  done

  if [ "$INSTALLED" -eq 0 ]; then
    echo "  установка не прошла:"
    grep -oE "RemotePairingError|Operation timed out|not found|denied|[A-Za-z]+Error error [0-9]+" \
      <<< "$OUTPUT" | sort -u | sed 's/^/    /'
    if grep -q "RemotePairingError\|timed out" <<< "$OUTPUT"; then
      echo "    → телефон отвечает по Wi-Fi нестабильно. Подключи кабелем."
    fi
    FAILED=1
    continue
  fi
  echo "  установлено"

  xcrun devicectl device process launch --device "$UDID" \
      --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1 \
    && echo "  запущено" || { echo "  не запустилось"; FAILED=1; continue; }

  # A crash on first launch is the failure mode worth catching automatically:
  # it looks exactly like success from the install step alone.
  sleep 6
  CRASHES=$(mktemp -d)
  xcrun devicectl device copy from --device "$UDID" --domain-type systemCrashLogs \
      --source ./ --destination "$CRASHES" >/dev/null 2>&1
  if find "$CRASHES" -iname "Runner-*" -newermt "-2 minutes" 2>/dev/null | grep -q .; then
    echo "  ⚠ упало при запуске — смотри $CRASHES"
    FAILED=1
  else
    echo "  работает"
  fi
  rm -rf "$CRASHES"
done <<< "$FOUND"

echo
[ "$FAILED" -eq 0 ] && echo "Готово." || echo "Готово, но с ошибками — см. выше."
exit $FAILED
