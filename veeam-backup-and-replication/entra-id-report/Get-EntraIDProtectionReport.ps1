<#
.SYNOPSIS
    Generates a comprehensive Entra ID Protection Report from Veeam Backup & Replication.

.DESCRIPTION
    Queries the VeeamBackup PostgreSQL database and dedicated veeamrepository_* databases
    to produce a full report of Entra ID backup sessions, object-type counts, and granular
    per-object inventory (Users, Groups, Applications, Service Principals, etc.).

    Outputs:
    - CSV exports (sessions, object counts, protected objects)
    - Interactive HTML dashboard with KPI widgets, charts, and AG Grid data tables

.PARAMETER ExportCsv
    Set to $true to export CSV files. Default: $true

.PARAMETER ExportHtml
    Set to $true to generate the interactive HTML dashboard. Default: $true

.PARAMETER ExportPath
    Base path for CSV output. Default: C:\temp\EntraID_Protection_Report.csv

.PARAMETER HtmlPath
    Path for the HTML dashboard. Default: C:\temp\EntraID_Protection_Dashboard.html

.NOTES
    NAME:    Get-EntraIDProtectionReport.ps1
    VERSION: 1.0
    AUTHOR:  Jorge de la Cruz
    TWITTER: @jorgedelacruz
    GITHUB:  https://github.com/jorgedlcruz

    REQUIREMENTS:
    - PowerShell 5.1+
    - psql.exe (PostgreSQL client, bundled with Veeam Backup & Replication)
    - Network access to the local PostgreSQL instance

.LINK
    https://jorgedelacruz.uk/
    https://github.com/jorgedlcruz/veeam-html-reporting
#>

# ---------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------
[bool]$ExportCsv  = $true
[bool]$ExportHtml = $true

[string]$ExportPath = "C:\temp\EntraID_Protection_Report.csv"
[string]$HtmlPath   = "C:\temp\EntraID_Protection_Dashboard.html"

# Email Configuration (Microsoft Graph API)
[bool]$SendEmail     = $false
$RecipientEmail      = "YOUREMAIL@YOURDOMAIN.com"
$TenantId            = "YOURTENANT.onmicrosoft.com"
$ClientId            = "YOURTENANTID"
$ClientSecretPlain   = "YOURCLIENTSECRETFORMAILAPP"

# PostgreSQL connection
$PsqlInstallPath = "C:\Program Files\PostgreSQL"   # Root folder where PostgreSQL is installed
$DbUser = "postgres"
$DbName = "VeeamBackup"
$DbHost = "localhost"
$DbPort = "5432"

# Time range - how many days of history to include
[int]$LastDays = 30

# ---------------------------------------------------------
# INITIALIZATION
# ---------------------------------------------------------
$ErrorActionPreference = "Continue"

function Write-TS([string]$msg) {
    $ts = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$ts] $msg"
}

# Compute date cutoff
$cutoffDate = (Get-Date).AddDays(-$LastDays).ToString("yyyy-MM-dd")
Write-TS "Report period: last $LastDays days (since $cutoffDate)"

# Find psql.exe
$PsqlPath = Get-ChildItem -Path $PsqlInstallPath -Recurse -Filter "psql.exe" `
    -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

if (-not $PsqlPath) {
    Write-Error "Could not find psql.exe in $PsqlInstallPath."
    return
}

# Ensure output directory exists
$outDir = Split-Path $ExportPath
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

# Helper: run a COPY ... TO STDOUT query and save to CSV
function Invoke-PsqlCopy {
    param([string]$Query, [string]$OutFile, [string]$Database = $DbName)
    $copyCmd    = "COPY ($Query) TO STDOUT WITH CSV HEADER"
    $tmpSqlFile = Join-Path $env:TEMP "veeam_entraid_$([guid]::NewGuid()).sql"
    $copyCmd | Out-File -FilePath $tmpSqlFile -Encoding utf8
    $od = Split-Path $OutFile
    if ($od -and -not (Test-Path $od)) { New-Item -ItemType Directory -Path $od | Out-Null }
    & $PsqlPath -U $DbUser -h $DbHost -p $DbPort -d $Database -f $tmpSqlFile | Out-File -FilePath $OutFile -Encoding utf8
    $exitCode = $LASTEXITCODE
    if (Test-Path $tmpSqlFile) { Remove-Item $tmpSqlFile }
    return $exitCode
}

# Helper: run a query and return pipe-separated output lines
function Invoke-PsqlQuery {
    param([string]$Query, [string]$Database = $DbName)
    $tmpSqlFile = Join-Path $env:TEMP "veeam_entraid_$([guid]::NewGuid()).sql"
    $Query | Out-File -FilePath $tmpSqlFile -Encoding utf8
    $output = & $PsqlPath -U $DbUser -h $DbHost -p $DbPort -d $Database -A -t -F "|" -f $tmpSqlFile 2>&1
    if (Test-Path $tmpSqlFile) { Remove-Item $tmpSqlFile }
    return $output
}

# =========================================================
# =========================================================
# SECTION 1: JOB SESSIONS
# =========================================================
Write-TS "Detecting VBR version based on view names..."
$viewCheckQuery = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'dis.jobsessionsview';"
$viewCheckOutput = Invoke-PsqlQuery -Query $viewCheckQuery
if ($viewCheckOutput -eq "1") {
    $viewPrefix = "dis"
    Write-TS "  Detected VBR v12.4+ (using 'dis' schema)"
} else {
    $viewPrefix = "wmiserver"
    Write-TS "  Detected VBR v12.3 or older (using 'wmiserver' schema)"
}

Write-TS "Querying Entra ID job sessions..."

$sqlSessions = @"
SELECT
    js.id                                           AS "Session_ID",
    js.job_id                                       AS "Job_ID",
    CAST(js.job_name AS TEXT)                       AS "Job_Name",
    CASE js.job_type
        WHEN 78    THEN 'Tenant Users Backup'
        WHEN 13000 THEN 'Tenant Logs/Copy'
        WHEN 13003 THEN 'Copy Job'
        ELSE 'Other (' || js.job_type || ')'
    END                                             AS "Job_Type_Desc",
    js.job_type                                     AS "Job_Type_Code",
    js.platform                                     AS "Platform_Code",
    CASE js.result
        WHEN  0 THEN 'Success'
        WHEN  1 THEN 'Warning'
        WHEN  2 THEN 'Failed'
        WHEN -1 THEN 'In Progress'
        ELSE 'Unknown'
    END                                             AS "Result",
    CASE 
        WHEN js.result = 0 THEN ''
        ELSE COALESCE(
            (SELECT CAST(sl.title AS TEXT)
             FROM "backup.model.backuptasksessionsview" ts
             JOIN sessionlog sl ON sl.sessionid = ts.id
             WHERE ts.session_id = js.id AND sl.status = js.result
               AND CAST(sl.title AS TEXT) NOT LIKE 'Processing finished%'
               AND CAST(sl.title AS TEXT) NOT LIKE 'Job finished%'
               AND CAST(sl.title AS TEXT) NOT LIKE 'Processing %'
             ORDER BY sl.starttimeutc DESC LIMIT 1),
            CAST(js.reason AS TEXT),
            CAST(js.last_log_entry AS TEXT)
        )
    END                                             AS "Reason",
    TO_CHAR(js.creation_time, 'YYYY-MM-DD HH24:MI:SS') AS "Start_Time",
    CASE 
        WHEN js.end_time = '1900-01-01 00:00:00'::timestamp THEN '' 
        ELSE TO_CHAR(js.end_time, 'YYYY-MM-DD HH24:MI:SS') 
    END                                             AS "End_Time",
    ROUND(EXTRACT(EPOCH FROM (
        COALESCE(NULLIF(js.end_time, '1900-01-01 00:00:00'::timestamp), CURRENT_TIMESTAMP) - js.creation_time
    )) / 60, 2)                                     AS "Duration_Minutes",
    js.processed_size                               AS "Processed_Size_Bytes",
    ROUND(js.processed_size / 1048576.0, 2)         AS "Processed_Size_MB",
    js.stored_size                                  AS "Stored_Size_Bytes",
    ROUND(js.stored_size / 1048576.0, 2)            AS "Stored_Size_MB",
    js.is_full                                      AS "Is_Full",
    CAST(js.last_log_entry AS TEXT)                 AS "Last_Log_Entry"
FROM "$($viewPrefix).jobsessionsview" js
WHERE (js.job_type IN (78, 13000, 13003))
  AND (js.platform IN (11, 13))
  AND (CAST(js.job_name AS TEXT) ILIKE '%entra%')
  AND js.creation_time >= '$cutoffDate'::timestamp
ORDER BY js.job_name, js.creation_time DESC
"@

$sessionsPath = $ExportPath
$exitCode = Invoke-PsqlCopy -Query $sqlSessions -OutFile $sessionsPath
$sessionsData = @()
if ($exitCode -eq 0 -and (Test-Path $sessionsPath)) {
    $sessionsData = @(Import-Csv $sessionsPath)
    Write-TS "  Found $($sessionsData.Count) job sessions."
} else {
    Write-Warning "Failed to query sessions."
}

# =========================================================
# SECTION 2: OBJECT-TYPE COUNTS PER SESSION (from sessionlog)
# =========================================================
Write-TS "Querying per-session object-type counts..."

$sqlObjectCounts = @"
SELECT
    js.id                                                               AS "Session_ID",
    CAST(js.job_name AS TEXT)                                           AS "Job_Name",
    CASE js.result
        WHEN  0 THEN 'Success'
        WHEN  1 THEN 'Warning'
        WHEN  2 THEN 'Failed'
        WHEN -1 THEN 'In Progress'
        ELSE 'Unknown'
    END                                                                 AS "Session_Result",
    TO_CHAR(js.creation_time, 'YYYY-MM-DD HH24:MI:SS')                 AS "Session_Start",
    CASE 
        WHEN js.end_time = '1900-01-01 00:00:00'::timestamp THEN '' 
        ELSE TO_CHAR(js.end_time, 'YYYY-MM-DD HH24:MI:SS') 
    END                                                                AS "Session_End",
    ROUND(EXTRACT(EPOCH FROM (
        COALESCE(NULLIF(js.end_time, '1900-01-01 00:00:00'::timestamp), CURRENT_TIMESTAMP) - js.creation_time
    )) / 60, 2)                                                        AS "Duration_Min",
    CAST(ts.object_name AS TEXT)                                        AS "Tenant_Name",
    TRIM(SPLIT_PART(CAST(sl.title AS TEXT), ' collected:', 1))          AS "Object_Type",
    CAST(TRIM(SPLIT_PART(SPLIT_PART(CAST(sl.title AS TEXT), 'collected: ', 2), ' of ', 1)) AS INTEGER) AS "Total_Discovered",
    CAST(TRIM(SPLIT_PART(SPLIT_PART(CAST(sl.title AS TEXT), 'stored to repository: ', 2), ',', 1)) AS INTEGER) AS "Stored_To_Repo",
    CAST(TRIM(SPLIT_PART(SPLIT_PART(CAST(sl.title AS TEXT), 'failed: ', 2), ',', 1)) AS INTEGER) AS "Failed",
    CAST(TRIM(REGEXP_REPLACE(SPLIT_PART(CAST(sl.title AS TEXT), 'incomplete: ', 2), '[^0-9].*', '')) AS INTEGER) AS "Incomplete",
    ROUND(EXTRACT(EPOCH FROM (sl.updatetimeutc - sl.starttimeutc)), 1)  AS "Processing_Seconds"
FROM "$($viewPrefix).jobsessionsview" js
JOIN "backup.model.backuptasksessionsview" ts ON ts.session_id = js.id
JOIN sessionlog sl ON sl.sessionid = ts.id
WHERE (js.job_type IN (78, 13000, 13003))
  AND (js.platform IN (11, 13))
  AND (CAST(js.job_name AS TEXT) ILIKE '%entra%')
  AND CAST(sl.title AS TEXT) ILIKE '%collected:%'
  AND js.creation_time >= '$cutoffDate'::timestamp
ORDER BY js.job_name, js.creation_time DESC, sl.starttimeutc
"@

$objectCountsPath = [System.IO.Path]::ChangeExtension($ExportPath, $null).TrimEnd('.') + "_ObjectCounts.csv"
$exitCode2 = Invoke-PsqlCopy -Query $sqlObjectCounts -OutFile $objectCountsPath
$objectCountsData = @()
if ($exitCode2 -eq 0 -and (Test-Path $objectCountsPath)) {
    $objectCountsData = @(Import-Csv $objectCountsPath)
    Write-TS "  Found $($objectCountsData.Count) object-type count rows."
} else {
    Write-Warning "Failed to query object counts."
}

# =========================================================
# SECTION 3: GRANULAR PROTECTED OBJECTS (from veeamrepository_* DBs)
# =========================================================
Write-TS "Finding Entra ID repository databases..."

$dbQuery = "SELECT datname FROM pg_database WHERE datname LIKE 'veeamrepository_%';"
$dbOutput = Invoke-PsqlQuery -Query $dbQuery -Database "postgres"
$entraDbs = @($dbOutput | Where-Object { $_ -match "veeamrepository_" } | ForEach-Object { $_.Trim() })

# Tenant name mapping
$tenantMapQuery = @"
SELECT
    SUBSTRING(CAST(object_tag AS TEXT) FROM 1 FOR 36) AS tenant_id,
    CAST(display_name AS TEXT) AS tenant_name
FROM "$($viewPrefix).objectrestorepointsview"
WHERE platform = 13
GROUP BY SUBSTRING(CAST(object_tag AS TEXT) FROM 1 FOR 36), CAST(display_name AS TEXT)
"@
$mapOutput = Invoke-PsqlQuery -Query $tenantMapQuery
$tenantMapping = @{}
foreach ($line in $mapOutput) {
    if ($line -match "\|") {
        $parts = $line.Split("|")
        if ($parts.Count -ge 2) { $tenantMapping[$parts[0].Trim()] = $parts[1].Trim() }
    }
}

$protectedObjectsPath = [System.IO.Path]::ChangeExtension($ExportPath, $null).TrimEnd('.') + "_ProtectedObjects.csv"
if (Test-Path $protectedObjectsPath) { Remove-Item $protectedObjectsPath }
"Tenant_Name,Tenant_ID,RestorePoint_Date,Object_Type,Object_Name,Object_Summary,RestorePoint_ID" | Out-File -FilePath $protectedObjectsPath -Encoding utf8

$totalObjRows = 0
foreach ($db in $entraDbs) {
    $tenantId = $db.Replace("veeamrepository_", "")
    $tenantName = if ($tenantMapping.ContainsKey($tenantId)) { $tenantMapping[$tenantId] } else { "Unknown" }
    Write-TS "  Extracting objects for Tenant: $tenantName"

    $safeTN = $tenantName.Replace("'", "''")
    $safeTI = $tenantId.Replace("'", "''")

    $copyQ = @"
COPY (
    SELECT
        '$safeTN' AS "Tenant_Name",
        '$safeTI' AS "Tenant_ID",
        TO_CHAR(rp."CreationTime", 'YYYY-MM-DD HH24:MI:SS') AS "RestorePoint_Date",
        i."Type" AS "Object_Type",
        i."Name" AS "Object_Name",
        i."Summary" AS "Object_Summary",
        rp."Id" AS "RestorePoint_ID"
    FROM "RestorePointItems" rpi
    JOIN "RestorePoints" rp ON rpi."RestorePointId" = rp."Id"
    JOIN "Items" i ON rpi."ItemId" = i."Id"
    WHERE rp."CreationTime" >= '$cutoffDate'::timestamp
    ORDER BY rp."CreationTime" DESC, i."Type", i."Name"
) TO STDOUT WITH CSV;
"@
    $tmpSql = Join-Path $env:TEMP "veeam_entra_obj_$([guid]::NewGuid()).sql"
    $copyQ | Out-File -FilePath $tmpSql -Encoding utf8
    $dbData = & $PsqlPath -U $DbUser -h $DbHost -p $DbPort -d $db -f $tmpSql
    if ($dbData) {
        $dbData | Out-File -FilePath $protectedObjectsPath -Encoding utf8 -Append
        $totalObjRows += $dbData.Count
    }
    Remove-Item $tmpSql -ErrorAction SilentlyContinue
}

$protectedObjectsData = @()
if ($totalObjRows -gt 0 -and (Test-Path $protectedObjectsPath)) {
    $protectedObjectsData = @(Import-Csv $protectedObjectsPath)
    Write-TS "  Extracted $($protectedObjectsData.Count) granular object records."
}

# =========================================================
# CONSOLE SUMMARY
# =========================================================
Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host " Entra ID Protection Report Summary" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "  Sessions found:       $($sessionsData.Count)" -ForegroundColor Cyan
Write-Host "  Object-type rows:     $($objectCountsData.Count)" -ForegroundColor Cyan
Write-Host "  Protected obj records:$($protectedObjectsData.Count)" -ForegroundColor Cyan

if ($ExportCsv) {
    Write-Host ""
    Write-Host "  CSV Exports:" -ForegroundColor Green
    Write-Host "    Sessions:     $sessionsPath"
    Write-Host "    Object Counts:$objectCountsPath"
    Write-Host "    Objects:      $protectedObjectsPath"
}

# =========================================================
# HTML REPORT GENERATION
# =========================================================
if (-not $ExportHtml) {
    Write-TS "HTML export disabled. Done."
    return
}

Write-TS "Generating HTML dashboard..."

# Read locally-downloaded libraries for inline embedding
$libDir = "C:\temp\libs"
$highchartsJs = ""
$agGridJs     = ""

if (Test-Path "$libDir\highcharts.js") {
    $highchartsJs = Get-Content "$libDir\highcharts.js" -Raw -Encoding UTF8
    Write-TS "  Embedded Highcharts ($($highchartsJs.Length) chars)"
} else {
    Write-Warning "Highcharts not found at $libDir\highcharts.js. Charts will not render."
    Write-TS "  Run this once to download: Invoke-WebRequest -Uri 'https://cdn.jsdelivr.net/npm/highcharts@11.4.1/highcharts.js' -OutFile '$libDir\highcharts.js'"
}

if (Test-Path "$libDir\ag-grid.js") {
    $agGridJs = Get-Content "$libDir\ag-grid.js" -Raw -Encoding UTF8
    Write-TS "  Embedded AG Grid ($($agGridJs.Length) chars)"
} else {
    Write-Warning "AG Grid not found at $libDir\ag-grid.js. Data grids will not render."
    Write-TS "  Run this once to download: Invoke-WebRequest -Uri 'https://cdn.jsdelivr.net/npm/ag-grid-community@31.3.2/dist/ag-grid-community.min.js' -OutFile '$libDir\ag-grid.js'"
}

$jsonSessions     = $sessionsData     | ConvertTo-Json -Depth 3 -Compress
$jsonObjCounts    = $objectCountsData | ConvertTo-Json -Depth 3 -Compress
$jsonProtectedObj = $protectedObjectsData | ConvertTo-Json -Depth 3 -Compress

# Guard single-object arrays
if ($sessionsData.Count -eq 1)          { $jsonSessions     = "[$jsonSessions]" }
if ($objectCountsData.Count -eq 1)      { $jsonObjCounts    = "[$jsonObjCounts]" }
if ($protectedObjectsData.Count -eq 1)  { $jsonProtectedObj = "[$jsonProtectedObj]" }

$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Build full self-contained HTML
$htmlParts = New-Object System.Text.StringBuilder
[void]$htmlParts.Append(@"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Entra ID Protection Report</title>
    <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, Roboto, 'Helvetica Neue', Arial, sans-serif; background: #f4f5f7; color: #1a1a2e; line-height: 1.5; font-size: 14px; }
        .container { max-width: 1440px; margin: 0 auto; }
        .main-content { padding: 1.75rem 2rem; }

        /* ── Header ── */
        .header { background: #1a1a2e; color: #fff; padding: 1.25rem 2rem; border-bottom: 3px solid #00b4d8; }
        .header-inner { max-width: 1440px; margin: 0 auto; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 1rem; }
        .header h1 { font-size: 1.25rem; font-weight: 600; letter-spacing: -0.01em; color: #fff; }
        .header .subtitle { margin-top: 2px; color: #8b8fa3; font-size: 0.8rem; font-weight: 400; }
        .header .report-date { text-align: right; }
        .header .report-date .label { font-size: 0.65rem; text-transform: uppercase; letter-spacing: 0.08em; color: #6b7280; }
        .header .report-date .value { font-family: 'Consolas', 'SFMono-Regular', monospace; font-size: 0.9rem; font-weight: 500; color: #d1d5db; }

        /* ── KPI Cards ── */
        .kpi-grid { display: grid; grid-template-columns: repeat(5, 1fr); gap: 1rem; margin-bottom: 1.75rem; }
        .kpi-card { background: #fff; padding: 1.125rem 1.25rem; border-radius: 6px; border: 1px solid #e5e7eb; border-left: 4px solid #d1d5db; position: relative; }
        .kpi-card.accent-blue   { border-left-color: #3b82f6; }
        .kpi-card.accent-green  { border-left-color: #22c55e; }
        .kpi-card.accent-amber  { border-left-color: #f59e0b; }
        .kpi-card.accent-red    { border-left-color: #ef4444; }
        .kpi-card.accent-purple { border-left-color: #8b5cf6; }
        .kpi-label { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.06em; font-weight: 600; color: #6b7280; margin-bottom: 4px; }
        .kpi-value { font-size: 1.75rem; font-weight: 700; color: #111827; line-height: 1.1; }

        /* ── Cards ── */
        .card { background: #fff; border-radius: 6px; border: 1px solid #e5e7eb; }
        .card-header { padding: 0.875rem 1.25rem; border-bottom: 1px solid #f3f4f6; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 0.5rem; }
        .card-header h3 { font-size: 0.85rem; font-weight: 600; color: #374151; text-transform: uppercase; letter-spacing: 0.03em; }
        .card-body { padding: 1.25rem; }
        .card.full-width { grid-column: 1 / -1; }
        .charts-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1.75rem; }

        /* ── Filter Input ── */
        .grid-filter { border: 1px solid #d1d5db; border-radius: 4px; padding: 6px 12px; font-size: 0.8rem; width: 240px; outline: none; font-family: inherit; color: #374151; background: #f9fafb; }
        .grid-filter:focus { border-color: #3b82f6; box-shadow: 0 0 0 2px rgba(59,130,246,0.15); background: #fff; }
        .grid-filter::placeholder { color: #9ca3af; }

        /* ── Status Badges ── */
        .badge { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 0.72rem; font-weight: 600; letter-spacing: 0.02em; border: 1px solid transparent; }
        .badge-success { background: #f0fdf4; color: #15803d; border-color: #bbf7d0; }
        .badge-warning { background: #fffbeb; color: #92400e; border-color: #fde68a; }
        .badge-failed  { background: #fef2f2; color: #991b1b; border-color: #fecaca; }

        /* ── AG Grid Overrides ── */
        .ag-theme-alpine { --ag-font-size: 13px; --ag-header-height: 38px; --ag-row-height: 34px; --ag-header-background-color: #f9fafb; --ag-border-color: #e5e7eb; }
        .ag-theme-alpine .ag-header-cell-label { font-weight: 600; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.03em; color: #6b7280; }
        .ag-theme-alpine .ag-row { font-size: 0.82rem; }

        /* ── Type Dots ── */
        .type-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 8px; vertical-align: middle; }
        .type-dot.user     { background: #3b82f6; }
        .type-dot.group    { background: #8b5cf6; }
        .type-dot.app      { background: #f59e0b; }
        .type-dot.sp       { background: #06b6d4; }
        .type-dot.role     { background: #6366f1; }
        .type-dot.perm     { background: #64748b; }
        .type-dot.policy   { background: #ec4899; }
        .type-dot.other    { background: #9ca3af; }

        /* ── Footer ── */
        .footer { text-align: center; padding: 1.5rem; color: #9ca3af; font-size: 0.75rem; border-top: 1px solid #e5e7eb; }

        /* ── Responsive ── */
        @media (max-width: 1024px) {
            .kpi-grid { grid-template-columns: repeat(3, 1fr); }
            .charts-grid { grid-template-columns: 1fr; }
        }
        @media (max-width: 640px) {
            .kpi-grid { grid-template-columns: repeat(2, 1fr); }
            .main-content { padding: 1rem; }
            .grid-filter { width: 100%; }
        }
    </style>
</head>
<body>
"@)

# Embed Highcharts inline
[void]$htmlParts.Append("<script>")
[void]$htmlParts.Append($highchartsJs)
[void]$htmlParts.Append("</script>`n")

# Embed AG Grid inline
[void]$htmlParts.Append("<script>")
[void]$htmlParts.Append($agGridJs)
[void]$htmlParts.Append("</script>`n")

[void]$htmlParts.Append(@"

    <header class="header">
        <div class="header-inner">
            <div>
                <h1>Entra ID Protection Report</h1>
                <p class="subtitle">Veeam Backup & Replication &mdash; Microsoft Entra ID Backup Analytics</p>
            </div>
            <div class="report-date">
                <p class="label">Data Range</p>
                <p class="value">$cutoffDate &rarr; $reportDate</p>
                <p class="label" style="margin-top:6px;">Last $LastDays day$(if ($LastDays -ne 1) { 's' })</p>
            </div>
        </div>
    </header>

    <div class="container main-content">

        <div class="kpi-grid">
            <div class="kpi-card accent-blue">
                <div class="kpi-label">Total Sessions</div>
                <div class="kpi-value" id="kpiSessions">0</div>
            </div>
            <div class="kpi-card accent-green">
                <div class="kpi-label">Successful</div>
                <div class="kpi-value" id="kpiSuccess" style="color:#15803d">0</div>
            </div>
            <div class="kpi-card accent-amber">
                <div class="kpi-label">Warnings</div>
                <div class="kpi-value" id="kpiWarnings" style="color:#b45309">0</div>
            </div>
            <div class="kpi-card accent-red">
                <div class="kpi-label">Failed</div>
                <div class="kpi-value" id="kpiFailed" style="color:#dc2626">0</div>
            </div>
            <div class="kpi-card accent-purple">
                <div class="kpi-label">Protected Objects</div>
                <div class="kpi-value" id="kpiObjects" style="color:#7c3aed">0</div>
            </div>
        </div>

        <div class="charts-grid">
            <div class="card">
                <div class="card-header"><h3>Session Results Over Time</h3></div>
                <div class="card-body"><div id="chartSessionTimeline" style="height: 300px;"></div></div>
            </div>
            <div class="card">
                <div class="card-header"><h3>Session Result Distribution</h3></div>
                <div class="card-body"><div id="chartResultDist" style="height: 300px;"></div></div>
            </div>
        </div>

        <div class="charts-grid">
            <div class="card full-width">
                <div class="card-header">
                    <h3>Daily Object Type Breakdown (Discovered vs Stored)</h3>
                    <select id="filter-objtypes" class="grid-filter" style="width: 150px; padding: 4px 8px;">
                        <option value="All">All Types</option>
                    </select>
                </div>
                <div class="card-body"><div id="chartObjTypes" style="height: 400px;"></div></div>
            </div>
            <div class="card full-width">
                <div class="card-header"><h3>Session Duration Trend (Main Backups)</h3></div>
                <div class="card-body"><div id="chartDurationTrend" style="height: 340px;"></div></div>
            </div>
        </div>
        
        <div class="card" style="margin-bottom: 1.75rem;">
            <div class="card-header">
                <h3>All Job Sessions (Execution Log)</h3>
                <input type="text" id="filter-sessions" placeholder="Filter sessions..." class="grid-filter">
            </div>
            <div id="gridSessions" class="ag-theme-alpine" style="height: 380px; width: 100%;"></div>
        </div>

        <div class="card" style="margin-bottom: 1.75rem;">
            <div class="card-header">
                <h3>Object Counts Per Session</h3>
                <input type="text" id="filter-counts" placeholder="Filter sessions..." class="grid-filter">
            </div>
            <div id="gridCounts" class="ag-theme-alpine" style="height: 420px; width: 100%;"></div>
        </div>

        <div class="card" style="margin-bottom: 1.75rem;">
            <div class="card-header">
                <h3>All Protected Objects</h3>
                <input type="text" id="filter-objects" placeholder="Search by name, type..." class="grid-filter">
            </div>
            <div id="gridObjects" class="ag-theme-alpine" style="height: 600px; width: 100%;"></div>
        </div>

    </div>

    <footer class="footer">
        Generated by Get-EntraIDProtectionReport.ps1 &mdash; $reportDate
    </footer>

    <script>
        const HC_FONT = "'Segoe UI', -apple-system, BlinkMacSystemFont, Roboto, sans-serif";
        const sessionsRaw     = $jsonSessions;
        const objCountsRaw    = $jsonObjCounts;
        const protectedObjRaw = $jsonProtectedObj;

        const sessions     = (Array.isArray(sessionsRaw) ? sessionsRaw : [sessionsRaw]).flat();
        const objCounts    = (Array.isArray(objCountsRaw) ? objCountsRaw : [objCountsRaw]).flat();
        const protectedObj = (Array.isArray(protectedObjRaw) ? protectedObjRaw : [protectedObjRaw]).flat();

        // KPIs
        document.getElementById('kpiSessions').innerText = sessions.length;
        document.getElementById('kpiSuccess').innerText  = sessions.filter(s => s.Result === 'Success').length;
        document.getElementById('kpiWarnings').innerText = sessions.filter(s => s.Result === 'Warning').length;
        document.getElementById('kpiFailed').innerText   = sessions.filter(s => s.Result === 'Failed').length;

        const latestRP = protectedObj.length > 0 ? protectedObj[0].RestorePoint_Date : null;
        document.getElementById('kpiObjects').innerText = latestRP
            ? ([...new Set(protectedObj.filter(o => o.RestorePoint_Date === latestRP).map(o => o.Object_Name))]).length
            : 0;

        // --- Charts ---
        const sessionsChron = [...sessions].sort((a,b) => a.Start_Time.localeCompare(b.Start_Time));
        const uniqueDates   = [...new Set(sessionsChron.map(s => s.Start_Time.substring(0,10)))];
        const successByDate = uniqueDates.map(d => sessionsChron.filter(s => s.Start_Time.startsWith(d) && s.Result === 'Success').length);
        const warningByDate = uniqueDates.map(d => sessionsChron.filter(s => s.Start_Time.startsWith(d) && s.Result === 'Warning').length);
        const failedByDate  = uniqueDates.map(d => sessionsChron.filter(s => s.Start_Time.startsWith(d) && s.Result === 'Failed').length);

        const HC_BASE = { chart: { style: { fontFamily: HC_FONT } }, credits: { enabled: false }, title: { text: null } };

        if (typeof Highcharts !== 'undefined') {
            Highcharts.setOptions({ chart: { style: { fontFamily: HC_FONT } }, colors: ['#3b82f6','#22c55e','#f59e0b','#ef4444','#8b5cf6','#06b6d4','#ec4899','#64748b'] });

            Highcharts.chart('chartSessionTimeline', {
                ...HC_BASE,
                chart: { type: 'column', style: { fontFamily: HC_FONT }, backgroundColor: 'transparent' },
                xAxis: { categories: uniqueDates, crosshair: true, labels: { style: { fontSize: '11px' } } },
                yAxis: { min: 0, title: { text: 'Sessions', style: { fontSize: '11px' } }, allowDecimals: false, gridLineColor: '#f3f4f6' },
                tooltip: { shared: true, borderColor: '#e5e7eb', shadow: false },
                plotOptions: { column: { stacking: 'normal', borderRadius: 2, borderWidth: 0 } },
                colors: ['#22c55e', '#f59e0b', '#ef4444'],
                series: [
                    { name: 'Success', data: successByDate },
                    { name: 'Warning', data: warningByDate },
                    { name: 'Failed',  data: failedByDate }
                ]
            });

            const resultCounts = {};
            sessions.forEach(s => { resultCounts[s.Result] = (resultCounts[s.Result] || 0) + 1; });
            const cMap = { 'Success': '#22c55e', 'Warning': '#f59e0b', 'Failed': '#ef4444', 'In Progress': '#3b82f6', 'Unknown': '#9ca3af' };

            Highcharts.chart('chartResultDist', {
                ...HC_BASE,
                chart: { type: 'pie', backgroundColor: 'transparent', style: { fontFamily: HC_FONT } },
                plotOptions: { pie: { innerSize: '60%', borderWidth: 0, allowPointSelect: true, cursor: 'pointer',
                    dataLabels: { enabled: true, format: '{point.name}: {point.y}', style: { fontSize: '12px', fontWeight: '500', color: '#374151', textOutline: 'none' } },
                    showInLegend: true } },
                legend: { itemStyle: { fontSize: '12px', fontWeight: '400', color: '#6b7280' } },
                series: [{ name: 'Sessions', colorByPoint: true,
                    data: Object.keys(resultCounts).map(k => ({ name: k, y: resultCounts[k], color: cMap[k] || '#9ca3af' })) }]
            });

            const datesWithCounts = [...new Set(objCounts.map(o => o.Session_Start.substring(0,10)))].sort();
            const dailyLatestSessions = datesWithCounts.map(d => {
                const dayCounts = objCounts.filter(o => o.Session_Start.startsWith(d));
                const latestStart = dayCounts.map(o => o.Session_Start).sort().reverse()[0];
                return dayCounts.filter(o => o.Session_Start === latestStart);
            });
            const allObjTypes = [...new Set(dailyLatestSessions.flat().map(o => o.Object_Type))].sort();
            
            const filterObjTypes = document.getElementById('filter-objtypes');
            if (filterObjTypes) {
                allObjTypes.forEach(t => {
                    const opt = document.createElement('option');
                    opt.value = t;
                    opt.innerText = t;
                    filterObjTypes.appendChild(opt);
                });
            }
            
            const objSeries = [];
            const typeColors = { 'User':'#3b82f6','Group':'#8b5cf6','Application':'#f59e0b','ServicePrincipal':'#06b6d4','UnifiedRoleDefinition':'#6366f1','UnifiedRoleAssignment':'#818cf8','Oauth2PermissionGrant':'#64748b','ConditionalAccessPolicy':'#ec4899','AdministrativeUnit':'#10b981' };

            allObjTypes.forEach((type, i) => {
                const c = typeColors[type] || Highcharts.getOptions().colors[i % 8];
                objSeries.push({
                    name: type + ' (Discovered)',
                    data: dailyLatestSessions.map(sc => { const r = sc.find(o => o.Object_Type === type); return r ? Number(r.Total_Discovered) : 0; }),
                    stack: 'Discovered', color: c, opacity: 0.4
                });
                objSeries.push({
                    name: type + ' (Stored)',
                    data: dailyLatestSessions.map(sc => { const r = sc.find(o => o.Object_Type === type); return r ? Number(r.Stored_To_Repo) : 0; }),
                    stack: 'Stored', color: c, opacity: 1.0
                });
            });

            const chartObj = Highcharts.chart('chartObjTypes', {
                ...HC_BASE,
                chart: { type: 'column', backgroundColor: 'transparent', style: { fontFamily: HC_FONT } },
                xAxis: { categories: datesWithCounts, labels: { style: { fontSize: '11px' } } },
                yAxis: { min: 0, title: { text: 'Objects', style: { fontSize: '11px' } }, allowDecimals: false, gridLineColor: '#f3f4f6' },
                tooltip: { shared: true, borderColor: '#e5e7eb', shadow: false, formatter: function() {
                    let s = '<b>' + this.x + '</b><br/>';
                    this.points.forEach(p => { if(p.y > 0) s += '<span style="color:' + p.color + '">\u25CF</span> ' + p.series.name + ': <b>' + p.y + '</b><br/>'; });
                    return s;
                }},
                plotOptions: { column: { stacking: 'normal', borderWidth: 0 } },
                series: objSeries
            });
            
            if (filterObjTypes) {
                filterObjTypes.addEventListener('change', function() {
                    const sel = this.value;
                    chartObj.series.forEach(series => {
                        if (sel === 'All' || series.name.startsWith(sel + ' ')) {
                            series.setVisible(true, false);
                        } else {
                            series.setVisible(false, false);
                        }
                    });
                    chartObj.redraw();
                });
            }

            const backupSessions = sessionsChron.filter(s => String(s.Job_Type_Code) === '78');
            
            Highcharts.chart('chartDurationTrend', {
                ...HC_BASE,
                chart: { type: 'areaspline', backgroundColor: 'transparent', style: { fontFamily: HC_FONT } },
                xAxis: { categories: backupSessions.map(s => s.Start_Time.substring(5,16)), crosshair: true, labels: { style: { fontSize: '10px' } } },
                yAxis: { title: { text: 'Minutes', style: { fontSize: '11px' } }, min: 0, gridLineColor: '#f3f4f6' },
                tooltip: { valueSuffix: ' min', borderColor: '#e5e7eb', shadow: false },
                plotOptions: { areaspline: { fillColor: { linearGradient: { x1:0,y1:0,x2:0,y2:1 }, stops: [[0,'rgba(59,130,246,0.12)'],[1,'rgba(59,130,246,0)']] }, marker: { radius: 4, fillColor: '#3b82f6' }, lineColor: '#3b82f6', lineWidth: 2 } },
                series: [{ name: 'Duration', data: backupSessions.map(s => Number(s.Duration_Minutes) || 0) }]
            });
        }

        // --- AG Grid ---
        if (typeof agGrid !== 'undefined') {
            function statusCellRenderer(params) {
                const v = params.value;
                const cls = v === 'Success' ? 'badge-success' : v === 'Warning' ? 'badge-warning' : v === 'Failed' ? 'badge-failed' : '';
                return '<span class="badge ' + cls + '">' + v + '</span>';
            }

            const sessColDefs = [
                { field: "Start_Time", headerName: "START TIME", filter: 'agDateColumnFilter', sortable: true, width: 170, sort: 'desc', valueGetter: p => p.data.Start_Time ? new Date(p.data.Start_Time.replace(' ', 'T')) : null, valueFormatter: p => p.data.Start_Time },
                { field: "Job_Name", headerName: "JOB NAME", filter: 'agTextColumnFilter', sortable: true, width: 260 },
                { field: "Job_Type_Desc", headerName: "JOB TYPE", filter: 'agTextColumnFilter', sortable: true, width: 175 },
                { field: "Result", headerName: "RESULT", filter: 'agTextColumnFilter', sortable: true, width: 105, cellRenderer: statusCellRenderer },
                { field: "Duration_Minutes", headerName: "DUR (MIN)", filter: 'agNumberColumnFilter', sortable: true, width: 105, valueGetter: p => Number(p.data.Duration_Minutes) },
                { field: "Processed_Size_MB", headerName: "PROC (MB)", filter: 'agNumberColumnFilter', sortable: true, width: 105, valueGetter: p => Number(p.data.Processed_Size_MB) },
                { field: "Stored_Size_MB", headerName: "STORED (MB)", filter: 'agNumberColumnFilter', sortable: true, width: 115, valueGetter: p => Number(p.data.Stored_Size_MB) },
                { field: "Reason", headerName: "MESSAGE / REASON", filter: 'agTextColumnFilter', sortable: true, flex: 1, minWidth: 250 },
                { field: "Session_ID", headerName: "SESSION ID", filter: 'agTextColumnFilter', sortable: true, hide: true }
            ];

            const sessGrid = agGrid.createGrid(document.querySelector('#gridSessions'), {
                columnDefs: sessColDefs, rowData: [...sessionsChron].reverse(),
                pagination: true, paginationPageSize: 15, animateRows: true,
                defaultColDef: { resizable: true, menuTabs: ['filterMenuTab'] },
                rowSelection: 'single',
                sideBar: { toolPanels: [{ id: 'columns', labelDefault: 'Columns', labelKey: 'columns', iconKey: 'columns', toolPanel: 'agColumnsToolPanel', toolPanelParams: { suppressRowGroups: true, suppressValues: true, suppressPivots: true, suppressPivotMode: true } }] }
            });
            document.getElementById('filter-sessions').addEventListener('input', function() { sessGrid.setGridOption('quickFilterText', this.value); });

            const countsColDefs = [
                { field: "Session_Start", headerName: "SESSION START", filter: 'agDateColumnFilter', sortable: true, width: 170, sort: 'desc', valueGetter: p => p.data.Session_Start ? new Date(p.data.Session_Start.replace(' ', 'T')) : null, valueFormatter: p => p.data.Session_Start },
                { field: "Job_Name", headerName: "JOB NAME", filter: 'agTextColumnFilter', sortable: true, width: 260 },
                { field: "Session_Result", headerName: "RESULT", filter: 'agTextColumnFilter', sortable: true, width: 105, cellRenderer: statusCellRenderer },
                { field: "Tenant_Name", headerName: "TENANT", filter: 'agTextColumnFilter', sortable: true, width: 155 },
                { field: "Object_Type", headerName: "OBJECT TYPE", filter: 'agTextColumnFilter', sortable: true, width: 185 },
                { field: "Total_Discovered", headerName: "DISCOVERED", filter: 'agNumberColumnFilter', sortable: true, width: 115, valueGetter: p => Number(p.data.Total_Discovered) },
                { field: "Stored_To_Repo", headerName: "STORED", filter: 'agNumberColumnFilter', sortable: true, width: 95, valueGetter: p => Number(p.data.Stored_To_Repo) },
                { field: "Failed", headerName: "FAILED", filter: 'agNumberColumnFilter', sortable: true, width: 85,
                  valueGetter: p => Number(p.data.Failed),
                  cellStyle: p => p.value > 0 ? { color: '#dc2626', fontWeight: '600' } : { color: '#9ca3af' } },
                { field: "Incomplete", headerName: "INCOMPLETE", filter: 'agNumberColumnFilter', sortable: true, width: 110, valueGetter: p => Number(p.data.Incomplete) },
                { field: "Duration_Min", headerName: "DUR (MIN)", filter: 'agNumberColumnFilter', sortable: true, width: 105, valueGetter: p => Number(p.data.Duration_Min) },
                { field: "Session_ID", headerName: "SESSION ID", filter: 'agTextColumnFilter', sortable: true, hide: true }
            ];

            const countsGrid = agGrid.createGrid(document.querySelector('#gridCounts'), {
                columnDefs: countsColDefs, rowData: objCounts,
                pagination: true, paginationPageSize: 20, animateRows: true,
                defaultColDef: { resizable: true, menuTabs: ['filterMenuTab'] },
                rowSelection: 'single',
                sideBar: { toolPanels: [{ id: 'columns', labelDefault: 'Columns', labelKey: 'columns', iconKey: 'columns', toolPanel: 'agColumnsToolPanel', toolPanelParams: { suppressRowGroups: true, suppressValues: true, suppressPivots: true, suppressPivotMode: true } }] }
            });
            document.getElementById('filter-counts').addEventListener('input', function() { countsGrid.setGridOption('quickFilterText', this.value); });

            const typeDotMap = { 'User':'user','Group':'group','Application':'app','ServicePrincipal':'sp','UnifiedRoleDefinition':'role','UnifiedRoleAssignment':'role','Oauth2PermissionGrant':'perm','ConditionalAccessPolicy':'policy','AdministrativeUnit':'group' };

            const objColDefs = [
                { field: "RestorePoint_Date", headerName: "RESTORE POINT", filter: 'agDateColumnFilter', sortable: true, width: 170, sort: 'desc', valueGetter: p => p.data.RestorePoint_Date ? new Date(p.data.RestorePoint_Date.replace(' ', 'T')) : null, valueFormatter: p => p.data.RestorePoint_Date },
                { field: "Tenant_Name", headerName: "TENANT", filter: 'agTextColumnFilter', sortable: true, width: 155 },
                { field: "Object_Type", headerName: "TYPE", filter: 'agTextColumnFilter', sortable: true, width: 200,
                  cellRenderer: function(params) {
                      const dot = typeDotMap[params.value] || 'other';
                      return '<span class="type-dot ' + dot + '"></span>' + params.value;
                  }
                },
                { field: "Object_Name", headerName: "OBJECT NAME", filter: 'agTextColumnFilter', sortable: true, flex: 1, minWidth: 250 },
                { field: "Object_Summary", headerName: "SUMMARY", filter: 'agTextColumnFilter', sortable: true, width: 240 },
                { field: "Tenant_ID", headerName: "TENANT ID", filter: 'agTextColumnFilter', sortable: true, hide: true },
                { field: "RestorePoint_ID", headerName: "RP ID", filter: 'agTextColumnFilter', sortable: true, hide: true }
            ];

            const objGrid = agGrid.createGrid(document.querySelector('#gridObjects'), {
                columnDefs: objColDefs, rowData: protectedObj,
                pagination: true, paginationPageSize: 25, animateRows: true,
                defaultColDef: { resizable: true, menuTabs: ['filterMenuTab'] },
                rowSelection: 'single',
                sideBar: { toolPanels: [{ id: 'columns', labelDefault: 'Columns', labelKey: 'columns', iconKey: 'columns', toolPanel: 'agColumnsToolPanel', toolPanelParams: { suppressRowGroups: true, suppressValues: true, suppressPivots: true, suppressPivotMode: true } }] }
            });
            document.getElementById('filter-objects').addEventListener('input', function() { objGrid.setGridOption('quickFilterText', this.value); });
        }
    </script>
</body>
</html>
"@)

# Write the full HTML file
[System.IO.File]::WriteAllText($HtmlPath, $htmlParts.ToString(), [System.Text.Encoding]::UTF8)
Write-TS "HTML Dashboard saved to $HtmlPath"
Write-Host ""
Write-Host "Done! Open the dashboard:" -ForegroundColor Green
Write-Host "  $HtmlPath" -ForegroundColor Cyan

# ---------------------------------------------------------
# SEND EMAIL VIA GRAPH API
# ---------------------------------------------------------
if ($SendEmail) {
    Write-TS "Sending email to $RecipientEmail via MS Graph API..."
    try {
        Import-Module MSAL.PS -ErrorAction Stop
        
        $ClientSecret = ConvertTo-SecureString $ClientSecretPlain -AsPlainText -Force
        
        $appRegistration = @{
            TenantId     = $TenantId
            ClientId     = $ClientId
            ClientSecret = $ClientSecret
        }

        $msalToken = Get-MsalToken @appRegistration -ForceRefresh -ErrorAction Stop

        $emailBody = @"
        <html>
        <body style="font-family: Arial, sans-serif; color: #333;">
            <h2>Veeam Entra ID Protection Report</h2>
            <p>The latest Entra ID protection dashboard and raw CSV exports have been successfully generated.</p>
            <p>Please find the attached ZIP archive containing the offline HTML dashboard and the CSV data files.</p>
            <br/>
            <p><small><i>Generated on $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))</i></small></p>
        </body>
        </html>
"@

        $attachmentsArray = @()
        
        # We must compress the files because the Graph API sendMail endpoint has a strict 3MB limit.
        # The offline HTML dashboard alone is ~2.2MB due to the embedded JavaScript.
        $zipPath = [System.IO.Path]::ChangeExtension($HtmlPath, ".zip")
        $filesToZip = @($HtmlPath, $ExportPath, $objectCountsPath, $protectedObjectsPath) | Where-Object { $null -ne $_ -and (Test-Path $_) }
        
        if ($filesToZip.Count -gt 0) {
            Write-TS "Compressing reports into $zipPath to bypass Graph API 3MB limit..."
            Compress-Archive -Path $filesToZip -DestinationPath $zipPath -Force
            
            if (Test-Path $zipPath) {
                $attachmentsArray += @{
                    "@odata.type"  = "#microsoft.graph.fileAttachment"
                    "name"         = Split-Path $zipPath -Leaf
                    "contentType"  = "application/zip"
                    "contentBytes" = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zipPath))
                }
            }
        }

        $requestBody = @{
            "message" = @{
                "subject" = "[Report] Veeam Entra ID Protection Dashboard"
                "body" = @{
                    "contentType" = "HTML"
                    "content"     = $emailBody
                }
                "toRecipients" = @(
                    @{
                        "emailAddress" = @{ "address" = $RecipientEmail }
                    }
                )
                "attachments" = $attachmentsArray
            }
            "saveToSentItems" = $true
        }

        $bodyJson = $requestBody | ConvertTo-Json -Depth 10 -Compress
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$RecipientEmail/sendMail" `
            -Headers @{ Authorization = $msalToken.CreateAuthorizationHeader() } `
            -Method POST `
            -ContentType "application/json" `
            -Body $bodyJson

        Write-Host "✅ Email sent successfully to $RecipientEmail with the Dashboard attached." -ForegroundColor Green
    } catch {
        Write-Error "Failed to send email: $_"
    }
}
