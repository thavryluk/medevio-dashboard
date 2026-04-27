# Deploy na Fly.io s automatickym embedovanim verze a datumu buildu.

# Pozn: ZAMERNE bez 'Stop' EAP - flyctl pisuje neskodny noise na stderr,
# coz by jinak shodilo skript pred dokoncenim deploy.
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
$ec = $LASTEXITCODE
Write-Host ""
if ($ec -eq 0) {
    Write-Host "==> Deploy hotov: https://medevio-dashboard.fly.dev/" -ForegroundColor Green
} else {
    Write-Host "!!  Deploy selhal (exit $ec)" -ForegroundColor Red
    exit $ec
}
