#!/usr/bin/env bash
set -e

echo "=========================================="
echo " QuickShare Windows Cross-Build Automation"
echo "=========================================="

echo "[+] Fetching Flutter packages..."
flutter pub get

echo "[+] Compiling Release binary..."
flutter build windows --release --obfuscate --split-debug-info=build/debug-info

DIST_DIR="../dist"
WIN_DIST_DIR="$DIST_DIR/windows"
BUNDLE_DIR="build/windows/x64/runner/Release"

mkdir -p "$WIN_DIST_DIR"

if [ -d "$BUNDLE_DIR" ]; then
    echo "[+] Copying files to $WIN_DIST_DIR..."
    cp -r "$BUNDLE_DIR"/* "$WIN_DIST_DIR/"
    echo "SUCCESS: Windows build ready at $WIN_DIST_DIR"
else
    echo "ERROR: Release directory $BUNDLE_DIR not found!"
    exit 1
fi
