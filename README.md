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

## Memory Claude Code

Persistentní kontext pro budoucí Claude session je v:
`C:\Users\thavr\.claude\projects\C--Users-thavr\memory\`

Po přesunu na Dropbox aktualizuj v memory soubor `medevio_dashboard_state.md` na novou cestu (`C:\Dropbox\claude\medevio-dashboard\`).
