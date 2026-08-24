# GlukVPN — обновление папки site/ из скачанного zip (без Python)
# Запуск из корня репозитория:
#   powershell -ExecutionPolicy Bypass -File .\update-site.ps1
# Можно указать конкретный архив:
#   powershell -ExecutionPolicy Bypass -File .\update-site.ps1 -Zip C:\Users\alish\Downloads\gluk-site.zip

param(
  [string]$Zip = "",
  [string]$Repo = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

if (-not $Zip) {
  $found = Get-ChildItem (Join-Path $env:USERPROFILE "Downloads") -Filter "gluk-site*.zip" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($found) { $Zip = $found.FullName }
}
if (-not $Zip -or -not (Test-Path $Zip)) {
  Write-Error "Не найден gluk-site*.zip в папке Downloads. Укажите путь через -Zip"
  exit 1
}

Write-Host "Архив : $Zip"
$tmp = Join-Path $env:TEMP ("gluk_site_" + [Guid]::NewGuid().ToString("N"))
Expand-Archive -Path $Zip -DestinationPath $tmp -Force

$src = Join-Path $tmp "site"
if (-not (Test-Path $src)) { $src = $tmp }
$dst = Join-Path $Repo "site"

if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
Copy-Item $src $dst -Recurse -Force
Remove-Item $tmp -Recurse -Force

$ver = Get-Content (Join-Path $dst "VERSION") -ErrorAction SilentlyContinue
$cnt = (Get-ChildItem $dst -Recurse -File).Count
Write-Host "Готово: $dst"
Write-Host "Версия : $ver"
Write-Host "Файлов : $cnt"
Write-Host ""
Write-Host "Дальше:"
Write-Host "  git add site"
Write-Host "  git commit -m \"site: 0.5.0 beta\""
Write-Host "  git push origin beta"
