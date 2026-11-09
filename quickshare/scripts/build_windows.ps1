# Build on Windows with Flutter, Visual Studio C++ desktop tools and Inno Setup 6.
# Run from any directory: powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$project = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $project
$bundle = Join-Path $project 'build\windows\x64\runner\Release'
$dist = Join-Path $project 'dist\windows'
$zip = Join-Path $dist 'DirectDrop-windows-portable.zip'
$installer = Join-Path $dist 'DirectDrop-windows-setup.exe'

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}

try {
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        throw 'Flutter was not found on PATH.'
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'vswhere.exe was not found. Install Visual Studio with the Desktop development with C++ workload.'
    }
    $vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsPath) { throw 'No Visual Studio installation with C++ tools was found.' }
    $redistRoot = Join-Path $vsPath 'VC\Redist\MSVC'
    if (-not (Test-Path -LiteralPath $redistRoot -PathType Container)) {
        throw "MSVC redistributable was not found under $redistRoot. Install the Visual C++ redistributable component."
    }
    $crtDir = Get-ChildItem -LiteralPath $redistRoot -Recurse -Directory -Filter 'Microsoft.VC*.CRT' |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $crtDir) { throw "No x64 CRT redistributable directory was found under $redistRoot." }
    $iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    if (-not (Test-Path -LiteralPath $iscc -PathType Leaf)) {
        $isccCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        if (-not $isccCommand) { throw 'Inno Setup 6 ISCC.exe was not found. Install Inno Setup 6 or add it to PATH.' }
        $iscc = $isccCommand.Source
    }
    $versionLine = Get-Content -LiteralPath (Join-Path $project 'pubspec.yaml') |
        Where-Object { $_ -match '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?\s*$' } |
        Select-Object -First 1
    if (-not $versionLine) { throw 'Could not read a numeric version from pubspec.yaml.' }
    $null = $versionLine -match '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)'
    $version = $Matches[1]

    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    # Never package a previous build or report previous artifacts as new ones.
    foreach ($artifact in @($zip, $installer)) {
        if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Force }
    }
    if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }

    # package:jni can detect a local JDK and attempt to build a JNI shim that
    # this Windows app does not use. CMake's JNI setting does not cover the
    # package's native-assets hook, so hide JAVA_HOME for these commands only.
    $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $null, 'Process')
        Invoke-Checked 'flutter' @('pub', 'get')
        Invoke-Checked 'flutter' @('build', 'windows', '--release')
    } finally {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $javaHome, 'Process')
    }
    foreach ($required in @('directdrop.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $bundle $required) -PathType Leaf)) {
            throw "Build output is missing $required."
        }
    }
    $dlls = @(Get-ChildItem -LiteralPath $crtDir.FullName -Filter '*.dll' -File)
    foreach ($runtime in @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $crtDir.FullName $runtime) -PathType Leaf)) {
            throw "Required runtime DLL $runtime was not found in $($crtDir.FullName)."
        }
    }
    $dlls | Copy-Item -Destination $bundle -Force
    Write-Host "Bundled Visual C++ runtime from $($crtDir.FullName)"

    @'
DirectDrop portable build

Extract the entire archive and run directdrop.exe. Keep the executable, DLLs,
and data folder together. Windows may warn that this build is not signed.
'@ | Set-Content -LiteralPath (Join-Path $bundle 'README-PORTABLE.txt') -Encoding UTF8
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip -Force
    Invoke-Checked $iscc @("/DMyAppVersion=$version", (Join-Path $project 'packaging\windows\directdrop.iss'))
    foreach ($artifact in @($zip, $installer)) {
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf) -or (Get-Item -LiteralPath $artifact).Length -eq 0) {
            throw "Artifact was not created: $artifact"
        }
        Write-Host "Created: $artifact"
    }
} catch {
    Write-Error $_
    exit 1
}
