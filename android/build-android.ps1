<#
.SYNOPSIS
    Builds the Android APK from your own Skate 3 dump, end to end.

.DESCRIPTION
    Generates CMakeUserPresets.json from the paths you pass, runs the code
    generator and cross-compiles for arm64, then packages the APK.

    Nothing here ships game code: the recompiled library is produced on your
    machine, from your dump, and never leaves it.

.PARAMETER GameData
    Folder holding default.xex and default.xexp from your copy of the game.

.PARAMETER TitleUpdate
    Title Update 3 package (TU_12K2276_...). REQUIRED: without it the code
    generator leaves unresolved calls and the link fails.

.PARAMETER Ndk
    Android NDK r29 root. Auto-detected under %LOCALAPPDATA%\Android\Sdk\ndk
    when omitted.

.PARAMETER Jobs
    Parallel compile jobs. Keep this low (default 4): the code generator's LLVM
    passes are memory-hungry and higher values have run machines out of RAM.

.PARAMETER Install
    After building, install onto the connected device via adb.

.PARAMETER PushGameData
    With -Install, also copy GameData to /sdcard/skate3/game (several GB, slow)
    and grant the storage permission.

.EXAMPLE
    .\build-android.ps1 -GameData D:\skate3\game -TitleUpdate D:\skate3\TU_12K2276_000000C000000.00000000000O3

.EXAMPLE
    .\build-android.ps1 -GameData D:\skate3\game -TitleUpdate D:\skate3\TU3 -Install -PushGameData
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GameData,
    [Parameter(Mandatory = $true)][string]$TitleUpdate,
    [string]$Ndk,
    [int]$Jobs = 4,
    [switch]$Install,
    [switch]$PushGameData
)

# NOT 'Stop': in Windows PowerShell every line a native tool writes to stderr
# becomes an error record, and 'Stop' would abort the build on a harmless CMake
# deprecation warning. Success is judged by $LASTEXITCODE after each call, and
# by checking that the expected files exist.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot   # repository root
$preset = 'android-arm64'

function Fail($message) { Write-Host "ERROR: $message" -ForegroundColor Red; exit 1 }
function Step($message) { Write-Host "`n==> $message" -ForegroundColor Cyan }

# ---- Inputs ---------------------------------------------------------------
Step 'Checking your game files'

# Plain Test-Path/Resolve-Path rather than ?. so this runs on the Windows
# PowerShell 5.1 that ships with Windows.
if (-not (Test-Path -LiteralPath $GameData)) { Fail "GameData folder not found: $GameData" }
$GameData = (Resolve-Path -LiteralPath $GameData).Path
foreach ($needed in 'default.xex', 'default.xexp') {
    if (-not (Test-Path -LiteralPath (Join-Path $GameData $needed))) {
        Fail "$needed is missing from $GameData. Both are required."
    }
}

if (-not (Test-Path -LiteralPath $TitleUpdate)) {
    Fail "Title Update package not found: $TitleUpdate`nTU3 is required - without it the generated code has unresolved calls and will not link."
}
$TitleUpdate = (Resolve-Path -LiteralPath $TitleUpdate).Path
Write-Host "  game data:    $GameData"
Write-Host "  title update: $TitleUpdate"

# ---- Toolchain ------------------------------------------------------------
Step 'Locating the toolchain'

if (-not $Ndk) {
    $ndkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk\ndk'
    if (Test-Path $ndkRoot) {
        # Highest installed version wins; r29 is what this port is built with.
        $Ndk = (Get-ChildItem $ndkRoot -Directory | Sort-Object Name -Descending |
                Select-Object -First 1).FullName
    }
}
if (-not $Ndk -or -not (Test-Path -LiteralPath $Ndk)) {
    Fail 'Android NDK not found. Install NDK r29 or pass -Ndk <path>.'
}
$toolchain = Join-Path $Ndk 'build\cmake\android.toolchain.cmake'
if (-not (Test-Path -LiteralPath $toolchain)) { Fail "No android.toolchain.cmake under $Ndk." }

foreach ($exe in 'cmake', 'ninja') {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { Fail "$exe is not on PATH." }
}
Write-Host "  ndk:   $Ndk"
Write-Host "  cmake: $((Get-Command cmake).Source)"

# ---- Preset ---------------------------------------------------------------
# CMakeUserPresets.json is per-machine (and git-ignored), so it is generated
# rather than committed.
Step 'Writing CMakeUserPresets.json'

$toJson = { param($p) $p -replace '\\', '/' }
@{
    version               = 6
    cmakeMinimumRequired  = @{ major = 3; minor = 25; patch = 0 }
    configurePresets      = @(@{
            name          = $preset
            displayName   = 'Skate 3 Android arm64-v8a'
            generator     = 'Ninja'
            binaryDir     = '${sourceDir}/out/build/android-arm64'
            toolchainFile = (& $toJson $toolchain)
            cacheVariables = @{
                ANDROID_ABI                 = 'arm64-v8a'
                ANDROID_PLATFORM            = 'android-26'
                CMAKE_BUILD_TYPE            = 'RelWithDebInfo'
                CMAKE_CXX_STANDARD          = '23'
                SKATE3_GAME_DATA_ROOT       = (& $toJson $GameData)
                SKATE3_TITLE_UPDATE_PACKAGE = (& $toJson $TitleUpdate)
            }
        })
    buildPresets          = @(@{ name = $preset; configurePreset = $preset })
} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root 'CMakeUserPresets.json') -Encoding UTF8

# ---- Build ----------------------------------------------------------------
Step 'Configuring (first run also generates the recompiled sources - this is slow)'
Push-Location $root
try {
    cmake --preset $preset
    if ($LASTEXITCODE -ne 0) { Fail 'CMake configure failed.' }

    Step "Building with -j $Jobs"
    cmake --build "out/build/$preset" --target skate3 -j $Jobs
    if ($LASTEXITCODE -ne 0) {
        Fail 'Build failed. If the compiler was killed, retry with a lower -Jobs: the code generator needs a lot of RAM per job.'
    }

    Step 'Staging the native libraries into the APK'
    $jni = Join-Path $root 'android\app\src\main\jniLibs\arm64-v8a'
    New-Item -ItemType Directory -Force -Path $jni | Out-Null
    foreach ($lib in 'librexruntimerd.so', 'libskate3.so') {
        $built = Join-Path $root "out\build\$preset\$lib"
        if (-not (Test-Path -LiteralPath $built)) { Fail "$lib was not produced." }
        Copy-Item -LiteralPath $built -Destination $jni -Force
    }

    Step 'Packaging the APK'
    Push-Location (Join-Path $root 'android')
    try {
        & .\gradlew.bat assembleDebug
        if ($LASTEXITCODE -ne 0) { Fail 'Gradle failed.' }
    } finally { Pop-Location }
} finally { Pop-Location }

$apk = Join-Path $root 'android\app\build\outputs\apk\debug\app-debug.apk'
if (-not (Test-Path -LiteralPath $apk)) { Fail 'No APK was produced.' }
Write-Host "`nAPK: $apk" -ForegroundColor Green
Write-Host 'It contains YOUR recompiled game. Do not redistribute it.' -ForegroundColor Yellow

# ---- Optional device steps ------------------------------------------------
if ($Install) {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { Fail 'adb is not on PATH.' }

    Step 'Installing'
    adb install -r -d $apk
    if ($LASTEXITCODE -ne 0) { Fail 'Install failed - check that a device is connected and authorised.' }

    if ($PushGameData) {
        # A public folder on purpose: from Android 11 on, adb push cannot write
        # into Android/data, so the app reads the game from here instead.
        Step 'Copying the game data (several GB - this takes a while)'
        adb shell mkdir -p /sdcard/skate3/game
        adb push "$GameData/." /sdcard/skate3/game/
        if ($LASTEXITCODE -ne 0) { Fail 'Copy failed - check free space on the device.' }

        $config = Join-Path $root 'config\skate3.android.toml'
        if (Test-Path -LiteralPath $config) { adb push $config /sdcard/skate3/skate3.toml }

        # No-op below Android 11, where the permission does not exist.
        adb shell appops set com.skate3recomp MANAGE_EXTERNAL_STORAGE allow 2>$null | Out-Null
    }

    Write-Host "`nDone. Launch Skate 3 on the device." -ForegroundColor Green
    Write-Host 'First launch is slow: shaders are compiled up front on purpose.'
}
