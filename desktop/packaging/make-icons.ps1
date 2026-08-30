<#
.SYNOPSIS
    Generates the tray and application icons for GlukVPN Desktop.

.DESCRIPTION
    TrayController loads assets\tray\{off,connecting,on,error}.ico, one per
    connection phase. This script draws them from the GlukVPN palette using
    System.Drawing, so the build has no external image dependency.

    Each .ico contains 32, 24, 20 and 16 pixel frames so Windows picks a crisp
    one at any DPI.

    assets\app.ico is generated from assets\logo.png when that file exists,
    otherwise from the same vector-ish drawing routine.
#>

[CmdletBinding()]
param(
    [string]$AssetsDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing

$PackagingDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot     = Resolve-Path (Join-Path $PackagingDir '..\..')

if (-not $AssetsDir) {
    $AssetsDir = Join-Path $RepoRoot 'flutter-client\assets'
}
$TrayDir = Join-Path $AssetsDir 'tray'

New-Item -ItemType Directory -Force -Path $TrayDir | Out-Null

# GlukVPN palette, matching lib/theme/tokens.dart.
$Phases = @(
    @{ Name = 'off';        Color = '#8B5CF6'; Glow = '#6D4DE0' }  # violet idle
    @{ Name = 'connecting'; Color = '#F0B567'; Glow = '#8B5CF6' }  # amber
    @{ Name = 'on';         Color = '#3DDC97'; Glow = '#8B5CF6' }  # green
    @{ Name = 'error';      Color = '#FF6B6B'; Glow = '#6D4DE0' }  # danger
)

$Sizes = @(32, 24, 20, 16)

function ConvertFrom-Hex([string]$hex) {
    $hex = $hex.TrimStart('#')
    return [System.Drawing.Color]::FromArgb(
        255,
        [Convert]::ToInt32($hex.Substring(0, 2), 16),
        [Convert]::ToInt32($hex.Substring(2, 2), 16),
        [Convert]::ToInt32($hex.Substring(4, 2), 16)
    )
}

# Draws the GlukVPN mark: a ring with a vertical power stroke, tinted per phase.
function New-PhaseBitmap([int]$size, [System.Drawing.Color]$color, [System.Drawing.Color]$glow) {
    $bitmap = New-Object System.Drawing.Bitmap($size, $size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $pad       = [Math]::Max(1, [int]($size * 0.12))
        $diameter  = $size - ($pad * 2)
        $thickness = [Math]::Max(1.5, $size * 0.13)

        # Soft halo so the icon reads on both light and dark taskbars.
        $haloColor = [System.Drawing.Color]::FromArgb(70, $glow.R, $glow.G, $glow.B)
        $haloBrush = New-Object System.Drawing.SolidBrush($haloColor)
        $g.FillEllipse($haloBrush, 0, 0, $size - 1, $size - 1)
        $haloBrush.Dispose()

        # Open ring, gap at the top for the power stroke.
        $pen = New-Object System.Drawing.Pen($color, $thickness)
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        $g.DrawArc($pen, $pad, $pad, $diameter, $diameter, -60, 300)

        # Vertical stroke.
        $centreX = $size / 2.0
        $top     = $pad * 0.55
        $bottom  = $size / 2.0 - ($size * 0.04)
        $g.DrawLine($pen, $centreX, $top, $centreX, $bottom)
        $pen.Dispose()
    }
    finally {
        $g.Dispose()
    }
    return $bitmap
}

# Writes a multi-resolution .ico by hand; System.Drawing cannot do it directly.
function Save-Icon([System.Drawing.Bitmap[]]$frames, [string]$path) {
    $pngs = @()
    foreach ($frame in $frames) {
        $stream = New-Object System.IO.MemoryStream
        $frame.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs += , $stream.ToArray()
        $stream.Dispose()
    }

    $file = [System.IO.File]::Create($path)
    $writer = New-Object System.IO.BinaryWriter($file)
    try {
        # ICONDIR
        $writer.Write([UInt16]0)                # reserved
        $writer.Write([UInt16]1)                # type: icon
        $writer.Write([UInt16]$frames.Count)    # image count

        $offset = 6 + (16 * $frames.Count)
        for ($i = 0; $i -lt $frames.Count; $i++) {
            $width  = $frames[$i].Width
            $height = $frames[$i].Height

            # ICONDIRENTRY. 0 means 256 in the icon format.
            $writer.Write([Byte](if ($width  -ge 256) { 0 } else { $width }))
            $writer.Write([Byte](if ($height -ge 256) { 0 } else { $height }))
            $writer.Write([Byte]0)              # palette
            $writer.Write([Byte]0)              # reserved
            $writer.Write([UInt16]1)            # colour planes
            $writer.Write([UInt16]32)           # bits per pixel
            $writer.Write([UInt32]$pngs[$i].Length)
            $writer.Write([UInt32]$offset)

            $offset += $pngs[$i].Length
        }

        foreach ($png in $pngs) {
            $writer.Write($png)
        }
    }
    finally {
        $writer.Dispose()
        $file.Dispose()
    }
}

Write-Host 'Generating tray icons' -ForegroundColor Cyan

foreach ($phase in $Phases) {
    $color = ConvertFrom-Hex $phase.Color
    $glow  = ConvertFrom-Hex $phase.Glow

    $frames = @()
    foreach ($size in $Sizes) {
        $frames += , (New-PhaseBitmap -size $size -color $color -glow $glow)
    }

    $target = Join-Path $TrayDir "$($phase.Name).ico"
    Save-Icon -frames $frames -path $target
    foreach ($frame in $frames) { $frame.Dispose() }

    Write-Host "    $target" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Application icon
# ---------------------------------------------------------------------------

$appIcon = Join-Path $AssetsDir 'app.ico'
$logoPng = Join-Path $AssetsDir 'logo.png'

if (Test-Path $logoPng) {
    Write-Host 'Generating app.ico from logo.png' -ForegroundColor Cyan
    $source = [System.Drawing.Image]::FromFile($logoPng)
    try {
        $frames = @()
        foreach ($size in @(256, 128, 64, 48, 32, 16)) {
            $bitmap = New-Object System.Drawing.Bitmap($size, $size,
                [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $g.InterpolationMode =
                    [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.DrawImage($source, 0, 0, $size, $size)
            }
            finally {
                $g.Dispose()
            }
            $frames += , $bitmap
        }

        Save-Icon -frames $frames -path $appIcon
        foreach ($frame in $frames) { $frame.Dispose() }
    }
    finally {
        $source.Dispose()
    }
} else {
    Write-Warning "logo.png not found; drawing a fallback app.ico"
    $color = ConvertFrom-Hex '#8B5CF6'
    $glow  = ConvertFrom-Hex '#6D4DE0'

    $frames = @()
    foreach ($size in @(256, 128, 64, 48, 32, 16)) {
        $frames += , (New-PhaseBitmap -size $size -color $color -glow $glow)
    }
    Save-Icon -frames $frames -path $appIcon
    foreach ($frame in $frames) { $frame.Dispose() }
}

Write-Host "    $appIcon" -ForegroundColor DarkGray
Write-Host 'Icons generated.' -ForegroundColor Green
