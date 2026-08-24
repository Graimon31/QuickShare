#!/bin/bash
# Where does a DirectDrop transfer actually travel?
#
#   tools/peer_link_probe.sh [seconds]        # default 120
#
# Start it, then do a transfer however you like — through the app on both
# devices, or by running the pair test. It samples the interface byte counters
# around the window and says which path carried the bytes.
#
# The question it answers is not "how fast" but "over what". A transfer that
# looks slow may be travelling somewhere absurd: out to a VPN server and back,
# or down the USB cable, while the direct Wi-Fi link sits idle. Both have
# already happened here, and neither is visible from a throughput number
# alone.
#
# Run it once with the VPN up and once with it down. The difference is the
# whole point — this has to work either way, so knowing what the VPN changes
# is what makes that possible.

set -uo pipefail
DURATION="${1:-120}"

snapshot() {
  netstat -ib | awk '$1 != "Name" && $7 ~ /^[0-9]+$/ { key=$1; if (!seen[key]++) print key, $7, $10 }'
}

label() {
  case "$1" in
    awdl0|llw0) echo "прямой Wi-Fi между устройствами (AWDL) ← то, что нужно" ;;
    utun*)      echo "VPN-туннель ← трафик уходит наружу и возвращается" ;;
    en0)        echo "обычный Wi-Fi / Ethernet (через роутер)" ;;
    bridge*)    echo "мост" ;;
    lo0)        echo "локальная петля" ;;
    *)          if ifconfig "$1" 2>/dev/null | grep -q "inet6 fe80" && ! ifconfig "$1" 2>/dev/null | grep -q "inet "; then
                  echo "похоже на USB-кабель к устройству"
                else
                  echo "прочее"
                fi ;;
  esac
}

echo "=============================================="
echo " DirectDrop: по какому пути идёт передача"
echo "=============================================="
echo
echo "Окружение:"
if ifconfig 2>/dev/null | grep -q "^utun.*UP"; then
  echo "  VPN:      поднят (есть активные utun)"
else
  echo "  VPN:      не обнаружен"
fi
WIFI_DEV=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')
if [ -n "${WIFI_DEV:-}" ]; then
  echo "  Wi-Fi:    $WIFI_DEV — $(ifconfig "$WIFI_DEV" 2>/dev/null | grep -q "status: active" && echo "включён" || echo "выключен")"
fi
if ifconfig 2>/dev/null | grep -q "^awdl0.*UP"; then
  echo "  awdl0:    интерфейс поднят"
else
  echo "  awdl0:    не поднят (появится при первой прямой передаче)"
fi
CABLE=$(ifconfig 2>/dev/null | awk '/^en[0-9]+:/{d=substr($1,1,length($1)-1)} /inet6 fe80/{if(d!="")c[d]=1} /inet /{if(d!="")delete c[d]} END{for(k in c) print k}' | head -1)
if [ -n "${CABLE:-}" ]; then
  echo "  кабель:   похоже, устройство подключено по USB ($CABLE)"
  echo "            ⚠ по кабелю система охотно пустит трафик вместо Wi-Fi —"
  echo "              для честного замера прямого линка отключи кабель"
else
  echo "  кабель:   USB-подключений к устройству не видно — это правильно"
fi
echo
echo "Снимаю счётчики и жду $DURATION секунд."
echo "▶ ЗАПУСКАЙ ПЕРЕДАЧУ ПРЯМО СЕЙЧАС."
echo

snapshot > /tmp/dd_probe_before.txt
START=$(date +%s)
for ((i = DURATION; i > 0; i--)); do
  printf "\r  осталось %3d с " "$i"
  sleep 1
done
printf "\r%*s\r" 24 ""
snapshot > /tmp/dd_probe_after.txt
ELAPSED=$(( $(date +%s) - START ))

echo "=============================================="
echo " Трафик за $ELAPSED с (только заметное, >1 МБ)"
echo "=============================================="
echo

python3 - "$ELAPSED" <<'PY'
import sys
elapsed = max(int(sys.argv[1]), 1)

def load(path):
    out = {}
    for line in open(path):
        parts = line.split()
        if len(parts) == 3:
            try:
                out[parts[0]] = (int(parts[1]), int(parts[2]))
            except ValueError:
                pass
    return out

before, after = load('/tmp/dd_probe_before.txt'), load('/tmp/dd_probe_after.txt')
rows = []
for name in sorted(set(before) | set(after)):
    bi, bo = before.get(name, (0, 0))
    ai, ao = after.get(name, (0, 0))
    din, dout = (ai - bi) / 1048576, (ao - bo) / 1048576
    if din > 1 or dout > 1:
        rows.append((name, din, dout))

if not rows:
    print('  Ничего заметного не прошло. Передача точно шла в это окно?')
else:
    print(f'  {"интерфейс":<10} {"принято":>10} {"отдано":>10}   МБ/с')
    for name, din, dout in sorted(rows, key=lambda r: -(r[1] + r[2])):
        peak = max(din, dout) / elapsed
        print(f'  {name:<10} {din:>9.1f}  {dout:>9.1f}   {peak:>6.2f}')
    print()
    top = max(rows, key=lambda r: r[1] + r[2])[0]
    print(f'  Больше всего прошло через: {top}')
PY

echo
echo "  Расшифровка интерфейсов:"
for iface in $(python3 -c "
import sys
def load(p):
    d={}
    for line in open(p):
        q=line.split()
        if len(q)==3:
            try: d[q[0]]=(int(q[1]),int(q[2]))
            except ValueError: pass
    return d
b,a=load('/tmp/dd_probe_before.txt'),load('/tmp/dd_probe_after.txt')
for k in sorted(set(b)|set(a)):
    bi,bo=b.get(k,(0,0)); ai,ao=a.get(k,(0,0))
    if (ai-bi)/1048576>1 or (ao-bo)/1048576>1: print(k)
"); do
  echo "    $iface — $(label "$iface")"
done
echo
echo "Готово. Пришли этот вывод целиком."
