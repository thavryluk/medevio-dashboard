# CLAUDE.md — kontext pro Claude Code

> **Automaticky načítáno** Claude Code při startu session v této složce.
> Cloud-portable: tento soubor je v Dropboxu i v GitHubu, takže každá Claude session na jakémkoli PC začíná se stejným kontextem.
>
> **Co je kde uložené:**
> - Tento `CLAUDE.md` + dokumentace + zdrojáky → **GitHub repo** (https://github.com/thavryluk/medevio-dashboard)
> - Sensitive data (`clinics.json`, `plans.json`) → **Fly secrets** + lokální Dropbox folder (gitignored)
> - Per-PC technické věci (flyctl auth, git credentials) → lokální, vyžadují re-login po `setup-new-pc.ps1`

## Uživatel

**Tomáš Havryluk** — pracuje ve firmě **Medevio**.
- E-mail: `tomas.havryluk@medevio.cz`
- Lokální username: `thavr` (Windows 11)
- GitHub: `thavryluk`
- Fly.io účet: `tomas.havryluk@medevio.cz` (organizace `personal`, tarif Pay-as-you-go)
- Komunikuje **česky**, preferuje stručnost a přímočarost
- Programuje sám, ale počítá s kolaborací s kolegy

## Co je projekt

**Medevio Dashboard + Léčebné plány** — lokální/cloudová aplikace nad **Medevio External API** (api.medevio.cz / .dev) se třemi záložkami:

1. **📊 Dashboard** — KPI karty, grafy (Chart.js), tabulky pacientských požadavků z N klinik (multiselect)
2. **🗂 Léčebné plány** — instance plánu „TEP kyčle — předoperační příprava" (38 kroků v 6 fázích podle PDF KN Liberec) pro konkrétní pacienty; vytvoření plánu = 38 Medevio requestů + 38 PDF příloh
3. **📋 Položky plánů** — filterable tabulka napříč všemi plány

## Tech stack

| Vrstva | Co |
|---|---|
| Backend | PowerShell 5.1/7 + .NET `System.Net.HttpListener` (1 soubor, ~900 řádků) |
| Frontend | Vanilla HTML/CSS/JS, Chart.js z CDN, žádný framework |
| Storage | JSON soubory na disku (`clinics.json`, `plans.json`, `plan-templates.json`) |
| Custom | Vlastní mini-PDF generátor v PowerShellu (~80 řádků, žádné externí knihovny) |
| Deploy | Docker (`mcr.microsoft.com/powershell:lts-alpine`) na **Fly.io** ve Frankfurtu |
| Source | **GitHub** (public): https://github.com/thavryluk/medevio-dashboard |

## Klíčové URL

| Co | Adresa |
|---|---|
| Veřejná aplikace | https://medevio-dashboard.fly.dev/ |
| Fly admin | https://fly.io/apps/medevio-dashboard |
| GitHub repo | https://github.com/thavryluk/medevio-dashboard |
| Lokální dev | http://localhost:8766/ |
| Medevio API docs | https://developers.medevio.cz/ |
| Medevio prod API | https://api.medevio.cz/external/v1 |
| Medevio dev API | https://api.medevio.dev/external/v1 |

## Soubory v projektu (tato složka, `C:\Dropbox\claude\medevio-dashboard\`)

| Soubor | Účel | V gitu? |
|---|---|---|
| `dashboard_server.ps1` | HTTP server + proxy + plán logika + PDF generátor | ✓ |
| `medevio-dashboard-live.html` | Frontend SPA (3 záložky, modaly) | ✓ |
| `plan-templates.json` | Šablona TEP kyčle (38 kroků) | ✓ |
| `Dockerfile` | Image recipe (pwsh LTS Alpine) | ✓ |
| `fly.toml` | Fly.io app config | ✓ |
| `.dockerignore`, `.gitignore` | Vyloučení secretů a artefaktů | ✓ |
| `clinics.json.example` | Schéma pro nového uživatele | ✓ |
| `clinics.json` | API klíče 3 dev klinik (mudr-kubita, mudr-havryluk, super-size-clinic) | ✗ (gitignore) |
| `plans.json` | Instance plánů + mapa stepCode → Medevio requestId | ✗ (gitignore) |
| `medevio-spec.js` | OpenAPI spec stažený ze Scalar | ✓ |
| `README.md`, `ARCHITECTURE.md`, `API-NOTES.md`, `CHANGELOG.md`, `OPEN-ISSUES.md` | Dokumentace | ✓ |
| `PROJECT-CONTEXT.md` | Tento soubor | ✓ |

## Spuštění

**Lokálně:**
```powershell
powershell -ExecutionPolicy Bypass -File C:\Dropbox\claude\medevio-dashboard\dashboard_server.ps1
```
→ http://localhost:8766/

**Deploy na Fly:**
```powershell
& "$env:USERPROFILE\.fly\bin\flyctl.exe" deploy --remote-only
```
(z folderu projektu, vyžaduje `fly auth login` jednorázově)

## Architektura plánu

Vytvoření plánu pro pacienta:
1. UI: vyber šablona → klinika → pacient (z `/api/patients`) → datum operace
2. Server: pro každý ze 38 kroků šablony:
   - Pick-EcrfCandidates (~11 ECRF typů podle kategorie kroku, fallback na 5xx)
   - `POST /clinics/{slug}/patientRequests/create` s vypočteným `dueDate = surgeryDate + offsetDays`
   - Vygenerovat mini-PDF s lidsky čitelným popisem + JSON metadata
   - 3-stupňový upload: `attachments/upload-link` → S3 PUT → `attachments` register
3. Save mapa `stepCode → {requestId, ecrfSid, contextAttachmentId}` do `plans.json`

Trvání: ~22 s pro 38 kroků (× 4 API calls = 152 calls).

## Zjištěné Medevio API quirky (důležité!)

- `userNote` při create se ukládá, ale search vrací `null` (nejasné, zda viditelné v UI)
- `title` API neumožňuje (bere se z `userECRF.name`, např. „Objednání na odběr")
- `dueDate` u typů s `requiresReservation: true` se přepisuje na čas vytvoření
- `userECRFId` některé 404ují (deaktivované); fallback přes 11 kandidátů s retry
- Přílohy enum jen `pdf|jpeg|png|gif|webp`, čistý JSON nelze
- Medevio nevaliduje shodu type vs obsah → můžeme nahrát JSON jako „PDF"
- API nemá GET attachment ani DELETE request (přílohy/requesty zůstávají navždy)
- PS 5.1 `Invoke-RestMethod` posílá body Latin-1 → UTF-8 láme češtinu; vždy posílat raw bytes
- `dueDate` musí být UTC `Z`, ne `+02:00`

Plus: `$Host` je rezervovaná PS proměnná. PS pipeline strippuje prázdné pole na `$null` (proto vlastní `Send-JsonArray` helper).

## Storage strategie

| Co | Kde žije teď | Strategie do budoucna |
|---|---|---|
| Tokeny klinik | Lokálně `clinics.json`, na Fly jako `CLINICS_JSON_SEED_B64` secret + volume `/data/clinics.json` | OK; rotovat přes `fly secrets set` |
| Instance plánů | Lokálně `plans.json`, na Fly volume `/data/plans.json` (seed přes `PLANS_JSON_SEED_B64`) | Časem zvážit Postgres, pokud bude víc kolaborantů |
| Šablony plánů | `plan-templates.json` (statický, v image) | OK |
| Pacientská data | Medevio Postgres + S3 (mimo nás) | nemáme co řešit |

**Lokál × Fly nesynchronizuje data!** Vyber strategii: pracovat jen na Fly, nebo lokálně testovat a přepoušíčit (`fly secrets set ...` pro nový plans.json snapshot).

## Klíčové milníky (vývoj)

| Datum | Co |
|---|---|
| 21.4.2026 | Průzkum Medevio API, statický dashboard s embedded daty |
| 22.4.2026 | Live PowerShell server, multi-clinic, modal pro správu klíčů |
| 23.4.2026 | 3 záložky, šablona TEP kyčle (38 kroků), detail dialog kroku, PDF přílohy ke každému Medevio requestu |
| 27.4.2026 | Přesun na Dropbox (`C:\Dropbox\claude\medevio-dashboard`), commit do GitHubu (public repo), Docker + deploy na Fly.io ve Frankfurtu, seed klinik a plánů přes Fly secrets |

## Workflow pro budoucí změny

1. Otevři terminál v `C:\Dropbox\claude\medevio-dashboard\` (nebo ekvivalent na druhém PC, viz „Setup na novém PC" níž)
2. Edituj kód, otestuj lokálně (`localhost:8766`)
3. `git add . && git commit -m "..." && git push`
4. `& "$env:USERPROFILE\.fly\bin\flyctl.exe" deploy --remote-only`
5. Ověř https://medevio-dashboard.fly.dev/

## Setup na novém PC (až přijde čas)

1. **Nainstalovat Dropbox** + počkat na sync `C:\Dropbox\claude\medevio-dashboard\`
2. **Nainstalovat Git** (https://git-scm.com/download/win)
3. **Nainstalovat flyctl**: v PowerShell `iwr https://fly.io/install.ps1 -useb | iex`
4. **Přihlásit se na Fly**: `& "$env:USERPROFILE\.fly\bin\flyctl.exe" auth login`
5. **Vyzkoušet lokální server**: `powershell -ExecutionPolicy Bypass -File <path>\dashboard_server.ps1`
6. **Pro Claude session**: nech Claude přečíst tento `PROJECT-CONTEXT.md` jako první. Memory soubory v `~\.claude\projects\...` jsou per-počítač, takže nejlepší je explicit reference na tento soubor.

## Otevřené body (záměrně neimplementované)

Viz `OPEN-ISSUES.md` pro detail. Krátce:

- **Auth před aplikací** — zatím bez ochrany (Cloudflare Access / Basic auth / Medevio token verification)
- **Auto-deploy** z `git push` přes GitHub Action (`.github/workflows/fly-deploy.yml` připraven, chybí `FLY_API_TOKEN` jako secret)
- **Sdílení dat lokál × Fly** — separátní (volby: Postgres, sync skript, jen Fly)
- **Kalendářní rezervace** (`timeSlotInput` v create requestu)
- **Přepočet termínů** při změně data operace (zatím ručně)
- **Více šablon plánů** (zatím jen TEP kyčle)
- **Stavový automat** (BLOCKED z `requires`, eskalace OVERDUE…)

## Kontakt na Medevio support

`podpora@medevio.cz` — pro tokeny, oprávnění, otázky na ECRF konfiguraci kliniky.
