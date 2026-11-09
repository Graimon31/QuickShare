#!/usr/bin/env bash
set -euxo pipefail
mkdir -p audit
package=com.directdrop.app
adb logcat -c
adb install audit/release.apk | tee audit/install.txt
grep -q Success audit/install.txt
adb shell dumpsys package "$package" > audit/package.txt
grep -q 'versionName=1.0.29' audit/package.txt
launch() {
  local label=$1
  adb shell am start -W -n "$package/.MainActivity" | tee "audit/start-$label.txt"
  sleep 15
  adb shell pidof "$package" | tee "audit/pid-$label.txt"
  test -s "audit/pid-$label.txt"
  adb shell uiautomator dump /sdcard/directdrop-window.xml
  adb pull /sdcard/directdrop-window.xml "audit/ui-$label.xml"
  python3 - "$label" <<'PY'
from pathlib import Path
import sys,xml.etree.ElementTree as ET
root=ET.parse(Path('audit')/('ui-'+sys.argv[1]+'.xml')).getroot()
nodes=list(root.iter('node'))
assert any(n.attrib.get('package')=='com.directdrop.app' for n in nodes),'App UI was not rendered'
text=' '.join(n.attrib.get('text','')+' '+n.attrib.get('content-desc','') for n in nodes)
assert any(w in text.lower() for w in ['send','отправить']),text
assert any(w in text.lower() for w in ['receive','получить','принять']),text
print('Flutter home UI rendered:',sys.argv[1])
PY
}
launch first-install
adb shell am force-stop "$package"
# Android 7 emulator exposes an emulated Ethernet adapter; its legacy
# svc wifi process exits 137. Disable all non-loopback adapters as root
# and assert their IFF_UP flags instead of accepting that failed command.
api=$(adb shell getprop ro.build.version.sdk | tr -d '\r')
if [ "$api" -le 24 ]; then
  adb root
  adb wait-for-device
  adb shell id | grep 'uid=0'
  adb shell 'for iface in /sys/class/net/*; do name=${iface##*/}; if [ "$name" != lo ]; then ip link set "$name" down; fi; done'
  adb shell 'for iface in /sys/class/net/*; do name=${iface##*/}; if [ "$name" != lo ]; then echo "$name $(cat "$iface/flags")"; fi; done' > audit/offline-interface-flags.txt
  python3 - <<'PYFLAGS'
from pathlib import Path
rows=[line.split() for line in Path('audit/offline-interface-flags.txt').read_text().splitlines() if line.strip()]
assert rows, 'No network adapters inspected'
assert all(int(flags,16)&1==0 for name,flags in rows),rows
print('All non-loopback interfaces administratively down:',rows)
PYFLAGS
else
  adb shell svc wifi disable
  adb shell svc data disable
fi
launch offline-restart
adb shell am force-stop "$package"
adb install -r audit/release.apk | tee audit/reinstall.txt
grep -q Success audit/reinstall.txt
launch upgrade-same-release
adb logcat -d > audit/logcat.txt
if grep -E 'FATAL EXCEPTION|Fatal signal|Unhandled Exception|E/flutter.*(Exception|Error)' audit/logcat.txt; then exit 1; fi
adb shell am force-stop "$package"
adb uninstall "$package" | tee audit/uninstall.txt
grep -q Success audit/uninstall.txt
printf '{"install":"passed","rendered_home":"passed","offline_restart":"passed","same_release_reinstall":"passed","uninstall":"passed"}\n' > audit/result.json
