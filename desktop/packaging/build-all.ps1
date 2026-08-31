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

$AppVersion = '1.0.0'

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

    # These two DLLs are the reason the client could not connect.
    #
    # tunnel.cpp loads wireguard.dll (WireGuardNT, the kernel driver) and
    # tunnel.dll (WireGuard's embeddable tunnel service) at runtime. When
    # either is absent it returns driver_unavailable and the UI says
    # "WireGuard driver files are missing". Nothing in the pipeline ever
    # fetched tunnel.dll, and a missing file was only a warning, so every
    # build shipped a client that looked fine and could never bring a tunnel
    # up. Both are downloaded here, and a missing file is now fatal.
    $wgTemp = Join-Path $env:TEMP "glukvpn-wg-$PID"
    New-Item -ItemType Directory -Force -Path $wgTemp | Out-Null

    # ROUND 5: the two DLLs are a MATCHED PAIR. tunnel.dll speaks exactly one
    # wireguard.dll ABI. Round 4 shipped wireguard.dll from wireguard-nt-1.1.zip
    # next to a tunnel.dll built from git master, and the mismatch made
    # WireGuardTunnelService() bail out roughly a second after start, which the
    # service reported as tunnel_error. Take both from the same release zip.
    $paired = $false
    if (-not ((Test-Path (Join-Path $vendor 'tunnel.dll')) -and (Test-Path (Join-Path $vendor 'wireguard.dll')))) {
        $embedZip = Join-Path $wgTemp 'embeddable-dll-service.zip'
        $embedDir = Join-Path $wgTemp 'embeddable'
        foreach ($ver in @('0.5.3', '0.5.2', '0.4.9')) {
            try {
                Write-Note "Fetching matched tunnel.dll + wireguard.dll pair (embeddable-dll-service $ver)"
                Invoke-WebRequest -Uri "https://download.wireguard.com/windows-client/embeddable-dll-service-amd64-$ver.zip" -OutFile $embedZip -UseBasicParsing
                Expand-Archive -Path $embedZip -DestinationPath $embedDir -Force
                foreach ($dll in @('tunnel.dll', 'wireguard.dll')) {
                    $found = Get-ChildItem -Path $embedDir -Filter $dll -Recurse |
                        Sort-Object { if ($_.FullName -match 'amd64') { 0 } else { 1 } } |
                        Select-Object -First 1
                    if ($found) { Copy-Item $found.FullName $vendor -Force }
                }
                if (Test-Path (Join-Path $vendor 'tunnel.dll')) {
                    $paired = $true
                    Write-Note "  matched pair taken from release $ver"
                    break
                }
            } catch {
                Write-Note "  release $ver unavailable, trying an older one"
            }
        }
    } else {
        $paired = $true
    }

    if (-not (Test-Path (Join-Path $vendor 'wireguard.dll'))) {
        Write-Note 'Fetching wireguard.dll (WireGuardNT 1.1 fallback)'
        $ntZip = Join-Path $wgTemp 'wireguard-nt.zip'
        Invoke-WebRequest -Uri 'https://download.wireguard.com/wireguard-nt/wireguard-nt-1.1.zip' -OutFile $ntZip -UseBasicParsing
        Expand-Archive -Path $ntZip -DestinationPath (Join-Path $wgTemp 'wg-nt') -Force
        $ntDll = Get-ChildItem -Path (Join-Path $wgTemp 'wg-nt') -Filter 'wireguard.dll' -Recurse |
            Where-Object { $_.FullName -match 'amd64' } |
            Select-Object -First 1
        if (-not $ntDll) { throw 'wireguard.dll (amd64) was not found inside wireguard-nt-1.1.zip.' }
        Copy-Item $ntDll.FullName $vendor -Force
    }

    if (-not (Test-Path (Join-Path $vendor 'tunnel.dll'))) {
        Write-Note 'Building tunnel.dll from wireguard-windows (UNMATCHED fallback - may cause tunnel_start_failed)'
        $goCmd = Get-Command 'go' -ErrorAction SilentlyContinue
        if ($goCmd) {
            $wgWinDir = Join-Path $wgTemp 'wg-windows'
            git clone --depth 1 https://git.zx2c4.com/wireguard-windows $wgWinDir
            Push-Location (Join-Path $wgWinDir 'embeddable-dll-service')
            $env:CGO_ENABLED = "1"
            $env:GOOS = "windows"
            $env:GOARCH = "amd64"
            go build -buildmode=c-shared -ldflags="-w -s" -trimpath -o (Join-Path $vendor 'tunnel.dll') .
            Pop-Location
        }
    }

    Remove-Item $wgTemp -Recurse -Force -ErrorAction SilentlyContinue

    foreach ($dll in @('tunnel.dll', 'wireguard.dll')) {
        if (-not (Test-Path (Join-Path $vendor $dll))) {
            throw "$dll is missing from vendor\amd64 and could not be downloaded. Without it the client reports driver_unavailable and can never connect. See $vendor\README.md"
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
            if ($Channel -eq 'prod' -and -not $Internal) {
                # Public builds must not expose the BETA switch.
                $defines += '--dart-define=ALLOW_BETA_CHANNEL=false'
            }

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
    foreach ($dll in @('tunnel.dll', 'wireguard.dll')) {
        $source = Join-Path $serviceOut $dll
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
