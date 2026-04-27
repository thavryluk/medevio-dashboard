# Deploy na Fly.io s automatickym embedovanim verze a datumu buildu.
# Spust z root slozky projektu.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$fly = "$env:USERPROFILE\.fly\bin\flyctl.exe"
if (-not (Test-Path $fly)) { Write-Host "ERR: flyctl chybi - spust setup-new-pc.ps1"; exit 1 }

$version = (git rev-parse --short HEAD).Trim()
$dirty = if ((git status --porcelain).Length -gt 0) { '+dirty' } else { '' }
$buildDate = (Get-Date).ToString('yyyy-MM-dd HH:mm')

Write-Host "==> Deploy" -ForegroundColor Cyan
Write-Host "    Version:    $version$dirty"
Write-Host "    Build date: $buildDate"
Write-Host ""

& $fly deploy --remote-only --build-arg "VERSION=$version$dirty" --build-arg "BUILD_DATE=$buildDate"
