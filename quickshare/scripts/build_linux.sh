#!/usr/bin/env bash
set -e

echo "=========================================="
echo " QuickShare Linux Build Script (Portable) "
echo "=========================================="

# 1. System Dependencies Check / Installation
if command -v apt-get &> /dev/null; then
    echo "[+] Verifying Debian/Ubuntu system packages..."
    sudo apt-get update
    sudo apt-get install -y \
        clang \
        cmake \
        ninja-build \
        pkg-config \
        libgtk-3-dev \
        liblzma-dev \
        libstdc++-12-dev
fi

# 2. Fetch dependencies
echo "[+] Fetching Flutter packages..."
flutter pub get

# 3. Optimized Release Build with symbol stripping
echo "[+] Compiling Release binary with size optimization & symbol stripping..."
flutter build linux --release --obfuscate --split-debug-info=build/debug-info

# 4. Packaging into ./dist/linux/
DIST_DIR="../dist"
LINUX_DIST_DIR="$DIST_DIR/linux"
BUNDLE_DIR="build/linux/x64/release/bundle"

mkdir -p "$LINUX_DIST_DIR"

if [ -d "$BUNDLE_DIR" ]; then
    echo "[+] Generating Portable launcher scripts..."
    
    # Executable AppRun wrapper script
    cat << 'EOF' > "$BUNDLE_DIR/QuickShare.AppRun"
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/lib:$LD_LIBRARY_PATH"
exec "$HERE/quickshare" "$@"
EOF
    chmod +x "$BUNDLE_DIR/QuickShare.AppRun"
    chmod +x "$BUNDLE_DIR/quickshare"

    # Portable Readme
    cat << 'EOF' > "$BUNDLE_DIR/README-PORTABLE.txt"
QuickShare Linux Portable (Standalone)
=======================================
No installation required!

Run options:
  - Double-click 'QuickShare.AppRun'
  - Or in terminal: ./QuickShare.AppRun or ./quickshare
EOF

    # Copy files to dist/linux/
    cp -r "$BUNDLE_DIR"/* "$LINUX_DIST_DIR/"
    
    # Strip symbols from final binary if strip is available
    if command -v strip &> /dev/null; then
        echo "[+] Stripping unneeded symbols from binary..."
        strip --strip-unneeded "$LINUX_DIST_DIR/quickshare" || true
    fi

    # Compress archive into dist/
    ARCHIVE_PATH="$DIST_DIR/quickshare-portable-linux-x64.tar.gz"
    echo "[+] Creating release tarball at $ARCHIVE_PATH..."
    tar -czvf "$ARCHIVE_PATH" -C "$LINUX_DIST_DIR" .

    echo "=========================================="
    echo " SUCCESS: Linux artifact created at:"
    echo "  - Executable folder: $LINUX_DIST_DIR"
    echo "  - Portable Tarball:  $ARCHIVE_PATH"
    echo "=========================================="
else
    echo "[-] ERROR: Build bundle directory $BUNDLE_DIR not found!"
    exit 1
fi
