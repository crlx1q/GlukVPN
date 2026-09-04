<#
.SYNOPSIS
    One-command build for GlukVPN Desktop (Windows).

.DESCRIPTION
    Builds the native tunnel service and the Flutter Windows app, then
    optionally produces an installer and/or a portable package.

    The Flutter app needs desktop-only dependencies, so this script swaps
    pubspec.desktop.yaml over pubspec.yaml for the duration of the build and
    always restores the Android pubspec in a finally block - even on Ctrl+C.
    Android builds are therefore never affected.

.PARAMETER Channel
    prod (api.gluk.tech) or beta (beta-api.gluk.tech). Default: prod.

.PARAMETER Internal
    Enables internal-only UI (MTU field, internal nodes, diagnostics).

.PARAMETER Installer
    Builds dist\GlukVPN-Setup-<version>.exe with Inno Setup.

.PARAMETER Portable
    Builds dist\GlukVPN-portable-<version>.zip.

.PARAMETER SingleFile
    Builds a self-extracting dist\GlukVPN-<version>-portable.exe (needs 7-Zip).

.PARAMETER Sign
    Authenticode certificate thumbprint. Signs every produced binary.

.EXAMPLE
    .\build-all.ps1 -Channel prod -Installer -MakeIcons
#>

[CmdletBinding()]
param(
    [ValidateSet('prod', 'beta')]
    [string]$Channel = 'prod',

    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [switch]$Internal,
    [switch]$Installer,
    [switch]$Portable,
    [switch]$SingleFile,
    [switch]$SkipNative,
    [switch]$SkipFlutter,
    [switch]$MakeIcons,
    [string]$Sign
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$PackagingDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot     = Resolve-Path (Join-Path $PackagingDir '..\..')
$FlutterDir   = Join-Path $RepoRoot 'flutter-client'
$NativeDir    = Join-Path $RepoRoot 'native\glukvpn-tunnel-service'
$DistDir      = Join-Path $RepoRoot 'dist'
$NativeBuild  = Join-Path $NativeDir 'build'

$AppVersion = '1.3.0'

function Write-Step($message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Magenta
}

function Write-Note($message) {
    Write-Host "    $message" -ForegroundColor DarkGray
}

function Assert-Tool($name, $hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name was not found on PATH. $hint"
    }
}

function Invoke-Sign($path) {
    if (-not $Sign) { return }

    Assert-Tool 'signtool' 'Install the Windows SDK.'
    Write-Note "Signing $(Split-Path -Leaf $path)"
    & signtool sign /sha1 $Sign /fd SHA256 /tr http://timestamp.digicert.com `
        /td SHA256 /q $path
    if ($LASTEXITCODE -ne 0) { throw "signtool failed for $path" }
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

Write-Host "GlukVPN Desktop build" -ForegroundColor Cyan
Write-Note "Channel       : $Channel"
Write-Note "Configuration : $Configuration"
Write-Note "Internal      : $($Internal.IsPresent)"
Write-Note "Repo          : $RepoRoot"

# ---------------------------------------------------------------------------
# Icons
# ---------------------------------------------------------------------------

if ($MakeIcons) {
    Write-Step 'Generating tray and app icons'
    & (Join-Path $PackagingDir 'make-icons.ps1')
}

# ---------------------------------------------------------------------------
# Native service
# ---------------------------------------------------------------------------

if (-not $SkipNative) {
    Write-Step 'Building the native tunnel service'
    Assert-Tool 'cmake' 'Install CMake 3.21+ or Visual Studio with the C++ workload.'

    $vendor = Join-Path $NativeDir 'vendor\amd64'
    New-Item -ItemType Directory -Force -Path $vendor | Out-Null

    # The tunnel needs exactly two artefacts next to the service, and both are
    # produced here. A missing one is fatal, never a warning.
    #
    # ROUND 7 - userspace WireGuard. tunnel.cpp used to load tunnel.dll from
    # wireguard-windows. That library is not a WireGuard implementation: it is
    # a launcher for the WireGuardNT kernel driver and installs the unsigned
    # wireguard.sys on first use. On a machine with Core Isolation / Memory
    # Integrity / WDAC the kernel refuses that driver, so the worker died with
    # ok=0, ran 1s. Shipping wintun.dll next to it changed nothing, because
    # tunnel.dll never asked for Wintun.
    #
    # The data plane is now our own Go program, native\...\go\glukvpn-wg:
    # wireguard-go speaking WireGuard in userspace on top of the WHQL-signed
    # wintun.dll. No kernel driver and no signing exception - the same design
    # Proton, Mullvad and Tailscale ship. It is a plain `go build` with cgo
    # off, so no mingw/gcc toolchain is needed on the build machine either.
    $wgTemp = Join-Path $env:TEMP "glukvpn-wg-$PID"
    New-Item -ItemType Directory -Force -Path $wgTemp | Out-Null

    # 1. wintun.dll is never optional: it *is* the adapter. 0.14.1 is the
    #    official WHQL-signed build and the exact file the commercial clients
    #    ship.
    if (-not (Test-Path (Join-Path $vendor 'wintun.dll'))) {
        Write-Note 'Fetching wintun.dll (Wintun 0.14.1, WHQL signed)'
        $wintunZip = Join-Path $wgTemp 'wintun.zip'
        Invoke-WebRequest -Uri 'https://www.wintun.net/builds/wintun-0.14.1.zip' -OutFile $wintunZip -UseBasicParsing
        Expand-Archive -Path $wintunZip -DestinationPath (Join-Path $wgTemp 'wintun') -Force
        $wintunDll = Get-ChildItem -Path (Join-Path $wgTemp 'wintun') -Filter 'wintun.dll' -Recurse |
            Where-Object { $_.FullName -match 'amd64' } |
            Select-Object -First 1
        if (-not $wintunDll) { throw 'wintun.dll (amd64) was not found inside wintun-0.14.1.zip.' }
        Copy-Item $wintunDll.FullName $vendor -Force
    }

    # 2. glukvpn-wg.exe - the data plane itself.
    $goSource = Join-Path $NativeDir 'go\glukvpn-wg'
    $workerExe = Join-Path $vendor 'glukvpn-wg.exe'
    if (-not (Get-Command 'go' -ErrorAction SilentlyContinue)) {
        throw 'Go 1.22+ is required to build the tunnel data plane (glukvpn-wg.exe). Install it from https://go.dev/dl/ and run this script again.'
    }
    Write-Note 'Building glukvpn-wg.exe (wireguard-go, userspace over Wintun)'
    Push-Location $goSource
    try {
        $env:CGO_ENABLED = "0"
        $env:GOOS = "windows"
        $env:GOARCH = "amd64"
        & go mod tidy
        if ($LASTEXITCODE -ne 0) { throw 'go mod tidy failed for the tunnel data plane.' }
        & go build -ldflags="-w -s" -trimpath -o $workerExe .
        if ($LASTEXITCODE -ne 0) { throw 'go build failed for the tunnel data plane.' }
    } finally {
        Pop-Location
    }

    # 3. sing-box.exe - the DPI-resistant data plane (round 24). Official
    #    release binary, unmodified: it owns the Wintun adapter, installs the
    #    routes itself through auto_route, and wraps the traffic in TLS so the
    #    provider cannot fingerprint a WireGuard header.
    $singbox = Join-Path $vendor 'sing-box.exe'
    if (-not (Test-Path $singbox)) {
        Write-Note 'Fetching sing-box.exe (latest official windows-amd64 release)'
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -like 'sing-box-*-windows-amd64.zip' } | Select-Object -First 1
        if (-not $asset) { throw 'The latest sing-box release has no windows-amd64 archive.' }
        $singboxZip = Join-Path $wgTemp 'sing-box.zip'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $singboxZip -UseBasicParsing
        Expand-Archive -Path $singboxZip -DestinationPath (Join-Path $wgTemp 'sing-box') -Force
        $found = Get-ChildItem -Path (Join-Path $wgTemp 'sing-box') -Filter 'sing-box.exe' -Recurse | Select-Object -First 1
        if (-not $found) { throw 'sing-box.exe was not found inside the release archive.' }
        Copy-Item $found.FullName $singbox -Force
        Write-Note "Vendored sing-box $($release.tag_name)"
    }

    Remove-Item $wgTemp -Recurse -Force -ErrorAction SilentlyContinue

    foreach ($artifact in @('glukvpn-wg.exe', 'wintun.dll', 'sing-box.exe')) {
        if (-not (Test-Path (Join-Path $vendor $artifact))) {
            throw "$artifact is missing from vendor\amd64 and could not be produced. Without it the client reports driver_unavailable and can never connect. See $vendor\README.md"
        }
    }

    & cmake -S $NativeDir -B $NativeBuild  `
        "-DGLUK_SERVICE_VERSION=$AppVersion"
    if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }

    & cmake --build $NativeBuild --config $Configuration
    if ($LASTEXITCODE -ne 0) { throw 'Native build failed.' }

    $serviceExe = Join-Path $NativeBuild "$Configuration\GlukVpnTunnelService.exe"
    if (-not (Test-Path $serviceExe)) { throw "Expected $serviceExe" }

    Invoke-Sign $serviceExe
    Write-Note "Built $serviceExe"
}

# ---------------------------------------------------------------------------
# Flutter app
# ---------------------------------------------------------------------------

if (-not $SkipFlutter) {
    Write-Step 'Building the Flutter Windows app'
    Assert-Tool 'flutter' 'Install the Flutter SDK 3.19+.'

    $pubspec        = Join-Path $FlutterDir 'pubspec.yaml'
    $desktopPubspec = Join-Path $FlutterDir 'pubspec.desktop.yaml'
    $backup         = Join-Path $FlutterDir 'pubspec.android.bak'

    if (-not (Test-Path $desktopPubspec)) { throw "Missing $desktopPubspec" }

    $swapped = $false
    try {
        # Swap in the desktop dependency set.
        Copy-Item $pubspec $backup -Force
        Copy-Item $desktopPubspec $pubspec -Force
        $swapped = $true
        Write-Note 'Swapped in pubspec.desktop.yaml'

        Push-Location $FlutterDir
        try {
            & flutter config --enable-windows-desktop | Out-Null

            & flutter pub get
            if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }

            $defines = @(
                "--dart-define=GLUK_CHANNEL=$Channel",
                "--dart-define=GLUK_INTERNAL=$($Internal.IsPresent.ToString().ToLower())"
            )
            # ROUND 12: beta stays compiled in, on every build.
            #
            # Public builds used to pass ALLOW_BETA_CHANNEL=false, and that is
            # why the PC appears to have no channel control: the switch is
            # drawn for an administrator, but AppConfig.setChannelOverride
            # refuses beta outright in such a build, so clicking it does
            # nothing and explains nothing.
            #
            # Deciding who may see the switch is the admin gate's job
            # (ChannelController.canSwitchAs), not the compiler's. A normal
            # user still never sees it, and the beta control plane refuses
            # non-admin accounts on its own, so shipping the capability
            # exposes nothing.

            $buildMode = if ($Configuration -eq 'Debug') { '--debug' } else { '--release' }

            & flutter build windows $buildMode --target lib\main_windows.dart @defines
            if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed.' }
        }
        finally {
            Pop-Location
        }
    }
    finally {
        # Always restore the Android pubspec, even on failure or Ctrl+C.
        if ($swapped -and (Test-Path $backup)) {
            Copy-Item $backup $pubspec -Force
            Remove-Item $backup -Force
            Write-Note 'Restored the Android pubspec.yaml'
        }
    }

    $runner = Join-Path $FlutterDir "build\windows\x64\runner\$Configuration"
    $appExe = Join-Path $runner 'glukvpn.exe'
    if (-not (Test-Path $appExe)) {
        # Older Flutter versions name the exe after the project.
        $candidate = Get-ChildItem $runner -Filter '*.exe' | Select-Object -First 1
        if ($candidate) {
            $appExe = $candidate.FullName
        } else {
            throw "No executable found in $runner"
        }
    }

    Invoke-Sign $appExe
    Write-Note "Built $appExe"
}

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------

$Stage = Join-Path $DistDir 'stage'
Write-Step 'Staging the payload'

if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage 'service') | Out-Null

$runnerDir = Join-Path $FlutterDir "build\windows\x64\runner\$Configuration"
if (Test-Path $runnerDir) {
    Copy-Item (Join-Path $runnerDir '*') $Stage -Recurse -Force
}

$serviceOut = Join-Path $NativeBuild $Configuration
if (Test-Path $serviceOut) {
    Copy-Item (Join-Path $serviceOut 'GlukVpnTunnelService.exe') `
        (Join-Path $Stage 'service') -Force
    foreach ($artifact in @('glukvpn-wg.exe', 'wintun.dll', 'sing-box.exe')) {
        $source = Join-Path $serviceOut $artifact
        if (Test-Path $source) {
            Copy-Item $source (Join-Path $Stage 'service') -Force
        }
    }
}

Write-Note "Staged in $Stage"

# ---------------------------------------------------------------------------
# Installer
# ---------------------------------------------------------------------------

if ($Installer) {
    Write-Step 'Building the installer'

    $iscc = Get-Command 'iscc' -ErrorAction SilentlyContinue
    if (-not $iscc) {
        $guess = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
        if (Test-Path $guess) {
            $iscc = $guess
        } else {
            throw 'Inno Setup 6 (ISCC.exe) was not found. Install it from https://jrsoftware.org/isdl.php'
        }
    } else {
        $iscc = $iscc.Source
    }

    & $iscc "/DAppVersion=$AppVersion" "/DStageDir=$Stage" `
        (Join-Path $PackagingDir 'installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed.' }

    $setup = Join-Path $DistDir "GlukVPN-Setup-$AppVersion.exe"
    Invoke-Sign $setup
    Write-Note "Installer: $setup"
}

# ---------------------------------------------------------------------------
# Portable
# ---------------------------------------------------------------------------

if ($Portable -or $SingleFile) {
    Write-Step 'Building the portable package'
    & (Join-Path $PackagingDir 'portable.ps1') `
        -StageDir $Stage -OutDir $DistDir -Version $AppVersion `
        -SingleFile:$SingleFile
}

Write-Host ""
Write-Host 'Build complete.' -ForegroundColor Green
Get-ChildItem $DistDir -File | ForEach-Object {
    Write-Host ("    {0,-42} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB))
}
