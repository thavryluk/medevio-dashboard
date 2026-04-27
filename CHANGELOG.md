# Changelog

Stručný přehled co se kdy postavilo (od 21. 4. 2026).

## 2026-04-21
- Průzkum Medevio API přes Scalar docs (developers.medevio.cz), extrakce 21 endpointů
- Identifikace `.dev` prostředí (api.medevio.dev) — není v dokumentaci
- Stažení dat z kliniky `mudr-kubita` (64 požadavků, 16 pacientů)
- **Statický dashboard** — jeden HTML soubor s embedded daty + Chart.js
- 6 KPI karet, 6 grafů (typy, čas, autor, stav podle typu, top pacienti, doba vyřízení)
- Tabulky otevřených a nejnovějších požadavků

## 2026-04-22
- Nahrazení statické verze **live serverem** v PowerShellu (`dashboard_server.ps1`)
- Endpoint `/api/data` proxy-volá Medevio s Bearer tokenem
- Tlačítko Obnovit v UI
- Doplnění **multiselect dropdownu** pro výběr klinik (1-N) a agregace dat
- Extrakce `clinics.json` jako konfig (3 dev kliniky: mudr-kubita, mudr-havryluk, super-size-clinic)
- **Modal „Spravovat API klíče"** — přidat/odebrat/toggle/edit/kopírovat klíče
- Per-klinika `env: dev|prod` s automatickou volbou base URL
- Statistika doby vyřízení rozšířena o průměr a P90 (horní decil)

## 2026-04-23
- **Tři záložky** — `Dashboard` / `Léčebné plány` / `Položky plánů`
- **Šablona „TEP kyčle"** (`plan-templates.json`) — 38 kroků v 6 fázích, 6 rolí, podle PDF KN Liberec (části A + B)
- Endpoint pro CRUD plánů (`/api/plans`, `/api/plan-items`, `/api/plan-templates`)
- **Vytvoření plánu** — formulář (šablona, klinika, pacient, datum operace) → server zakládá 38 požadavků v Medevio
- Lokální stavový systém kroků (11 stavů: NOT_STARTED, PENDING_PATIENT, …, OVERDUE)
- Položky plánů — filterable tabulka (klinika, plán, pacient, role, fáze, kategorie, stav + checkboxy)
- **Detail dialog kroku** — view + editace lokálního stavu + interní poznámka koordinátora + tlačítko „Vyřešit v Medevio"
- Počeštění labelů (role, kategorie, stavy) — odstranění anglicismů
- **Bug fix:** UTF-8 v Read-Body i Invoke-Medevio (PS 5.1 default Latin-1 láme češtinu)
- **Bug fix:** `dueDate` UTC `Z` (Medevio neakceptuje `+02:00`)
- **Bug fix:** ECRF fallback (zkouší 11 kandidátů s retry/throttle)
- **PDF přílohy ke každému kroku** — custom mini-PDF generátor v PS (validní PDF 1.4) s lidsky čitelným popisem + JSON metadata; nahrávané přes `attachments/upload-link` → S3 → `attachments` register

## 2026-04-27
- Přesun projektu na Dropbox (`C:\Dropbox\claude\medevio-dashboard\`)
- Přidána dokumentace (README, ARCHITECTURE, API-NOTES, CHANGELOG, OPEN-ISSUES)
- Změna portu 8765 → 8766 (původní zaseknutý zombie procesem)
