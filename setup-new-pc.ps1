# Setup script pro nove PC. Spustit z PowerShellu (jako bezny user, ne admin).
#
# Predpoklady:
# - Windows + PowerShell 5.1+
# - Internet
# - Tento soubor lezi v Dropbox synchronizovane slozce
#
# Idempotentni: muze se spustit opakovane, jen co chybi se doplni.

$ErrorActionPreference = 'Stop'

Write-Host "==> Setup Medevio Dashboard projektu na novem PC" -ForegroundColor Cyan
Write-Host ""

# 1. Git
Write-Host "[1/4] Git" -ForegroundColor Yellow
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    Write-Host "  OK: $(git --version)"
} else {
    Write-Host "  CHYBI - nainstaluj z https://git-scm.com/download/win" -ForegroundColor Red
    Write-Host "  Po instalaci spust skript znovu."
    exit 1
}

# Git identity (jen pro tento repo, ne globalne)
$repoDir = $PSScriptRoot
Set-Location $repoDir
$existingName = git config user.name 2>$null
if (-not $existingName) {
    Write-Host "  Nastavuji git identity pro tento repo (Tomas Havryluk)"
    git config user.name "Tomáš Havryluk"
    git config user.email "tomas.havryluk@medevio.cz"
} else {
    Write-Host "  Identity uz nastavena: $existingName"
}

# 2. flyctl
Write-Host ""
Write-Host "[2/4] flyctl (Fly.io CLI)" -ForegroundColor Yellow
$flyExe = "$env:USERPROFILE\.fly\bin\flyctl.exe"
if (Test-Path $flyExe) {
    Write-Host "  OK: $(& $flyExe version)"
} else {
    Write-Host "  Stahuji a instaluji..."
    iwr https://fly.io/install.ps1 -useb | iex
}

# 3. Fly auth
Write-Host ""
Write-Host "[3/4] Fly.io prihlaseni" -ForegroundColor Yellow
$whoami = & $flyExe auth whoami 2>&1
if ($whoami -match '@') {
    Write-Host "  OK: prihlasen jako $whoami"
} else {
    Write-Host "  Otviram prihlaseni v prohlizeci..."
    & $flyExe auth login
}

# 4. Test lokalniho serveru
Write-Host ""
Write-Host "[4/4] Test lokalniho serveru" -ForegroundColor Yellow
Write-Host "  Pro spusteni serveru lokalne:"
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$repoDir\dashboard_server.ps1`""
Write-Host ""
Write-Host "  Server bude na http://localhost:8766/"
Write-Host ""
Write-Host "  Pozn.: clinics.json a plans.json se vytvori prazdne pri prvnim startu."
Write-Host "  Pokud chces nahrat z Fly produkce, spust:"
Write-Host "    .\sync-from-fly.ps1   (TODO: zatim neexistuje, vyzadej u Claude)"

Write-Host ""
Write-Host "==> Hotovo. Veci ktere musis udelat MANUALNE:" -ForegroundColor Green
Write-Host "    1. Otevrit terminal v $repoDir"
Write-Host "    2. Pripadne: spustit Claude Code, ktery automaticky nacte CLAUDE.md"
Write-Host "    3. Otevrit https://medevio-dashboard.fly.dev/ v prohlizeci"
