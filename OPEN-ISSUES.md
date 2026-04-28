# Otevřené body

Co jsme záměrně odložili nebo zatím neimplementovali.

## UI drobnosti

- **Oddělovač tisíců** — všechna čísla v UI (KPI karty, počty požadavků, cache info, tabulky) zobrazovat s mezerou jako oddělovačem tisíců (česká konvence: `1 234 567` místo `1234567`). JS helper: `n.toLocaleString('cs-CZ')`. Aplikovat v `escHtml`/`fmtNum` helperu napříč.

## Veřejný deploy

Aktuálně jen lokálně (`localhost:8766`). Diskutovány varianty:

1. **Cloudflare Tunnel** — server zůstane lokálně, `cloudflared` udělá HTTPS tunel. + Cloudflare Access (Google SSO) zdarma. Nevýhoda: PC musí být zapnutý.
2. **Cloudflare Workers + Access** — přepsat PowerShell logiku do JS (~50 řádků), token jako Worker Secret. Běží 24/7. Doporučená dlouhodobá volba.
3. **Render / Railway / Fly.io** — Docker s pwsh nebo přepis do Node. Cold-start 10s.

⚠ Před veřejným nasazením anonymizovat data (jména pacientů jsou reálná zaměstnanci Medevio na dev) NEBO postavit auth (Cloudflare Access).

## Kalendářní rezervace (`timeSlotInput`)

`POST /patientRequests/create` přijímá `timeSlotInput: {start, end, calendarId}` pro vytvoření rezervace. Bez něj Medevio přepíše `dueDate` na čas vytvoření.

Co je třeba:
- Endpoint v serveru: `POST /api/patients` → vrátí seznam kalendářů z `/calendar/search`
- UI v dialogu pro vytvoření plánu: výběr kalendáře per krok (nebo defaultně jeden pro celou kliniku)
- V `Create-PlanInMedevio` přidat `timeSlotInput` do create body

## Přepočítávání dat při změně data operace

Když uživatel změní `surgeryDate` v detailu plánu, due dates kroků se **nepřepočítávají** (uživatel musí ručně). API neumožňuje editaci `dueDate` na existujícím požadavku, takže reálně by šlo jen o:

- Přepočítat plánované termíny v `plans.json` (snadné)
- Nahradit existující PDF přílohu novou (nový upload-link + S3 PUT + register; stará příloha ale zůstane v Medevio — API neumí mazat přílohy)

## Stavy kroku — automatizace

Stavový systém má 11 stavů ale dashboard zatím auto-rozhoduje jen mezi `NOT_STARTED` / `OVERDUE` / `COMPLETED`. Ručně lze nastavit ostatních 8 přes detail dialog.

Možné rozšíření:
- Auto `BLOCKED` když `requires` step není COMPLETED
- Auto `PENDING_PATIENT` / `PENDING_CLINICIAN` podle role kroku v `NOT_STARTED`
- Notifikace koordinátorovi pro `OVERDUE` (e-mail / Slack)

## Refresh skutečného stavu z Medevio

Po vytvoření plánu Plan-WithLiveData načítá `doneAt` z Medevio při každém GET. Funguje, ale volá `patientRequests/search` znovu pro každou kliniku → pomalé pro velký počet plánů. Cache by stálo za to.

## Smazání plánu

`DELETE /api/plans/{id}` smaže lokální mapu, ale 38 požadavků v Medevio zůstává osiřele (API nemá DELETE). Možnosti:

- Označit všechny resolve (přes 38× `PUT /resolve`) → uvidí se jako vyřešené místo zmizelé
- Nechat na admina v Medevio
- Nepodporovat smazání plánu, jen archivaci

## Více šablon

Zatím existuje jen `TEP-KYCLE-v1`. Šablonu pro jiný operační typ (TEP kolene, kýla, …) lze přidat manuálně do `plan-templates.json`. UI pro tvorbu/editaci šablon zatím neexistuje.

## Přílohy — alternativy k PDF

Aktuálně mini-PDF s textem + JSON dump v textové formě. Možné varianty:

- **Validní PDF s embedded JSON metadata** (PDF/A umožňuje přiložit XMP nebo soubor) — komplexnější generátor
- **PNG s textem** — generovaný přes `System.Drawing.Bitmap` — snadnější ale "obrázek" v UI
- **PDF s tabulkou** — víc layoutu (nadpisy, oddíly, formátování)

## Persistence stavu napříč sessiony

`plans.json` na disku není zálohovaný. Pokud Dropbox sync selže, data se mohou ztratit. Možnosti:
- Periodický git commit (cron)
- SQLite místo JSON souborů
- Nahrávat snapshot do Medevio jako přílohu plán-meta requestu

## Test coverage

Žádné testy. Server je `.ps1` skript, frontend SPA. Pro stabilní vývoj by stálo za to mít:
- PS Pester testy pro `New-MinimalPdf`, `CalcDueDate`, `Pick-EcrfCandidates`
- Smoke test endpointů (curl skript)
- Mockování Medevio API pro CI
