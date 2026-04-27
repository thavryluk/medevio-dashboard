# Medevio API — quirky, na které jsme narazili

Verze spec: 1.0.1 (OpenAPI 3.1.1) — `developers.medevio.cz`

## Prostředí

- **Produkce:** `https://api.medevio.cz/external/v1`
- **Dev/test:** `https://api.medevio.dev/external/v1`

V dokumentaci je uvedena pouze `.cz`, dev `.dev` zjištěna empiricky. Tokeny jsou vázány na prostředí (prod token nefunguje proti dev a naopak).

## Kódování

PowerShell 5.1 `Invoke-RestMethod` posílá body jako Latin-1, což láme UTF-8 znaky → API vrací 500 u českého textu. **Vždy posílat raw UTF-8 bytes:**

```powershell
$bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
Invoke-RestMethod -Body $bytes -ContentType 'application/json; charset=utf-8' ...
```

Stejně tak `HttpListener` defaultně čte body jako Latin-1 — `Read-Body` vynucuje UTF-8.

## `dueDate` musí být UTC

Medevio přijímá pouze `YYYY-MM-DDTHH:mm:ss.fffZ`. Offset `+02:00` vrátí 400.

```powershell
$Surgery.AddDays($OffsetDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
```

## `dueDate` se přepisuje na čas vytvoření

U `userECRF` s `requiresReservation: true` (LABORATORY, CHECKUP_KASPAROVA, …) Medevio **ignoruje předaný `dueDate`** a uloží čas vytvoření. Plánovaný termín z naší šablony zobrazujeme jako primární, Medevio termín jako sekundární.

Workaround = poslat `timeSlotInput` s `calendarId` (ale to vyžaduje napojení na kalendář kliniky, nepřipraveno).

## `userNote` se neukládá zpětně

`POST /patientRequests/create` přijme `userNote` (200 OK), ale následný `search` ho vrací jako `null`. Není jasné, jestli je viditelný v Medevio aplikaci. Pro jistotu posíláme i tak.

## `title` API neumožňuje

V request body create endpointu pole `title` neexistuje. Titulek požadavku v Medevio se odvodí od `userECRF.name`, např.:

| `userECRF.sid` | Zobrazený titulek |
|---|---|
| `LABORATORY` | „Objednání na odběr" |
| `CHECKUP_KASPAROVA` | „Objednání vyšetření" |
| `DOCTOR_MESSAGE` | „Zpráva od lékaře" |
| `APPROVAL_PEDIATRIC_SUB_MEDICAL_FITNESS` | „Posudek o zdravotní způsobilosti" |
| `CHCI_SE_OBJEDNAT_NA_KONZULTACI` | „Recept na lék" |
| `DIAOBE_ANAMNESTICKY` | „Testovací název" |

Pro plán to znamená: pacient v Medevio aplikaci uvidí 38 požadavků s ~10 různými titulky podle typu. **Skutečný kontext** je v PDF příloze a v našem dashboardu.

## `userECRFId` — některé 404ují

Některé typy (např. `DOCTOR_MESSAGE` u kliniky `mudr-kubita`) vrací `404 UserECRF not found`, i když existují v datech kliniky. Pravděpodobně admin je deaktivoval. Server proto zkouší **až 11 kandidátních ECRF** podle kategorie kroku (`Pick-EcrfCandidates`) s retry na 5xx.

## Přílohy — jen PDF a image

`POST /attachments` má enum `contentType: pdf|jpeg|png|gif|webp`. **Čistý JSON nelze zaregistrovat.**

Workaround: `upload-link` přijme jakýkoliv contentType (jen string), S3 PUT přijme libovolný obsah, a `register` se dá oklamat — server **nevaliduje shodu typu a obsahu**. Proto generujeme **mini-PDF s lidsky čitelným popisem + JSON dump v textu** a registrujeme jako `application/pdf`.

## `attachments` GET neexistuje

API umožňuje upload, ale ne download přílohy. Přílohy slouží jen pro vizuální zobrazení v Medevio UI; primárním source-of-truth pro náš dashboard zůstává `plans.json`.

## Žádné PUT/PATCH na request

`POST /create` a `PUT /resolve` jsou jediné write operace na požadavku. Editace `userNote`, `title`, `dueDate`, tagů atd. po vytvoření **nelze**. Změny mohou nastat jen v Medevio aplikaci.

## Žádné DELETE na request

Smazat požadavek přes API nelze. Pokud uživatel smaže plán v dashboardu, požadavky v Medevio zůstanou (s mazáním pomůže jen admin v Medevio).

## Rate-limiting / 5xx pod load

Medevio dev občas vrací 500 při rychlém batchi. Server má retry s 600 ms backoff (3× per ECRF kandidát) + 250 ms throttle mezi kroky.

## OpenAPI spec extract

Spec je dostupná přes `https://developers.medevio.cz` (Scalar viewer). Raw JS s embedded JSON: `developers.medevio.cz/assets/vaxlokjflthj5wm7krmvforuucogf7m1u0hj5ine-Cc4C-Piq.js` — kopie v tomto repu jako `medevio-spec.js`.

## Endpointový seznam (21)

| Tag | Endpoint |
|---|---|
| Status | `GET /status` |
| Users | `GET /user/me` |
| Clinics | `POST /clinics/search` |
| Clinics | `GET/POST /clinics/{slug}/users/{search,id}` |
| Clinics | `DELETE /clinics/{slug}/patientRecords` *(jen DEV)* |
| Patients | `POST /clinics/{slug}/patients/search` |
| Patients | `GET/DELETE /clinics/{slug}/patients/{id}` |
| Patients | `GET .../patients/{id}/canDelete` |
| Patients | `POST .../patients/{id}/invitation` |
| Patient Import | `POST .../patients/import` |
| Patient Import | `POST .../patients/import-bulk` |
| Patient Import | `GET .../patients/import-bulk/{jobId}` |
| Patient Import | `GET .../patients/import-bulk/{jobId}/status` |
| Calendar | `POST .../calendar/search` |
| Calendar | `POST .../calendar/reservations/search` |
| Patient Requests | `POST .../patientRequests/search` |
| Patient Requests | `POST .../patientRequests/create` |
| Patient Requests | `PUT .../patientRequests/{id}/resolve` |
| Patient Requests | `POST .../patientRequests/{id}/attachments/upload-link` |
| Patient Requests | `POST .../patientRequests/{id}/attachments` |
