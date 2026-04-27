# Medevio Dashboard + Léčebné plány

Lokální dashboard nad Medevio External API. Tři záložky:

1. **📊 Dashboard** — KPI, grafy, tabulky požadavků pacientů (live data z Medevio)
2. **🗂 Léčebné plány** — instance plánů typu „TEP kyčle" pro pacienty (38 kroků v 6 fázích)
3. **📋 Položky plánů** — filterable tabulka všech kroků napříč plány

## Spuštění

```powershell
powershell -ExecutionPolicy Bypass -File C:\Dropbox\claude\medevio-dashboard\dashboard_server.ps1
```

Server poslouchá na `http://localhost:8766/`. Otevři v prohlížeči.

**Stop:** Ctrl+C v okně serveru.

## Soubory

| Soubor | Účel |
|---|---|
| `dashboard_server.ps1` | PowerShell HTTP server, proxy k Medevio API, plánová logika, PDF generátor |
| `medevio-dashboard-live.html` | Single-page frontend (3 záložky, modaly), Chart.js z CDN |
| `clinics.json` | API klíče klinik (⚠ tokeny — nepushovat do veřejného git!) |
| `plans.json` | Instance léčebných plánů + mapa `stepCode → requestId + attachmentId` |
| `plan-templates.json` | Šablona plánu „TEP kyčle" (38 kroků dle PDF KN Liberec) |
| `medevio-spec.js` | OpenAPI spec stažený ze Scalar docs (referenční, raw JS od Scalaru) |
| `ARCHITECTURE.md` | Návrh systému a datových toků |
| `API-NOTES.md` | Zjištěné quirky Medevio API (kódování, dueDate, userNote, atd.) |
| `CHANGELOG.md` | Co se kdy postavilo |
| `OPEN-ISSUES.md` | Co zbývá udělat |

## Konfigurace klinik

Soubor `clinics.json` obsahuje pole klinik se schématem:

```json
{
  "label":   "MUDr. Šimon Kubita",
  "slug":    "mudr-kubita",
  "token":   "<Personal Access Token z Medevio>",
  "enabled": true,
  "env":     "dev"  // "dev" = api.medevio.dev, "prod" = api.medevio.cz
}
```

Klíče lze spravovat přes UI (⚙ Spravovat API klíče v multiselect dropdownu nahoře).

## Závislosti

- Windows + PowerShell 5.1 (built-in)
- Internet (volá Medevio API)
- Browser s Chart.js z `cdn.jsdelivr.net`
- Žádné npm/pip — server je jeden `.ps1` soubor

## Deploy na Fly.io (s Dockerem)

Aplikace běží v Docker kontejneru. Konfigurace ve `fly.toml`, image staví podle `Dockerfile`.

### Prerekvizity
1. Účet na https://fly.io
2. `flyctl` CLI (`winget install fly-io.flyctl` na Windows, případně instalátor z https://fly.io/docs/flyctl/install/)
3. `fly auth login`

### První deploy

```powershell
cd C:\Dropbox\claude\medevio-dashboard
fly launch --copy-config --no-deploy   # vezme stávající fly.toml
fly volumes create medevio_data --size 1 --region fra
fly deploy
```

URL: `https://medevio-dashboard.fly.dev` (nebo podle zvoleného app name).

### Konfigurace klinik po deployi

V kontejneru se vytvoří prázdný `clinics.json` na `/data/clinics.json`. Kliniky se přidají přes UI (⚙ Spravovat API klíče v dropdownu nahoře). Soubor přežije restart díky persistent volume.

### Update aplikace

```powershell
git push origin main   # commit do GitHubu
fly deploy             # nový build + redeploy, ~1-2 min
```

### Užitečné příkazy
- `fly logs` — live logy
- `fly status` — co běží
- `fly ssh console` — shell uvnitř kontejneru
- `fly secrets set FOO=bar` — nastavit env var (šifrovaně)

## Setup na novém PC

```powershell
# 1. Pockat na Dropbox sync (vznikne C:\Dropbox\claude\medevio-dashboard\)
# 2. Spustit setup script (idempotentni - jen co chybi se doinstaluje)
powershell -ExecutionPolicy Bypass -File C:\Dropbox\claude\medevio-dashboard\setup-new-pc.ps1
```

Skript zkontroluje/nainstaluje **git**, **flyctl**, nastaví git identity, a pomůže s `fly auth login` přes prohlížeč.

## Kontext pro Claude Code

Soubor [`CLAUDE.md`](./CLAUDE.md) v rootu repa je **automaticky načítán** Claude Code session při startu z této složky. Obsahuje:
- profil uživatele
- popis projektu, tech stacku, architektury
- známé Medevio API quirky
- workflow pro deploy
- otevřené body

Když pokračuješ na novém PC: stačí `cd C:\Dropbox\claude\medevio-dashboard` a spustit Claude Code — kontext se naváže automaticky.
