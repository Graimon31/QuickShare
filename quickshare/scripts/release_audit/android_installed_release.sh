#!/usr/bin/env bash
set -euo pipefail
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
adb shell svc wifi disable
adb shell svc data disable
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
