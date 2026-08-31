<#
.SYNOPSIS
    Generates the GlukVPN Windows icon set from the app logo.

.DESCRIPTION
    Produces five .ico files:

      flutter-client/assets/app.ico          installer + exe + window icon
      flutter-client/assets/tray/off.ico     idle          violet glow
      flutter-client/assets/tray/connecting.ico  coming up  amber  glow
      flutter-client/assets/tray/on.ico      verified up   green  glow
      flutter-client/assets/tray/error.ico   failed        red    glow

    All four tray icons are the real logo, not an abstract shape, with a
    state-coloured halo and a small status dot in the bottom-right corner so the
    state is readable at 16 px on both light and dark taskbars.

    Each .ico embeds PNG frames (Vista+ format) at several sizes, so Windows
    picks a crisp one for the tray, the taskbar, Alt+Tab and the Programs list.

.PARAMETER Logo
    Source artwork. Defaults to flutter-client/assets/logo.png.

.PARAMETER KeepExisting
    Leave icons that already exist alone. By default every icon is rebuilt from
    the logo, because refreshing them is the entire point of running this
    script - keeping stale files is exactly how a placeholder power glyph
    survived in the tray instead of the GlukVPN logo.

.PARAMETER Force
    Kept for compatibility. Regenerating is now the default.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File desktop\packaging\make-icons.ps1 -Force
#>

[CmdletBinding()]
param(
    [string]$Logo,
    [switch]$Force,
    [switch]$KeepExisting
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$assets = Join-Path $repoRoot 'flutter-client\assets'
$trayDir = Join-Path $assets 'tray'

if (-not $Logo) { $Logo = Join-Path $assets 'logo.png' }

if (-not (Test-Path $Logo)) {
    Write-Warning "Logo not found at $Logo - icons cannot be generated."
    Write-Warning 'Drop the artwork in flutter-client/assets/logo.png and re-run.'
    exit 1
}

New-Item -ItemType Directory -Force -Path $trayDir | Out-Null

# State palette. Matches GlukColors in lib/theme/tokens.dart so the tray icon,
# the connect button and the status pill always agree.
$states = @(
    @{ Name = 'off';        R = 139; G = 92;  B = 246 }  # violet  #8B5CF6
    @{ Name = 'connecting'; R = 240; G = 181; B = 103 }  # amber   #F0B567
    @{ Name = 'on';         R = 61;  G = 220; B = 151 }  # green   #3DDC97
    @{ Name = 'error';      R = 255; G = 107; B = 107 }  # red     #FF6B6B
)

# Tray icons are only ever drawn small; the app icon needs the large frames.
$traySizes = @(16, 20, 24, 32, 40, 48)
$appSizes = @(16, 20, 24, 32, 48, 64, 128, 256)

$source = [System.Drawing.Image]::FromFile($Logo)

function New-Frame {
    param(
        [int]$Size,
        [System.Drawing.Image]$Image,
        $State,
        [bool]$WithGlow,
        [bool]$WithHalo = $false
    )

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode =
            [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode =
            [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)

        # ROUND 5: no halo on the tray icon any more. The user asked for the
        # plain logo with just the coloured lamp, and the glow was eating about
        # a quarter of a 16 px icon, which is exactly why it looked small.
        # Kept behind a switch in case a future variant wants it back.
        if ($WithHalo) {
            # Soft halo: concentric translucent rings, cheap and dependable
            # across every .NET version shipped with Windows.
            $rings = [Math]::Max(4, [int]($Size / 5))
            for ($i = $rings; $i -ge 1; $i--) {
                $t = $i / $rings
                $alpha = [int](46 * $t * $t)
                if ($alpha -le 0) { continue }
                $colour = [System.Drawing.Color]::FromArgb(
                    $alpha, $State.R, $State.G, $State.B)
                $brush = New-Object System.Drawing.SolidBrush($colour)
                $inset = ($Size * 0.5) * (1.0 - $t)
                $g.FillEllipse($brush, $inset, $inset,
                    $Size - (2 * $inset), $Size - (2 * $inset))
                $brush.Dispose()
            }
        }

        # Logo, centred, with rounded corners.
        #
        # Two separate complaints are fixed here. The artwork is a square tile,
        # so Windows drew a hard square in the tray, on the taskbar and in the
        # Programs list; it is now clipped to a rounded square like every other
        # modern Windows app icon. And the tray frame used to nudge the logo up
        # and left by 4% to clear the status dot, which is exactly what made the
        # small icon look glued into a corner - the logo is centred now and the
        # dot simply overlaps it.
        # Tray: 0.98 instead of 0.74. With the halo gone the logo can use
        # almost the whole frame, which is what "make it bigger" means at 16 px.
        $scale = if ($WithGlow) { 0.98 } else { 0.94 }
        $side = [int]($Size * $scale)
        $offset = [double](($Size - $side) / 2.0)
        $radius = [double]([Math]::Max(2.0, $side * 0.28))
        $arc = $radius * 2.0

        $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
        $clip.AddArc($offset, $offset, $arc, $arc, 180, 90)
        $clip.AddArc(($offset + $side - $arc), $offset, $arc, $arc, 270, 90)
        $clip.AddArc(($offset + $side - $arc), ($offset + $side - $arc), $arc, $arc, 0, 90)
        $clip.AddArc($offset, ($offset + $side - $arc), $arc, $arc, 90, 90)
        $clip.CloseFigure()

        $gsave = $g.Save()
        $g.SetClip($clip)
        $g.DrawImage($Image, $offset, $offset, [double]$side, [double]$side)
        $g.Restore($gsave)
        $clip.Dispose()

        if ($WithGlow) {
            # Status dot. At 16 px the halo alone is hard to read, this is not.
            $dot = [Math]::Max(5, [int]($Size * 0.28))
            $dx = $Size - $dot - [Math]::Max(0, [int]($Size * 0.03))
            $dy = $Size - $dot - [Math]::Max(0, [int]($Size * 0.03))

            # Dark outline keeps the dot visible on a light taskbar.
            $ring = New-Object System.Drawing.SolidBrush(
                [System.Drawing.Color]::FromArgb(215, 8, 6, 14))
            $g.FillEllipse($ring, $dx - 1, $dy - 1, $dot + 2, $dot + 2)
            $ring.Dispose()

            $fill = New-Object System.Drawing.SolidBrush(
                [System.Drawing.Color]::FromArgb(255, $State.R, $State.G, $State.B))
            $g.FillEllipse($fill, $dx, $dy, $dot, $dot)
            $fill.Dispose()
        }
    }
    finally {
        $g.Dispose()
    }

    return $bmp
}

function Save-Ico {
    param(
        [string]$Path,
        [int[]]$Sizes,
        [System.Drawing.Image]$Image,
        $State,
        [bool]$WithGlow
    )

    $frames = @()
    foreach ($size in $Sizes) {
        $bmp = New-Frame -Size $size -Image $Image -State $State -WithGlow $WithGlow
        $stream = New-Object System.IO.MemoryStream
        $bmp.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $frames += [pscustomobject]@{ Size = $size; Bytes = $stream.ToArray() }
        $stream.Dispose()
    }

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        # ICONDIR
        $bw.Write([UInt16]0)                  # reserved
        $bw.Write([UInt16]1)                  # type: 1 = icon
        $bw.Write([UInt16]$frames.Count)

        # Image data starts after the directory.
        $offset = 6 + (16 * $frames.Count)
        foreach ($frame in $frames) {
            $dim = if ($frame.Size -ge 256) { 0 } else { $frame.Size }
            $bw.Write([Byte]$dim)             # width  (0 means 256)
            $bw.Write([Byte]$dim)             # height
            $bw.Write([Byte]0)                # palette entries
            $bw.Write([Byte]0)                # reserved
            $bw.Write([UInt16]1)              # colour planes
            $bw.Write([UInt16]32)             # bits per pixel
            $bw.Write([UInt32]$frame.Bytes.Length)
            $bw.Write([UInt32]$offset)
            $offset += $frame.Bytes.Length
        }

        foreach ($frame in $frames) {
            $bw.Write($frame.Bytes)
        }
    }
    finally {
        $bw.Dispose()
        $fs.Dispose()
    }

    $kb = [Math]::Round((Get-Item $Path).Length / 1KB, 1)
    Write-Host ("  {0,-42} {1} KB" -f (Split-Path $Path -Leaf), $kb)
}

try {
    Write-Host 'GlukVPN icon set'
    Write-Host "  source: $Logo"

    $appIco = Join-Path $assets 'app.ico'
    if ((Test-Path $appIco) -and $KeepExisting -and -not $Force) {
        Write-Host '  app.ico exists, kept (-KeepExisting)'
    }
    else {
        Save-Ico -Path $appIco -Sizes $appSizes -Image $source `
            -State $states[0] -WithGlow $false
    }

    foreach ($state in $states) {
        $path = Join-Path $trayDir ("{0}.ico" -f $state.Name)
        if ((Test-Path $path) -and $KeepExisting -and -not $Force) {
            Write-Host ("  {0}.ico exists, kept" -f $state.Name)
            continue
        }
        Save-Ico -Path $path -Sizes $traySizes -Image $source `
            -State $state -WithGlow $true
    }

    Write-Host 'Done.'
}
finally {
    $source.Dispose()
}
