$ErrorActionPreference = 'Stop'

$ApiBaseDev  = 'https://api.medevio.dev/external/v1'
$ApiBaseProd = 'https://api.medevio.cz/external/v1'
function Resolve-ApiBase([string]$Env) { if ($Env -eq 'prod') { $ApiBaseProd } else { $ApiBaseDev } }

# Konfigurace pres env var (pro Docker / Fly.io); fallback na lokalni cesty
$Port     = if ($env:PORT)     { [int]$env:PORT }     else { 8766 }
$BindHost = if ($env:HOST)     { $env:HOST }          else { 'localhost' }
$DataDir  = if ($env:DATA_DIR) { $env:DATA_DIR }      else { $PSScriptRoot }

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$ConfigFile        = Join-Path $DataDir       'clinics.json'
$PlansFile         = Join-Path $DataDir       'plans.json'
$PlanTemplatesFile = Join-Path $PSScriptRoot  'plan-templates.json'
$HtmlFile          = Join-Path $PSScriptRoot  'medevio-dashboard-live.html'

# Seed clinics.json z env var CLINICS_JSON_SEED (Fly secret) pokud:
#  - soubor neexistuje, NEBO
#  - existuje ale je prazdny ([] nebo 0 B)
# Po pridani kliniky pres UI uz nebude prazdny a env var se ignoruje.
$needSeed = -not (Test-Path $ConfigFile)
if (-not $needSeed) {
    $existing = (Get-Content $ConfigFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $existing -or $existing -eq '[]') { $needSeed = $true }
}
if ($needSeed) {
    if ($env:CLINICS_JSON_SEED_B64) {
        Write-Host "Seeduji $ConfigFile z env CLINICS_JSON_SEED_B64 (base64)"
        $jsonBytes = [Convert]::FromBase64String($env:CLINICS_JSON_SEED_B64)
        [System.IO.File]::WriteAllBytes($ConfigFile, $jsonBytes)
    } elseif ($env:CLINICS_JSON_SEED) {
        Write-Host "Seeduji $ConfigFile z env CLINICS_JSON_SEED"
        [System.IO.File]::WriteAllText($ConfigFile, $env:CLINICS_JSON_SEED, (New-Object System.Text.UTF8Encoding $false))
    } else {
        '[]' | Out-File -FilePath $ConfigFile -Encoding utf8 -NoNewline
        Write-Host "Vytvoren prazdny $ConfigFile"
    }
}
$plansNeedSeed = -not (Test-Path $PlansFile)
if (-not $plansNeedSeed) {
    $existingPlans = (Get-Content $PlansFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $existingPlans -or $existingPlans -eq '[]') { $plansNeedSeed = $true }
}
if ($plansNeedSeed) {
    if ($env:PLANS_JSON_SEED_B64) {
        Write-Host "Seeduji $PlansFile z env PLANS_JSON_SEED_B64 (base64)"
        $plansBytes = [Convert]::FromBase64String($env:PLANS_JSON_SEED_B64)
        [System.IO.File]::WriteAllBytes($PlansFile, $plansBytes)
    } else {
        '[]' | Out-File -FilePath $PlansFile -Encoding utf8 -NoNewline
    }
}
if (-not (Test-Path $PlanTemplatesFile)) { Write-Host "ERR: chybi $PlanTemplatesFile"; exit 1 }

function Get-Clinics {
    $raw = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($raw | ForEach-Object {
        $en  = if ($null -ne $_.enabled) { [bool]$_.enabled } else { $true }
        $env = if ($_.env) { $_.env } else { 'dev' }
        [PSCustomObject]@{ label = $_.label; slug = $_.slug; token = $_.token; enabled = $en; env = $env }
    })
}

function Save-Clinics([object[]]$List) {
    $json = $List | ConvertTo-Json -Depth 4
    $tmp = "$ConfigFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -Force $tmp $ConfigFile
}

function Invoke-Medevio([string]$Token, [string]$Env, [string]$Method, [string]$Path, [string]$Body = '{}') {
    $base = Resolve-ApiBase $Env
    $headers = @{ 'Authorization' = "Bearer $Token" }
    $m = $Method.ToUpper()
    if ($m -eq 'GET') {
        return Invoke-RestMethod -Uri "$base$Path" -Method GET -Headers $headers
    }
    # PowerShell 5.1 Invoke-RestMethod posila body jako Latin-1 - UTF-8 znaky (cesky text)
    # zlamou serverovou stranu a vrati 500. Posilame raw UTF-8 bytes.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    return Invoke-RestMethod -Uri "$base$Path" -Method $m -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes
}

# Persistent cache pro DONE pozadavky. Soubor /data/cache-done-<slug>-<env>.json,
# v RAM hashtable pro rychly pristup. Pro suspended Fly machine prezije.
# Strategie: vzdy vratime, co mame (i stale). Pokud cache neexistuje/stara, oznacime
# stale=true a kliknuti 'Vc. hotovych' v UI vyvola force refresh.
$script:DoneCache = @{}
$script:DoneCacheTtlHours = 24

function Get-DoneCacheFile([object]$Clinic) {
    $safeName = "$($Clinic.slug)-$($Clinic.env)" -replace '[^a-zA-Z0-9-]', '_'
    return Join-Path $DataDir "cache-done-$safeName.json"
}

function Load-DoneCacheFromDisk([object]$Clinic) {
    $file = Get-DoneCacheFile $Clinic
    if (-not (Test-Path $file)) { return $null }
    try {
        $raw = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        return [PSCustomObject]@{
            items     = @($raw.items)
            fetchedAt = [datetime]::Parse($raw.fetchedAt)
            count     = $raw.count
        }
    } catch {
        Write-Host "  WARN nelze nacist $file : $($_.Exception.Message)"
        return $null
    }
}

function Save-DoneCacheToDisk([object]$Clinic, [object]$Entry) {
    $file = Get-DoneCacheFile $Clinic
    $payload = [PSCustomObject]@{
        slug      = $Clinic.slug
        env       = $Clinic.env
        items     = $Entry.items
        fetchedAt = $Entry.fetchedAt.ToString('o')
        count     = $Entry.count
    }
    $json = $payload | ConvertTo-Json -Depth 12 -Compress
    $tmp = "$file.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -Force $tmp $file
}

function Get-CachedDoneRequests([object]$Clinic, [bool]$ForceRefresh = $false) {
    $key = "$($Clinic.slug)|$($Clinic.env)"
    $now = Get-Date

    # Lazy load z disku do RAM pri prvnim pristupu
    if (-not $script:DoneCache.ContainsKey($key)) {
        $disk = Load-DoneCacheFromDisk $Clinic
        if ($disk) {
            $script:DoneCache[$key] = $disk
            $ageHr = [int]($now - $disk.fetchedAt).TotalHours
            Write-Host "  $($Clinic.slug) DONE nacteno z disku ($($disk.count) pozadavku, stari $ageHr h)"
        }
    }

    $entry = $script:DoneCache[$key]
    $isStale = -not $entry -or (($now - $entry.fetchedAt).TotalHours -ge $script:DoneCacheTtlHours)

    if ($ForceRefresh -or -not $entry) {
        # Bud uzivatel pozadal o refresh, nebo zadna cache neni - musime nacist sync
        $reasonText = if ($ForceRefresh) { 'force refresh' } else { 'no cache' }
        Write-Host "  $($Clinic.slug) DONE refresh ($reasonText)"
        $items = Fetch-AllPatientRequests $Clinic @{ state = 'DONE' }
        $entry = [PSCustomObject]@{
            items     = $items
            fetchedAt = $now
            count     = @($items).Count
        }
        $script:DoneCache[$key] = $entry
        try { Save-DoneCacheToDisk $Clinic $entry } catch { Write-Host "  WARN ukladani cache: $($_.Exception.Message)" }
        $isStale = $false
    } elseif ($isStale) {
        # Cache je stara, ale neco mame - vratime stale, oznacime
        $ageHr = [int]($now - $entry.fetchedAt).TotalHours
        Write-Host "  $($Clinic.slug) DONE stale z cache (stari $ageHr h - klikni 'Vc. hotovych' pro refresh)"
    } else {
        $ageMin = [int]($now - $entry.fetchedAt).TotalMinutes
        Write-Host "  $($Clinic.slug) DONE z cache ($($entry.count) pozadavku, stari $ageMin min, fresh)"
    }

    return [PSCustomObject]@{
        items     = $entry.items
        fetchedAt = $entry.fetchedAt
        count     = $entry.count
        stale     = $isStale
    }
}

function Fetch-AllPatientRequests([object]$Clinic, [hashtable]$Filter = $null, [int]$MaxPages = 50) {
    # Medevio /patientRequests/search ma hard cap limit=100. Strankujeme dokud neni stranka prazdna,
    # nebo dosahneme MaxPages (50 = 5000 zaznamu, bezpecna pojistka proti runaway).
    $all = @()
    $offset = 0
    $pageSize = 100
    for ($page = 0; $page -lt $MaxPages; $page++) {
        $body = @{ pagination = @{ limit = $pageSize; offset = $offset } }
        if ($Filter) { $body.filter = $Filter }
        $bodyJson = $body | ConvertTo-Json -Compress -Depth 5
        try {
            $resp = Invoke-Medevio $Clinic.token $Clinic.env 'POST' "/clinics/$($Clinic.slug)/patientRequests/search" $bodyJson
        } catch {
            Write-Host "  WARN paginace selhala na offset=${offset}: $($_.Exception.Message)"
            break
        }
        $batch = @($resp.data)
        if ($batch.Count -eq 0) { break }
        $all += $batch
        if ($batch.Count -lt $pageSize) { break }   # posledni stranka
        $offset += $pageSize
    }
    return ,$all
}

function Discover-Clinic([string]$Token, [string]$Env) {
    $resp = Invoke-Medevio $Token $Env 'POST' '/clinics/search'
    $first = $resp.data | Select-Object -First 1
    if (-not $first) { throw "Token nemá přístup k žádné klinice" }
    return $first
}

function Fetch-ClinicData([object]$Clinic, [bool]$RefreshDone = $false) {
    $slug  = $Clinic.slug
    $token = $Clinic.token
    $env   = $Clinic.env
    $clinicsResp = Invoke-Medevio $token $env 'POST' '/clinics/search'

    # ACTIVE - vzdy cerstve (typicky < 300, < 3 stranky, < 3 s)
    $activeReqs  = Fetch-AllPatientRequests $Clinic @{ state = 'ACTIVE' }
    Write-Host "  $slug ACTIVE: $(@($activeReqs).Count) (cerstve)"

    # DONE - z cache (24 h TTL), nebo force refresh
    $doneEntry   = Get-CachedDoneRequests $Clinic $RefreshDone
    $doneReqs    = $doneEntry.items
    $allReqs     = @($activeReqs) + @($doneReqs)

    $patsResp    = Invoke-Medevio $token $env 'POST' "/clinics/$slug/patients/search"
    $usrsResp    = Invoke-Medevio $token $env 'POST' "/clinics/$slug/users/search"
    $clinicMeta  = $clinicsResp.data | Where-Object { $_.slug -eq $slug } | Select-Object -First 1
    $label       = if ($clinicMeta) { $clinicMeta.name } else { $Clinic.label }

    $slim = @($allReqs | ForEach-Object {
        $p = $_.patient; $e = $_.userECRF
        [PSCustomObject]@{
            id                = $_.id
            title             = $_.title
            createdAt         = $_.createdAt
            doneAt            = $_.doneAt
            dueDate           = $_.dueDate
            createdByDoctor   = [bool]$_.createdByDoctor
            patientName       = if ($p) { "$($p.name) $($p.surname)".Trim() } else { '' }
            patientSex        = if ($p) { $p.sex } else { $null }
            typeSid           = if ($e) { $e.sid } else { $null }
            typeName          = if ($e) { $e.name } else { $null }
            reservationLength = if ($e) { $e.reservationLength } else { $null }
            priority          = if ($e) { $e.priority } else { $null }
            tagNames          = @($_.tags | ForEach-Object { $_.name })
            clinicSlug        = $slug
            clinicLabel       = $label
            clinicEnv         = $env
        }
    })

    return [PSCustomObject]@{
        slug = $slug; label = $label; env = $env; clinic = $clinicMeta
        patientsCount = @($patsResp.data).Count
        usersCount    = @($usrsResp.data).Count
        requests      = $slim
        cacheInfo     = [PSCustomObject]@{
            doneCount     = $doneEntry.count
            doneFetchedAt = $doneEntry.fetchedAt.ToString('o')
            doneAgeMin    = [int]((Get-Date) - $doneEntry.fetchedAt).TotalMinutes
            doneStale     = [bool]$doneEntry.stale
            activeCount   = @($activeReqs).Count
        }
    }
}

function Build-Payload([string[]]$SelectedSlugs, [bool]$RefreshDone = $false) {
    $all = Get-Clinics | Where-Object { $_.enabled }
    $selected = if ($SelectedSlugs -and $SelectedSlugs.Count -gt 0) {
        @($all | Where-Object { $SelectedSlugs -contains $_.slug })
    } else { @() }

    $clinicResults = @(); $allRequests = @(); $totalPatients = 0; $totalUsers = 0; $errors = @()
    foreach ($c in $selected) {
        try {
            $r = Fetch-ClinicData $c $RefreshDone
            $clinicResults += [PSCustomObject]@{ slug=$r.slug; label=$r.label; env=$r.env; patientsCount=$r.patientsCount; usersCount=$r.usersCount; requestsCount=@($r.requests).Count; cacheInfo=$r.cacheInfo }
            $allRequests   += $r.requests
            $totalPatients += $r.patientsCount
            $totalUsers    += $r.usersCount
        } catch {
            $errors += [PSCustomObject]@{ slug=$c.slug; label=$c.label; error=$_.Exception.Message }
            Write-Host "  CHYBA u $($c.slug): $($_.Exception.Message)"
        }
    }
    [PSCustomObject]@{
        fetchedAt = (Get-Date).ToString('o')
        selectedSlugs = @($selected | ForEach-Object { $_.slug })
        clinics = $clinicResults
        patientsCount = $totalPatients
        usersCount = $totalUsers
        requests = $allRequests
        errors = $errors
    }
}

function Public-ClinicList { @(Get-Clinics | Where-Object { $_.enabled } | ForEach-Object { [PSCustomObject]@{ slug=$_.slug; label=$_.label; env=$_.env } }) }
function Full-ClinicList   { @(Get-Clinics | ForEach-Object { [PSCustomObject]@{ slug=$_.slug; label=$_.label; token=$_.token; enabled=$_.enabled; env=$_.env } }) }

function Read-Body([System.Net.HttpListenerRequest]$Req) {
    if (-not $Req.HasEntityBody) { return $null }
    # HttpListener defaultne pouziva ISO-8859-1 kdyz charset chybi v Content-Type, coz lame ceske znaky.
    # Browsery posilaji JSON v UTF-8, takze to vynutime.
    $sr = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
    try { $txt = $sr.ReadToEnd() } finally { $sr.Close() }
    if (-not $txt) { return $null }
    return $txt | ConvertFrom-Json
}

function Parse-Query([System.Net.HttpListenerRequest]$Req) {
    $h = @{}
    $q = $Req.Url.Query
    if (-not $q -or $q.Length -le 1) { return $h }
    foreach ($p in $q.TrimStart('?').Split('&')) {
        $kv = $p.Split('=', 2)
        if ($kv.Length -eq 2) { $h[[uri]::UnescapeDataString($kv[0])] = [uri]::UnescapeDataString($kv[1]) }
    }
    return $h
}

function Send-JsonArray($Res, $Items, [int]$Status = 200) {
    # Helper pro endpointy vracejici kolekce - PS pipeline strippuje prazdne pole na $null,
    # coz by zlomilo UI ocekavajici pole. Vyhazujeme $null prvky.
    $arr = if ($null -eq $Items) { @() } else { @($Items | Where-Object { $null -ne $_ }) }
    $json = if ($arr.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $arr -Depth 10 -Compress }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Res.StatusCode = $Status
    $Res.ContentType = 'application/json; charset=utf-8'
    $Res.Headers['Cache-Control'] = 'no-store'
    $Res.ContentLength64 = $bytes.Length
    $Res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-Json($Res, $Obj, [int]$Status = 200) {
    $Res.StatusCode = $Status
    if ($null -eq $Obj) { $json = 'null' }
    elseif ($Obj -is [array] -and $Obj.Count -eq 0) { $json = '[]' }
    elseif ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string]) -and -not ($Obj -is [hashtable]) -and -not ($Obj -is [System.Collections.IDictionary]) -and @($Obj).Count -eq 0) { $json = '[]' }
    else {
        $json = ConvertTo-Json -InputObject $Obj -Depth 10 -Compress
        if ($null -eq $json -or $json -eq '') { $json = 'null' }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Res.ContentType = 'application/json; charset=utf-8'
    $Res.Headers['Cache-Control'] = 'no-store'
    $Res.ContentLength64 = $bytes.Length
    $Res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Handle-ClinicCRUD([System.Net.HttpListenerRequest]$Req, [System.Net.HttpListenerResponse]$Res) {
    $method = $Req.HttpMethod
    $q = Parse-Query $Req

    if ($method -eq 'POST') {
        $body = Read-Body $Req
        if (-not $body -or -not $body.token) { Send-Json $Res @{ error = 'Chybí token' } 400; return }
        $token = $body.token.Trim()
        $env = if ($body.env -eq 'prod') { 'prod' } else { 'dev' }
        try { $discovered = Discover-Clinic $token $env }
        catch { Send-Json $Res @{ error = "Token nelze ověřit v ${env}: $($_.Exception.Message)" } 400; return }
        $slug  = $discovered.slug
        $label = if ($body.label) { $body.label } else { $discovered.name }
        $current = Get-Clinics
        if ($current | Where-Object { $_.slug -eq $slug -and $_.env -eq $env }) {
            Send-Json $Res @{ error = "Klinika '$slug' v $env už v configu existuje" } 409; return
        }
        $newClinic = [PSCustomObject]@{ label=$label; slug=$slug; token=$token; enabled=$true; env=$env }
        Save-Clinics @($current + $newClinic)
        Send-Json $Res @{ added = [PSCustomObject]@{ slug=$slug; label=$label; token=$token; enabled=$true; env=$env } }
        return
    }

    if ($method -eq 'PUT') {
        $slug = $q['slug']
        if (-not $slug) { Send-Json $Res @{ error = 'Chybí slug v query' } 400; return }
        $body = Read-Body $Req
        $current = Get-Clinics
        $found = $current | Where-Object { $_.slug -eq $slug }
        if (-not $found) { Send-Json $Res @{ error = "Klinika '$slug' nenalezena" } 404; return }
        $updated = @($current | ForEach-Object {
            if ($_.slug -eq $slug) {
                [PSCustomObject]@{
                    slug    = $_.slug
                    label   = if ($null -ne $body.label)   { $body.label }   else { $_.label }
                    token   = if ($null -ne $body.token)   { $body.token }   else { $_.token }
                    enabled = if ($null -ne $body.enabled) { [bool]$body.enabled } else { $_.enabled }
                    env     = if ($body.env)               { $body.env }     else { $_.env }
                }
            } else { $_ }
        })
        Save-Clinics $updated
        $u = $updated | Where-Object { $_.slug -eq $slug }
        Send-Json $Res @{ updated = $u }
        return
    }

    if ($method -eq 'DELETE') {
        $slug = $q['slug']
        if (-not $slug) { Send-Json $Res @{ error = 'Chybí slug' } 400; return }
        $current = Get-Clinics
        $remaining = @($current | Where-Object { $_.slug -ne $slug })
        if ($remaining.Count -eq $current.Count) { Send-Json $Res @{ error = "Klinika '$slug' nenalezena" } 404; return }
        Save-Clinics $remaining
        Send-Json $Res @{ deleted = $slug }
        return
    }

    Send-Json $Res @{ error = "Metoda $method nepodporovana" } 405
}

# ===== PLANY =====

function Get-PlanTemplates { Get-Content $PlanTemplatesFile -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-Plans         { @(Get-Content $PlansFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
function Save-Plans([object[]]$List) {
    $json = ConvertTo-Json -InputObject $List -Depth 10
    if ($null -eq $json -or $List.Count -eq 0) { $json = '[]' }
    $tmp = "$PlansFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -Force $tmp $PlansFile
}

# Pri vytvareni Medevio requestu potrebujeme userECRFId.
# Pokusime se ho najit pres existujici requesty (cache na klinicku).
function Get-EcrfMap([object]$Clinic) {
    try {
        $resp = Invoke-Medevio $Clinic.token $Clinic.env 'POST' "/clinics/$($Clinic.slug)/patientRequests/search"
        $map = @{}
        foreach ($r in $resp.data) {
            $e = $r.userECRF
            if ($e -and $e.sid -and -not $map.ContainsKey($e.sid)) { $map[$e.sid] = $e.id }
        }
        return $map
    } catch {
        Write-Host "  WARN: Nelze nacist userECRF mapu pro $($Clinic.slug): $($_.Exception.Message)"
        return @{}
    }
}

function Pick-EcrfCandidates([hashtable]$EcrfMap, [string]$Category) {
    # Vraci serazeny seznam kandidatu (multiple SIDs to try). Nektere ECRF maji 404 i kdyz existuje
    # request s nimi vytvoreny - admin je mohl deaktivovat v adminu kliniky.
    $prefs = switch ($Category) {
        'EXAM'        { @('LABORATORY','CHECKUP_KASPAROVA','DIAOBE_ANAMNESTICKY','VSTUPNI_VYSETRENI_VETERINA','APPROVAL_PEDIATRIC_SUB_MEDICAL_RECORDS','DOCTOR_MESSAGE','CHCI_SE_OBJEDNAT_NA_KONZULTACI') }
        'DECISION'    { @('APPROVAL_PEDIATRIC_SUB_MEDICAL_FITNESS','DIAOBE_ANAMNESTICKY','CHCI_SE_OBJEDNAT_NA_KONZULTACI','APPROVAL_SUB_OTHER','DOCTOR_MESSAGE') }
        'LOGISTIC'    { @('CHCI_SE_OBJEDNAT_NA_KONZULTACI','DIAOBE_ANAMNESTICKY','APPROVAL_SUB_OTHER','DOCTOR_MESSAGE') }
        'MEDICATION'  { @('CHCI_SE_OBJEDNAT_NA_KONZULTACI','DIAOBE_ANAMNESTICKY','APPROVAL_SUB_OTHER','DOCTOR_MESSAGE') }
        'APPOINTMENT' { @('CHECKUP_KASPAROVA','VSTUPNI_VYSETRENI_VETERINA','VISIT_DATE_CHANGE','CHCI_SE_OBJEDNAT_NA_KONZULTACI','DOCTOR_MESSAGE') }
        'EDUCATION'   { @('CHECKUP_KASPAROVA','DIAOBE_ANAMNESTICKY','CHCI_SE_OBJEDNAT_NA_KONZULTACI','APPROVAL_SUB_OTHER','DOCTOR_MESSAGE') }
        default       { @('DIAOBE_ANAMNESTICKY','DOCTOR_MESSAGE') }
    }
    $out = @()
    foreach ($p in $prefs) { if ($EcrfMap.ContainsKey($p)) { $out += @{ id = $EcrfMap[$p]; sid = $p } } }
    # Doplnime cokoli zbylo, aby bylo na cem zkousit
    foreach ($k in $EcrfMap.Keys) {
        if (-not ($out | Where-Object { $_.sid -eq $k })) { $out += @{ id = $EcrfMap[$k]; sid = $k } }
    }
    return $out
}

function CalcDueDate([datetime]$Surgery, [int]$OffsetDays) {
    # Medevio API vyzaduje UTC s 'Z' suffixem, nepodporuje +02:00 offset
    return $Surgery.AddDays($OffsetDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function Encode-PdfText([string]$Text) {
    # PDF text content musi escapovat zavorky a backslash
    return ($Text -replace '\\', '\\' -replace '\(', '\(' -replace '\)', '\)')
}

function New-MinimalPdf([string]$Title, [string[]]$Lines) {
    # Generuje validni jednostranny PDF s textovym obsahem.
    # Vraci string (bytes-compatible).
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("BT /F1 14 Tf 50 760 Td (" + (Encode-PdfText $Title) + ") Tj ET")
    $y = 730
    foreach ($l in $Lines) {
        $clean = $l -replace "`r", ""
        foreach ($subline in ($clean -split "`n")) {
            # Wrap dlouhych radku po 95 znacich
            $remaining = $subline
            do {
                $chunk = if ($remaining.Length -le 95) { $remaining; $remaining = '' } else { $remaining.Substring(0, 95); $remaining = $remaining.Substring(95) }
                [void]$sb.AppendLine("BT /F1 9 Tf 50 $y Td (" + (Encode-PdfText $chunk) + ") Tj ET")
                $y -= 12
                if ($y -lt 40) { break }
            } while ($remaining.Length -gt 0)
            if ($y -lt 40) { break }
        }
    }
    $contentStream = $sb.ToString()
    $contentLen = [System.Text.Encoding]::ASCII.GetByteCount($contentStream)

    # Stavime PDF + presne offsety pro xref
    $parts = @()
    $binMark = [string][char]0xE2 + [char]0xE3 + [char]0xCF + [char]0xD3
    $parts += "%PDF-1.4`n%$binMark`n"
    $parts += "1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n"
    $parts += "2 0 obj`n<< /Type /Pages /Kids [3 0 R] /Count 1 >>`nendobj`n"
    $parts += "3 0 obj`n<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /MediaBox [0 0 612 792] /Contents 5 0 R >>`nendobj`n"
    $parts += "4 0 obj`n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>`nendobj`n"
    $parts += "5 0 obj`n<< /Length $contentLen >>`nstream`n$contentStream`nendstream`nendobj`n"

    # Spocitame offsety
    $offsets = @(0)
    $cum = 0
    for ($i = 0; $i -lt 5; $i++) {
        $cum += [System.Text.Encoding]::GetEncoding(28591).GetByteCount($parts[$i])
        $offsets += $cum
    }
    # offsets[0] = 0 (free), [1..5] = byte position before objects 1..5
    # Korekce: chci pozici startu kazdeho obj. Prvni obj zacina na offset[0] = delka prvni casti (header)
    # Misto rekurzivnich vypoctu - prepocitam:
    $headerLen = [System.Text.Encoding]::GetEncoding(28591).GetByteCount($parts[0])
    $obj1Off = $headerLen
    $obj2Off = $obj1Off + [System.Text.Encoding]::GetEncoding(28591).GetByteCount($parts[1])
    $obj3Off = $obj2Off + [System.Text.Encoding]::GetEncoding(28591).GetByteCount($parts[2])
    $obj4Off = $obj3Off + [System.Text.Encoding]::GetEncoding(28591).GetByteCount($parts[3])
    $obj5Off = $obj4Off + [System.Text.Encoding]::GetEncoding(28591).GetByteCount($parts[4])
    $xrefOff = $obj5Off + [System.Text.Encoding]::GetEncoding(28591).GetByteCount($parts[5])

    $xref = "xref`n0 6`n"
    $xref += "0000000000 65535 f`n"
    $xref += ('{0:D10} 00000 n' -f $obj1Off) + "`n"
    $xref += ('{0:D10} 00000 n' -f $obj2Off) + "`n"
    $xref += ('{0:D10} 00000 n' -f $obj3Off) + "`n"
    $xref += ('{0:D10} 00000 n' -f $obj4Off) + "`n"
    $xref += ('{0:D10} 00000 n' -f $obj5Off) + "`n"
    $trailer = "trailer`n<< /Size 6 /Root 1 0 R >>`nstartxref`n$xrefOff`n%%EOF`n"

    $full = ($parts -join '') + $xref + $trailer
    return [System.Text.Encoding]::GetEncoding(28591).GetBytes($full)
}

function Upload-StepContext([object]$Clinic, [string]$RequestId, [object]$Plan, [object]$Step, [object]$Template) {
    # Vytvori PDF prilohu se stitkem kontextem kroku
    $surgery = [datetime]::Parse($Plan.surgeryDate)
    $plannedDue = (CalcDueDate $surgery $Step.offsetDays)
    $title = "Krok lecebneho planu: $($Step.code)"

    $roleCz = @{ PATIENT='Pacient'; GP='Prakticky lekar'; SURGEON='Ortoped'; ANEST='Anesteziolog'; NUTRI='Nutricni terapeut'; COORD='Koordinator' }
    $catCz  = @{ EXAM='Vysetreni'; DECISION='Rozhodnuti'; LOGISTIC='Logistika'; MEDICATION='Medikace'; APPOINTMENT='Termin'; EDUCATION='Edukace' }
    $phaseCz = @{ '0'='Iniciace'; 'A'='Faze A - Pred edukacnim seminarem'; 'B1'='Faze B1 - Navazna pece'; 'B2'='Faze B2 - Predoperacni vysetreni'; 'B3'='Faze B3 - Medikace + anesteziolog'; 'C'='Faze C - Operace + propusteni' }

    $lines = @(
        "Plan: $($Template.title)"
        "Pacient: $($Plan.patientName)"
        "Datum operace: $($surgery.ToString('d. M. yyyy'))"
        ""
        "=== KROK ==="
        "Kod: $($Step.code)"
        "Nazev: $($Step.title)"
        "Faze: $($phaseCz[$Step.phase])"
        "Role: $($roleCz[$Step.role])"
        "Kategorie: $($catCz[$Step.category])"
        "Zavaznost: $($Step.gate)"
        "Posun od operace: D$(if ($Step.offsetDays -ge 0) { '+' })$($Step.offsetDays) dni"
        "Planovany termin: $((Get-Date $plannedDue).ToString('d. M. yyyy'))"
    )
    if ($Step.requires -and @($Step.requires).Count -gt 0) {
        $lines += "Predpoklady: " + (@($Step.requires) -join ', ')
    }
    if ($Step.conditional) {
        $lines += "Podminka: $($Step.conditional)"
    }
    $lines += ""
    $lines += "=== POKYNY PRO PACIENTA ==="
    $lines += $Step.userNote
    $lines += ""
    $lines += "=== METADATA (strojova) ==="
    $meta = @{
        planId = $Plan.id
        templateId = $Plan.templateId
        stepCode = $Step.code
        role = $Step.role
        category = $Step.category
        phase = $Step.phase
        gate = $Step.gate
        offsetDays = $Step.offsetDays
        plannedDue = $plannedDue
        patientId = $Plan.patientId
        clinicSlug = $Plan.clinicSlug
        surgeryDate = $Plan.surgeryDate
        requires = $Step.requires
        conditional = $Step.conditional
        patientVisible = $Step.patientVisible
        snapshotAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress -Depth 6
    $lines += $meta

    $pdfBytes = New-MinimalPdf $title $lines
    if (-not $pdfBytes -or $pdfBytes.Length -lt 100) { throw "PDF generation failed" }

    # Step 1: upload-link
    $linkBody = @{ contentType = 'application/pdf' } | ConvertTo-Json -Compress
    $linkResp = Invoke-Medevio $Clinic.token $Clinic.env 'POST' "/clinics/$($Clinic.slug)/patientRequests/$RequestId/attachments/upload-link" $linkBody
    $uploadUrl = $linkResp.data.url
    $fileHash  = $linkResp.data.fileHash

    # Step 2: PUT na S3
    Invoke-WebRequest -Uri $uploadUrl -Method PUT -Body $pdfBytes -ContentType 'application/pdf' -UseBasicParsing | Out-Null

    # Step 3: register
    $regBody = @{
        contentType = 'application/pdf'
        fileHash = $fileHash
        description = "Lecebny plan - krok $($Step.code) ($($Step.title))"
        categoryType = 'OTHER'
        visibleToPatient = [bool]$Step.patientVisible
    } | ConvertTo-Json -Compress
    $regBytes = [System.Text.Encoding]::UTF8.GetBytes($regBody)
    $regResp = Invoke-RestMethod -Uri "$(Resolve-ApiBase $Clinic.env)/clinics/$($Clinic.slug)/patientRequests/$RequestId/attachments" -Method POST -Headers @{ Authorization = "Bearer $($Clinic.token)" } -ContentType 'application/json; charset=utf-8' -Body $regBytes
    return $regResp.data.id
}

function Try-CreateRequest([object]$Clinic, [string]$PatientId, [string]$EcrfId, [string]$Note, [string]$DueIso, [bool]$Invite) {
    $body = @{
        patientId = $PatientId
        userECRFId = $EcrfId
        userNote = $Note
        dueDate = $DueIso
        shouldInvitePatient = $Invite
    } | ConvertTo-Json -Compress -Depth 4
    # Retry pri 5xx (Medevio dev obcas 500-uje pri rychlem batchi)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $resp = Invoke-Medevio $Clinic.token $Clinic.env 'POST' "/clinics/$($Clinic.slug)/patientRequests/create" $body
            $id = if ($resp.data -and $resp.data.id) { $resp.data.id } elseif ($resp.id) { $resp.id } else { $null }
            if ($id) { return @{ ok = $true; id = $id } }
            return @{ ok = $false; err = 'API nevratil id'; transient = $false }
        } catch {
            $msg = $_.Exception.Message
            $is500 = ($msg -match '\(500\)|Vnit.{1,3}n.{1,3} chyba|Internal Server')
            $is404 = ($msg -match '\(404\)|Nenalezeno|Not Found|UserECRF not found')
            $is400 = ($msg -match '\(400\)|Bad Request|VALIDATION')
            if ($is500 -and $attempt -lt 3) { Start-Sleep -Milliseconds 600; continue }
            return @{ ok = $false; err = $msg; transient = $is500; clientRefuse = ($is404 -or $is400) }
        }
    }
    return @{ ok = $false; err = 'Vycerpan retry'; transient = $true }
}

function Create-PlanInMedevio([object]$Plan, [object]$Clinic, [object]$Template) {
    $ecrfMap = Get-EcrfMap $Clinic
    $surgery = [datetime]::Parse($Plan.surgeryDate)
    $stepReqs = @{}
    $errors = @()
    $isFirst = $true

    foreach ($step in $Template.steps) {
        $candidates = Pick-EcrfCandidates $ecrfMap $step.category
        if ($candidates.Count -eq 0) { $errors += "Krok $($step.code): zadny ECRF v klinice"; continue }

        $dueIso = (CalcDueDate $surgery $step.offsetDays)
        $usedSid = $null; $newId = $null; $allErrs = @()

        foreach ($c in $candidates) {
            $r = Try-CreateRequest $Clinic $Plan.patientId $c.id $step.userNote $dueIso $isFirst
            if ($r.ok) { $newId = $r.id; $usedSid = $c.sid; break }
            $allErrs += "$($c.sid): $($r.err)"
            # Mezi pokusy s ruznymi ECRF chvilku pockame, at neflood-ujeme API
            Start-Sleep -Milliseconds 200
        }

        if ($newId) {
            $attachId = $null
            try {
                $attachId = Upload-StepContext $Clinic $newId $Plan $step $Template
                Write-Host "    + priloha PDF: $attachId"
            } catch {
                Write-Host "    ! priloha selhala: $($_.Exception.Message)"
                $errors += "Krok $($step.code) priloha: $($_.Exception.Message)"
            }
            $stepReqs[$step.code] = [PSCustomObject]@{ requestId = $newId; ecrfSid = $usedSid; dueDate = $dueIso; contextAttachmentId = $attachId }
            $isFirst = $false
            Write-Host "  OK $($step.code) -> $usedSid -> $newId"
        } else {
            $msg = "Krok $($step.code): " + ($allErrs -join ' | ')
            Write-Host "  ERR $msg"
            $errors += $msg
        }
        # Throttle mezi kroky (Medevio dev je citlive na batch)
        Start-Sleep -Milliseconds 250
    }
    return @{ stepReqs = $stepReqs; errors = $errors }
}

# Stahne aktualni stav requestu pres patientRequests/search a vrati doneAt + dueDate.
function Fetch-RequestsByIds([object]$Clinic, [string[]]$RequestIds, [string]$PatientId = $null) {
    # Krome IDs prijima i volitelny patientId filter pro efektivnejsi search
    # (jinak by se musely strankovat vsechny pozadavky kliniky kvuli ID matchi).
    if (-not $RequestIds -or $RequestIds.Count -eq 0) { return @{} }
    try {
        $filter = if ($PatientId) { @{ patientId = $PatientId } } else { $null }
        $allReqs = Fetch-AllPatientRequests $Clinic $filter
        $idSet = @{}
        foreach ($id in $RequestIds) { $idSet[$id] = $true }
        $out = @{}
        foreach ($r in $allReqs) {
            if ($idSet.ContainsKey($r.id)) {
                $out[$r.id] = [PSCustomObject]@{
                    id         = $r.id
                    title      = $r.title
                    createdAt  = $r.createdAt
                    doneAt     = $r.doneAt
                    dueDate    = $r.dueDate
                    userNote   = $r.userNote
                    typeSid    = $r.userECRF.sid
                    typeName   = $r.userECRF.name
                    patientId  = $r.patientId
                    patientName= "$($r.patient.name) $($r.patient.surname)".Trim()
                }
            }
        }
        return $out
    } catch {
        Write-Host "  WARN Fetch-RequestsByIds: $($_.Exception.Message)"
        return @{}
    }
}

function Plan-WithLiveData([object]$Plan, [object]$Template) {
    $clinics = Get-Clinics
    $clinic  = $clinics | Where-Object { $_.slug -eq $Plan.clinicSlug -and $_.env -eq $Plan.clinicEnv } | Select-Object -First 1
    $stepRequestIds = @()
    $stepReqsHash   = @{}
    if ($Plan.stepRequests) {
        foreach ($p in $Plan.stepRequests.PSObject.Properties) {
            $stepReqsHash[$p.Name] = $p.Value
            $stepRequestIds += $p.Value.requestId
        }
    }
    $live = if ($clinic) { Fetch-RequestsByIds $clinic $stepRequestIds $Plan.patientId } else { @{} }
    $surgery = [datetime]::Parse($Plan.surgeryDate)

    $stepDetails = @()
    $doneCount = 0; $totalCount = 0; $overdueCount = 0
    $now = Get-Date
    foreach ($step in $Template.steps) {
        $totalCount++
        $stepReq  = $stepReqsHash[$step.code]
        $reqLive  = if ($stepReq -and $live.ContainsKey($stepReq.requestId)) { $live[$stepReq.requestId] } else { $null }
        $localState = if ($Plan.stepStates -and $Plan.stepStates.PSObject.Properties[$step.code]) { $Plan.stepStates.($step.code).state } else { $null }

        # Planovany datum (z sablony + datum operace) — ne to, co Medevio vraci.
        # Medevio API casto prepisuje dueDate na cas vytvoreni (zvlast u userECRF s requiresReservation=true).
        $plannedDue = (CalcDueDate $surgery $step.offsetDays)
        $isOverdue = $plannedDue -and ([datetime]::Parse($plannedDue) -lt $now)
        $effState = if ($reqLive -and $reqLive.doneAt) {
                        $doneCount++; 'COMPLETED'
                    } elseif ($localState) { $localState }
                    elseif ($isOverdue) {
                        $overdueCount++; 'OVERDUE'
                    } else { 'NOT_STARTED' }
        $localNote = if ($Plan.stepStates -and $Plan.stepStates.PSObject.Properties[$step.code]) { $Plan.stepStates.($step.code).note } else { $null }
        $stepDetails += [PSCustomObject]@{
            code         = $step.code
            title        = $step.title
            role         = $step.role
            category     = $step.category
            phase        = $step.phase
            offsetDays   = $step.offsetDays
            gate         = $step.gate
            requires     = $step.requires
            patientVisible = [bool]$step.patientVisible
            conditional  = $step.conditional
            userNote     = $step.userNote
            localNote    = $localNote
            requestId    = if ($stepReq) { $stepReq.requestId } else { $null }
            doneAt       = if ($reqLive) { $reqLive.doneAt }   else { $null }
            dueDate      = $plannedDue   # planovany termin podle sablony
            actualDueDate = if ($reqLive) { $reqLive.dueDate } else { $null }  # ten, co ulozilo Medevio
            createdAt    = if ($reqLive) { $reqLive.createdAt } else { $null }
            medevioTitle = if ($reqLive) { $reqLive.title }    else { $null }
            medevioNote  = if ($reqLive) { $reqLive.userNote } else { $null }
            state        = $effState
            ecrfSid      = if ($reqLive) { $reqLive.typeSid } elseif ($stepReq) { $stepReq.ecrfSid } else { $null }
            ecrfName     = if ($reqLive) { $reqLive.typeName } else { $null }
        }
    }

    return [PSCustomObject]@{
        id            = $Plan.id
        templateId    = $Plan.templateId
        templateTitle = $Template.title
        patientId     = $Plan.patientId
        patientName   = $Plan.patientName
        clinicSlug    = $Plan.clinicSlug
        clinicEnv     = $Plan.clinicEnv
        clinicLabel   = if ($clinic) { $clinic.label } else { $Plan.clinicSlug }
        surgeryDate   = $Plan.surgeryDate
        notes         = $Plan.notes
        createdAt     = $Plan.createdAt
        progress      = @{ done = $doneCount; total = $totalCount; overdue = $overdueCount }
        steps         = $stepDetails
    }
}

# ===== KONEC PLANY =====

$prefix = "http://${BindHost}:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch { Write-Host "ERR: $($_.Exception.Message)"; exit 1 }
$cnt = (Get-Clinics).Count
Write-Host "Loaded $cnt clinic(s) from $ConfigFile"
Write-Host "Serving on $prefix"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext(); $req = $ctx.Request; $res = $ctx.Response
        $path = $req.Url.AbsolutePath
        Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $($req.HttpMethod) $($req.Url.PathAndQuery)"
        try {
            if ($path -eq '/' -or $path -eq '/index.html') {
                $bytes = [System.IO.File]::ReadAllBytes($HtmlFile)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.Headers['Cache-Control'] = 'no-store'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($path -eq '/api/clinics' -and $req.HttpMethod -eq 'GET') {
                Send-JsonArray $res (Public-ClinicList)
            }
            elseif ($path -eq '/api/clinics/full' -and $req.HttpMethod -eq 'GET') {
                Send-JsonArray $res (Full-ClinicList)
            }
            elseif ($path -eq '/api/clinics') {
                Handle-ClinicCRUD $req $res
            }
            elseif ($path -eq '/api/plan-templates' -and $req.HttpMethod -eq 'GET') {
                $raw = Get-Content $PlanTemplatesFile -Raw -Encoding UTF8
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
                $res.StatusCode = 200
                $res.ContentType = 'application/json; charset=utf-8'
                $res.Headers['Cache-Control'] = 'no-store'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($path -eq '/api/plans' -and $req.HttpMethod -eq 'GET') {
                $q = Parse-Query $req
                $templates = Get-PlanTemplates
                $plans = Get-Plans
                if ($q['clinicSlug']) { $plans = @($plans | Where-Object { $_.clinicSlug -eq $q['clinicSlug'] }) }
                if ($q['patientId'])  { $plans = @($plans | Where-Object { $_.patientId  -eq $q['patientId']  }) }
                $out = @()
                foreach ($p in $plans) {
                    $myTpl = $null
                    foreach ($t in $templates) { if ($t.id -eq $p.templateId) { $myTpl = $t; break } }
                    if ($myTpl) { $out += (Plan-WithLiveData $p $myTpl) }
                }
                Send-JsonArray $res $out
            }
            elseif ($path -match '^/api/plans/[a-f0-9-]+$' -and $req.HttpMethod -eq 'GET') {
                $planId = $path.Substring('/api/plans/'.Length)
                $plans = Get-Plans
                $plan = $plans | Where-Object { $_.id -eq $planId } | Select-Object -First 1
                if (-not $plan) { Send-Json $res @{ error = 'Plan not found' } 404 }
                else {
                    $templates = Get-PlanTemplates
                    $tpl = $templates | Where-Object { $_.id -eq $plan.templateId } | Select-Object -First 1
                    if (-not $tpl) { Send-Json $res @{ error = 'Template not found' } 404 }
                    else { Send-Json $res (Plan-WithLiveData $plan $tpl) }
                }
            }
            elseif ($path -eq '/api/plans' -and $req.HttpMethod -eq 'POST') {
                $body = Read-Body $req
                if (-not $body.templateId -or -not $body.patientId -or -not $body.clinicSlug -or -not $body.surgeryDate) {
                    Send-Json $res @{ error = 'Vyzaduje templateId, patientId, clinicSlug, surgeryDate' } 400
                } else {
                    $templates = Get-PlanTemplates
                    $tpl = $templates | Where-Object { $_.id -eq $body.templateId } | Select-Object -First 1
                    if (-not $tpl) { Send-Json $res @{ error = "Sablona '$($body.templateId)' nenalezena" } 404 }
                    else {
                        $clinics = Get-Clinics
                        $clinicEnv = if ($body.clinicEnv) { $body.clinicEnv } else { 'dev' }
                        $clinic = $clinics | Where-Object { $_.slug -eq $body.clinicSlug -and $_.env -eq $clinicEnv } | Select-Object -First 1
                        if (-not $clinic) { Send-Json $res @{ error = "Klinika '$($body.clinicSlug)' v $clinicEnv nenalezena" } 404 }
                        else {
                            $planId = [guid]::NewGuid().ToString()
                            $newPlan = [PSCustomObject]@{
                                id = $planId
                                templateId = $body.templateId
                                patientId = $body.patientId
                                patientName = if ($body.patientName) { $body.patientName } else { '' }
                                clinicSlug = $body.clinicSlug
                                clinicEnv = $clinicEnv
                                surgeryDate = $body.surgeryDate
                                notes = if ($body.notes) { $body.notes } else { '' }
                                createdAt = (Get-Date).ToString('o')
                                stepRequests = @{}
                                stepStates = @{}
                            }
                            $created = Create-PlanInMedevio $newPlan $clinic $tpl
                            $newPlan.stepRequests = $created.stepReqs
                            $current = Get-Plans
                            Save-Plans @($current + $newPlan)
                            $resp = [PSCustomObject]@{ planId = $planId; createdSteps = $created.stepReqs.Count; errors = $created.errors }
                            Send-Json $res $resp
                        }
                    }
                }
            }
            elseif ($path -match '^/api/plans/[a-f0-9-]+$' -and $req.HttpMethod -eq 'PATCH') {
                $planId = $path.Substring('/api/plans/'.Length)
                $body = Read-Body $req
                $plans = Get-Plans
                $found = $plans | Where-Object { $_.id -eq $planId }
                if (-not $found) { Send-Json $res @{ error = 'Plan not found' } 404 }
                else {
                    $updated = @($plans | ForEach-Object {
                        if ($_.id -eq $planId) {
                            if ($null -ne $body.surgeryDate) { $_.surgeryDate = $body.surgeryDate }
                            if ($null -ne $body.notes)       { $_.notes = $body.notes }
                            if ($null -ne $body.patientName) { $_.patientName = $body.patientName }
                            if ($body.stepStates) {
                                if (-not $_.stepStates) { $_ | Add-Member -NotePropertyName stepStates -NotePropertyValue @{} -Force }
                                foreach ($p in $body.stepStates.PSObject.Properties) {
                                    $_.stepStates | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                                }
                            }
                        }
                        $_
                    })
                    Save-Plans $updated
                    Send-Json $res @{ updated = $planId }
                }
            }
            elseif ($path -match '^/api/plans/[a-f0-9-]+/steps/[A-Z0-9-]+/resolve$' -and $req.HttpMethod -eq 'POST') {
                $parts = $path -split '/'
                $planId = $parts[3]; $stepCode = $parts[5]
                $plans = Get-Plans
                $plan = $plans | Where-Object { $_.id -eq $planId } | Select-Object -First 1
                if (-not $plan) { Send-Json $res @{ error = 'Plán nenalezen' } 404 }
                else {
                    $sr = $plan.stepRequests.PSObject.Properties[$stepCode]
                    if (-not $sr) { Send-Json $res @{ error = "Krok $stepCode nemá v plánu Medevio request" } 404 }
                    else {
                        $clinics = Get-Clinics
                        $clinic = $clinics | Where-Object { $_.slug -eq $plan.clinicSlug -and $_.env -eq $plan.clinicEnv } | Select-Object -First 1
                        if (-not $clinic) { Send-Json $res @{ error = 'Klinika nenalezena' } 404 }
                        else {
                            $reqId = $sr.Value.requestId
                            try {
                                Invoke-Medevio $clinic.token $clinic.env 'PUT' "/clinics/$($clinic.slug)/patientRequests/$reqId/resolve" '{}' | Out-Null
                                Send-Json $res @{ resolved = $stepCode; requestId = $reqId }
                            } catch { Send-Json $res @{ error = $_.Exception.Message } 500 }
                        }
                    }
                }
            }
            elseif ($path -match '^/api/plans/[a-f0-9-]+/steps/[A-Z0-9-]+$' -and $req.HttpMethod -eq 'PATCH') {
                # Update local stepStates entry (state, note)
                $parts = $path -split '/'
                $planId = $parts[3]; $stepCode = $parts[5]
                $body = Read-Body $req
                $plans = Get-Plans
                $plan = $plans | Where-Object { $_.id -eq $planId } | Select-Object -First 1
                if (-not $plan) { Send-Json $res @{ error = 'Plán nenalezen' } 404 }
                else {
                    $updated = @($plans | ForEach-Object {
                        if ($_.id -eq $planId) {
                            if (-not $_.stepStates) { $_ | Add-Member -NotePropertyName stepStates -NotePropertyValue (@{}) -Force }
                            $cur = if ($_.stepStates.PSObject.Properties[$stepCode]) { $_.stepStates.($stepCode) } else { [PSCustomObject]@{} }
                            $newSt = [PSCustomObject]@{
                                state = if ($null -ne $body.state) { $body.state } elseif ($cur.state) { $cur.state } else { $null }
                                note  = if ($null -ne $body.note)  { $body.note }  elseif ($cur.note)  { $cur.note }  else { '' }
                            }
                            $_.stepStates | Add-Member -NotePropertyName $stepCode -NotePropertyValue $newSt -Force
                        }
                        $_
                    })
                    Save-Plans $updated
                    Send-Json $res @{ updated = $stepCode }
                }
            }
            elseif ($path -match '^/api/plans/[a-f0-9-]+$' -and $req.HttpMethod -eq 'DELETE') {
                $planId = $path.Substring('/api/plans/'.Length)
                $plans = Get-Plans
                $remaining = @($plans | Where-Object { $_.id -ne $planId })
                if ($remaining.Count -eq $plans.Count) { Send-Json $res @{ error = 'Plan not found' } 404 }
                else { Save-Plans $remaining; Send-Json $res @{ deleted = $planId } }
            }
            elseif ($path -eq '/api/plan-items' -and $req.HttpMethod -eq 'GET') {
                # Aggregate all steps from all plans
                $templates = Get-PlanTemplates
                $plans = Get-Plans
                $items = @()
                foreach ($plan in $plans) {
                    $tpl = $templates | Where-Object { $_.id -eq $plan.templateId } | Select-Object -First 1
                    if (-not $tpl) { continue }
                    $detailed = Plan-WithLiveData $plan $tpl
                    foreach ($step in $detailed.steps) {
                        $items += [PSCustomObject]@{
                            planId       = $plan.id
                            templateId   = $plan.templateId
                            templateTitle= $tpl.title
                            patientId    = $plan.patientId
                            patientName  = $plan.patientName
                            clinicSlug   = $plan.clinicSlug
                            clinicEnv    = $plan.clinicEnv
                            clinicLabel  = $detailed.clinicLabel
                            surgeryDate  = $plan.surgeryDate
                            stepCode     = $step.code
                            stepTitle    = $step.title
                            role         = $step.role
                            category     = $step.category
                            phase        = $step.phase
                            offsetDays   = $step.offsetDays
                            gate         = $step.gate
                            patientVisible = $step.patientVisible
                            requestId    = $step.requestId
                            doneAt       = $step.doneAt
                            dueDate      = $step.dueDate
                            createdAt    = $step.createdAt
                            state        = $step.state
                        }
                    }
                }
                Send-JsonArray $res $items
            }
            elseif ($path -eq '/api/patients' -and $req.HttpMethod -eq 'GET') {
                $q = Parse-Query $req
                if (-not $q['clinicSlug']) { Send-Json $res @{ error = 'Vyzaduje ?clinicSlug=' } 400 }
                else {
                    $env = if ($q['clinicEnv']) { $q['clinicEnv'] } else { 'dev' }
                    $clinics = Get-Clinics
                    $clinic = $clinics | Where-Object { $_.slug -eq $q['clinicSlug'] -and $_.env -eq $env } | Select-Object -First 1
                    if (-not $clinic) { Send-Json $res @{ error = 'Klinika nenalezena' } 404 }
                    else {
                        try {
                            $resp = Invoke-Medevio $clinic.token $clinic.env 'POST' "/clinics/$($clinic.slug)/patients/search"
                            $out = @($resp.data | ForEach-Object { [PSCustomObject]@{ id=$_.id; name=$_.name; surname=$_.surname; identificationNumber=$_.identificationNumber; sex=$_.sex; dob=$_.dob } })
                            Send-JsonArray $res $out
                        } catch { Send-Json $res @{ error = $_.Exception.Message } 500 }
                    }
                }
            }
            elseif ($path -match '^/api/admin/cache-upload/([a-zA-Z0-9_-]+)$' -and $req.HttpMethod -eq 'POST') {
                # Adminskeho-only endpoint pro nahrani cache souboru. Vyzaduje
                # X-Admin-Token header shodny s env ADMIN_TOKEN.
                $providedToken = $req.Headers['X-Admin-Token']
                if (-not $env:ADMIN_TOKEN) { Send-Json $res @{ error = 'ADMIN_TOKEN nenastaveno' } 503 }
                elseif ($providedToken -ne $env:ADMIN_TOKEN) { Send-Json $res @{ error = 'Neplatny X-Admin-Token' } 403 }
                else {
                    $safeName = $matches[1]
                    if ($safeName -notmatch '^[a-zA-Z0-9_-]+$') { Send-Json $res @{ error = 'Neplatne jmeno' } 400 }
                    else {
                        # Cti raw bytes
                        $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                        $body = $sr.ReadToEnd(); $sr.Close()
                        $file = Join-Path $DataDir "cache-done-$safeName.json"
                        [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding $false))
                        # Invalidate in-memory cache (nacte se z disku pri pristim pristupu)
                        $script:DoneCache.Clear()
                        Write-Host "  ADMIN upload: $file ($($body.Length) chars)"
                        Send-Json $res @{ uploaded = $safeName; bytes = $body.Length }
                    }
                }
            }
            elseif ($path -eq '/api/data' -and $req.HttpMethod -eq 'GET') {
                $q = Parse-Query $req
                $slugs = @()
                if ($q.ContainsKey('slugs') -and $q['slugs']) { $slugs = $q['slugs'].Split(',') | Where-Object { $_ } }
                $refreshDone = $q.ContainsKey('refreshDone') -and ($q['refreshDone'] -eq '1' -or $q['refreshDone'] -eq 'true')
                Send-Json $res (Build-Payload $slugs $refreshDone)
            }
            else {
                $res.StatusCode = 404
                $b = [System.Text.Encoding]::UTF8.GetBytes('Not found')
                $res.OutputStream.Write($b, 0, $b.Length)
            }
        }
        catch {
            Write-Host "  chyba: $($_.Exception.Message)"
            try { Send-Json $res @{ error = $_.Exception.Message } 500 } catch {}
        }
        finally { try { $res.OutputStream.Close() } catch {} }
    }
}
finally { $listener.Stop(); $listener.Close() }
