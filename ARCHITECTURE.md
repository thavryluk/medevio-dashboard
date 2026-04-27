# Architektura

## Přehled vrstev

```
┌─────────────────────────────────────────────────┐
│  Browser (medevio-dashboard-live.html)          │
│  - 3 záložky: Dashboard / Plány / Položky       │
│  - Chart.js (CDN), modaly, multiselect klinik   │
└──────────────────┬──────────────────────────────┘
                   │ fetch /api/...
                   ▼
┌─────────────────────────────────────────────────┐
│  Lokální HTTP server (dashboard_server.ps1)     │
│  - PowerShell + System.Net.HttpListener         │
│  - Token nikdy neopouští server                 │
│  - PDF generátor pro přílohy                    │
└──────────────────┬──────────────────────────────┘
                   │ Bearer token (UTF-8)
                   ▼
┌─────────────────────────────────────────────────┐
│  Medevio External API                           │
│  - api.medevio.dev (dev) / api.medevio.cz (prod)│
│  - 21 endpointů, OpenAPI 3.1                    │
└─────────────────────────────────────────────────┘
```

## API endpointy serveru

### Klíče (správa)
- `GET  /api/clinics` — veřejný seznam klinik (slug, label, env), bez tokenů
- `GET  /api/clinics/full` — kompletní list včetně tokenů (pro management UI)
- `POST /api/clinics` — přidat (validuje token přes /clinics/search)
- `PUT  /api/clinics?slug=X` — update (label, token, enabled, env)
- `DELETE /api/clinics?slug=X` — odebrat

### Data dashboardu
- `GET /api/data?slugs=a,b,c` — agregovaná data (požadavky, pacienti, uživatelé) z N klinik

### Pacienti
- `GET /api/patients?clinicSlug=X&clinicEnv=dev` — seznam pacientů kliniky

### Léčebné plány
- `GET /api/plan-templates` — šablony (zatím jen TEP-KYCLE-v1)
- `GET /api/plans` — instance plánů (s live progress)
- `GET /api/plans/{id}` — detail plánu
- `POST /api/plans` — vytvořit (založí 38 requestů + 38 PDF příloh v Medevio)
- `PATCH /api/plans/{id}` — update (surgeryDate, notes, stepStates)
- `DELETE /api/plans/{id}` — smazat lokální mapu (Medevio requesty zůstanou — API neumí delete)
- `PATCH /api/plans/{id}/steps/{code}` — update lokálního stavu kroku
- `POST /api/plans/{id}/steps/{code}/resolve` — označit krok jako vyřešený v Medevio

### Položky
- `GET /api/plan-items` — všechny kroky napříč plány (pro filterable tabulku)

## Datový model léčebného plánu

### Šablona (plan-templates.json)

```json
{
  "id": "TEP-KYCLE-v1",
  "title": "TEP kyčle — předoperační příprava",
  "steps": [
    {
      "code": "P0-INIT",
      "title": "Úvodní pohovor s koordinátorem",
      "role": "COORD",                    // PATIENT|GP|SURGEON|ANEST|NUTRI|COORD
      "category": "EDUCATION",            // EXAM|DECISION|LOGISTIC|MEDICATION|APPOINTMENT|EDUCATION
      "phase": "0",                       // 0|A|B1|B2|B3|C
      "offsetDays": -90,                  // dny od data operace (záporné = před)
      "gate": "none",                     // none|soft|hard
      "requires": [],                     // pole prereq stepCode
      "patientVisible": true,
      "userNote": "...",                  // pokyny pro pacienta
      "conditional": "..."                // (volitelně) podmínka
    }
  ]
}
```

### Instance plánu (plans.json)

```json
{
  "id": "<uuid>",
  "templateId": "TEP-KYCLE-v1",
  "patientId": "<medevio uuid>",
  "patientName": "Tomáš Havryluk",
  "clinicSlug": "mudr-kubita",
  "clinicEnv": "dev",
  "surgeryDate": "2026-09-01T08:00:00.000Z",
  "createdAt": "...",
  "stepRequests": {
    "P0-INIT": {
      "requestId": "<medevio request uuid>",
      "ecrfSid": "CHECKUP_KASPAROVA",     // typ Medevio request
      "dueDate": "2026-06-03T08:00:00.000Z",
      "contextAttachmentId": "<medevio attachment uuid>"  // PDF s plnou kopií
    }
  },
  "stepStates": {
    "P0-INIT": {
      "state": "PENDING_PATIENT",         // 11 stavů
      "note": "Volal jsem 25.4., dohodnuto na 12.5."
    }
  }
}
```

## Stavy kroku

| Kód | Význam |
|---|---|
| `NOT_STARTED` | Vytvořeno, čeká |
| `PENDING_PATIENT` | Čeká na akci pacienta |
| `PENDING_CLINICIAN` | Čeká na akci lékaře |
| `IN_PROGRESS` | Probíhá |
| `SUBMITTED` | Pacient/lékař odevzdal, čeká review |
| `NEEDS_REVIEW` | Čeká schválení koordinátora |
| `BLOCKED` | Prerekvizita nesplněna |
| `COMPLETED` | Hotovo (auto, když Medevio request má `doneAt`) |
| `SKIPPED` | Nerelevantní |
| `FAILED` | Nelze dokončit |
| `OVERDUE` | Plánovaný termín v minulosti, nedokončené |

## Vytvoření plánu (workflow)

1. UI: výběr šablony + kliniky + pacienta + datum operace
2. Server: pro každý ze 38 kroků šablony:
   - Vybere nejvhodnější `userECRFId` ze seznamu kandidátů (~11) podle kategorie
   - Vyzkouší `POST /patientRequests/create` s retry/fallback
   - Vygeneruje mini-PDF (~900 B) s lidsky čitelným popisem + JSON metadata
   - Nahraje PDF přes `attachments/upload-link` → S3 PUT → `attachments` register
3. Uloží mapu `stepCode → {requestId, ecrfSid, contextAttachmentId}` do `plans.json`

Trvání: ~22 s pro 38 kroků (× 4 API calls = 152 calls).

## PDF generátor

Custom v PowerShellu (~80 řádků v `dashboard_server.ps1`, funkce `New-MinimalPdf`). Generuje validní PDF 1.4 s:
- Catalog → Pages → Page → Font (Helvetica) → Content stream
- Přesné xref offsety (jinak některé readery selžou)
- Latin-1 encoding (S3 PUT pak posílá raw bajty)

Důvod custom generátoru: PowerShell 5.1 nemá zabudovanou PDF knihovnu, instalace nuget/pip není vyžadovaná.
