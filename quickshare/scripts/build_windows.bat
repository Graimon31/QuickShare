@echo off
echo ============================================
echo  QuickShare Windows Build Script (Portable) 
echo ============================================

echo [+] Fetching Flutter packages...
call flutter pub get

echo [+] Compiling Release binary with size optimization & symbol stripping...
call flutter build windows --release --obfuscate --split-debug-info=build\debug-info

set DIST_DIR=..\dist
set WIN_DIST_DIR=%DIST_DIR%\windows
set BUNDLE_DIR=build\windows\x64\runner\Release

if not exist "%WIN_DIST_DIR%" mkdir "%WIN_DIST_DIR%"

if exist "%BUNDLE_DIR%" (
    echo [+] Creating Portable helper launcher & metadata...
    
    (
        echo @echo off
        echo start "" "%%~dp0quickshare.exe" %%*
    ) > "%BUNDLE_DIR%\QuickShare-Portable.bat"

    (
        echo QuickShare Windows Portable (Standalone^)
        echo ==========================================
        echo.
        echo No installation required!
        echo.
        echo Run options:
        echo   - Double-click "quickshare.exe"
        echo   - Or double-click "QuickShare-Portable.bat"
    ) > "%BUNDLE_DIR%\README-PORTABLE.txt"

    echo [+] Copying bundle files to %WIN_DIST_DIR%...
    xcopy /E /Y /I "%BUNDLE_DIR%\*" "%WIN_DIST_DIR%\" >nul

    echo [+] Packaging Portable Windows release ZIP...
    powershell -Command "Compress-Archive -Path '%WIN_DIST_DIR%\*' -DestinationPath '%DIST_DIR%\quickshare-portable-windows-x64.zip' -Force"

    echo ============================================
    echo  SUCCESS: Windows artifact created at:
    echo   - Executable folder: %WIN_DIST_DIR%
    echo   - Portable Zip:      %DIST_DIR%\quickshare-portable-windows-x64.zip
    echo ============================================
) else (
    echo [-] ERROR: Build directory %BUNDLE_DIR% not found!
    exit /b 1
)
