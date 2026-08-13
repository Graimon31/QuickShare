#!/usr/bin/env python3
import subprocess
import time
import json
import base64

def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

print("1. Activating macOS quickshare.app...")
run("osascript -e 'tell application \"quickshare\" to activate'")
time.sleep(1)

print("2. Activating Android Emulator...")
run("~/Library/Android/sdk/platform-tools/adb shell am force-stop com.yourorg.quickshare")
time.sleep(0.5)
run("~/Library/Android/sdk/platform-tools/adb shell am start -n com.yourorg.quickshare/.MainActivity")
time.sleep(2)

print("3. Tapping 'Receive File' on Android Emulator...")
run("~/Library/Android/sdk/platform-tools/adb shell input tap 810 700")
time.sleep(1.5)

# Generate valid QR Payload code
# {"v":1,"ip":"10.0.2.2","p":8090,"t":"live_demo_token","fn":"mac_to_android_demo.txt","fs":1024,"cs":""}
payload_dict = {
    "v": 1,
    "ip": "10.0.2.2",
    "p": 8090,
    "t": "live_demo_token",
    "fn": "mac_to_android_demo.txt",
    "fs": 1024,
    "cs": ""
}
json_str = json.dumps(payload_dict)
b64_code = base64.b64encode(json_str.encode()).decode().rstrip("=")

print(f"4. Entering share code on Android emulator: {b64_code}")
# Tap text field
run("~/Library/Android/sdk/platform-tools/adb shell input tap 540 750")
time.sleep(0.5)

# Type code
run(f"~/Library/Android/sdk/platform-tools/adb shell input text {b64_code}")
time.sleep(1)

# Tap Submit
run("~/Library/Android/sdk/platform-tools/adb shell input tap 540 950")
print("5. Live GUI interaction complete!")
