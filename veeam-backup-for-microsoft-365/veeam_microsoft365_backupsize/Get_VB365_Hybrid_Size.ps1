<#
.SYNOPSIS
    Calculates backup sizes for Veeam Backup for Microsoft 365 objects from hybrid cloud storage.

.DESCRIPTION
    This PowerShell script connects to multiple cloud storage repositories (S3/Wasabi and Azure Blob)
    and calculates the actual backup size per protected object (Mailboxes, Teams, Sites).
    
    It uses PostgreSQL (VeeamBackup365 + cache databases) to map cryptic GUIDs to human-readable 
    names for Organizations, Users, Teams, and Sites.
    
    Outputs include:
    - A CSV report with detailed per-object sizing
    - An interactive HTML dashboard with charts (Highcharts) and data grid (AG Grid)

.PARAMETER Repositories
    Configure in the CONFIGURATION section. Array of hashtables defining S3 and Azure repositories.

.PARAMETER ExportHtml
    Set to $true to generate the HTML analytics dashboard. Default: $true

.PARAMETER MaskNames
    Set to $true to mask user/group/site names for privacy (e.g., "Jor*****"). Default: $false

.OUTPUTS
    - VB365_Hybrid_Report.csv: Detailed per-object backup sizes
    - VB365_Hybrid_Analytics.html: Interactive dashboard with charts and data grid

.EXAMPLE
    .\Get_VB365_Hybrid_Size.ps1
    Runs the script with default settings, prompting for PostgreSQL password if not set.

.EXAMPLE
    $env:PGPASSWORD = "mypassword"; .\Get_VB365_Hybrid_Size.ps1
    Runs the script with password set via environment variable (useful for scheduled tasks).

.NOTES
    NAME: Get_VB365_Hybrid_Size.ps1
    VERSION: 1.0
    AUTHOR: Jorge de la Cruz
    TWITTER: @jorgedelacruz
    GITHUB: https://github.com/jorgedlcruz

    REQUIREMENTS:
    - PowerShell 5.1+ or PowerShell 7
    - Npgsql.dll (included with Veeam Backup for Microsoft 365)
    - Network access to PostgreSQL, S3/Wasabi, and/or Azure Blob Storage

.LINK
    https://jorgedelacruz.uk/
    https://github.com/jorgedlcruz/veeam-html-reporting
#>

# ---------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------
$Repositories = @(
    # --- REPO 1: WASABI FOR EXAMPLE (S3) ---
    @{
        Name      = "REPO-S3-WASABI"       # Must match Repository Name in VB365 (Postgres)
        Type      = "S3"
        Region    = "eu-west-1"
        Bucket    = "veeam-wasabi-vb365"
        Folder    = "1YEAR-SNAPSHOT"       # Root folder inside the bucket
        Endpoint  = "https://s3.eu-west-1.wasabisys.com" # Optional, defaults to Wasabi if omitted
        
        # CREDENTIALS (S3)
        AccessKey = "YOURACCESSKEY"      # <--- PUT KEY HERE
        SecretKey = "YOURSECRETKEY"      # <--- PUT SECRET HERE
    },

    # --- REPO 2: AZURE BLOB FOR EXAMPLE ---
    @{
        Name        = "VEEAM-AZURE-BLOB"    # Must match Repository Name in VB365 (Postgres)
        Type        = "Azure"
        AccountName = "YOURSTORAGEACCOUNTNAME"      # <--- PUT ACCOUNT NAME HERE
        Container   = "YOURCONTAINERNAME"     # <--- PUT CONTAINER NAME HERE
        Folder      = "YOURFOLDERNAME"
        
        # CREDENTIALS (Azure)
        AccountKey  = "YOURACCOUNTKEY"    # <--- PUT BASE64 ACCOUNT KEY HERE
    }
)

# PostgreSQL Settings
$DbHost = "127.0.0.1"
$DbPort = 5432
$DbUser = "postgres"
# $DbPassword = "..." # Or set via environment variable PGPASSWORD or prompt

# Export Settings
[string]$OutputCsv = ".\VB365_Hybrid_Report.csv"
[bool]$ExportHtml = $true         # Set to $false to skip HTML report generation
[bool]$MaskNames = $false         # Set to $true to mask user/group names (e.g., "Jor***")


# ---------------------------------------------------------
# INITIALIZATION
# ---------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-TS([string]$msg) {
    $ts = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$ts] $msg"
}

# Mask names if enabled (show first 3 characters + asterisks)
function Get-MaskedName([string]$name) {
    if (-not $MaskNames -or [string]::IsNullOrWhiteSpace($name)) { return $name }
    if ($name.Length -le 3) { return $name }
    return $name.Substring(0, 3) + ("*" * [Math]::Min(($name.Length - 3), 5))
}

# Load Npgsql
$NpgsqlPath = "C:\Program Files\Veeam\Backup365\Npgsql.dll"
if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.FullName -like "*Npgsql*" })) {
    if (Test-Path $NpgsqlPath) { Add-Type -Path $NpgsqlPath }
    else { Write-Error "Npgsql not found at $NpgsqlPath"; exit }
}

# Handle DB Password
if (-not $env:PGPASSWORD) {
    $pt = Read-Host "Enter PostgreSQL Password" -AsSecureString
    $env:PGPASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pt))
}
$DbPassword = $env:PGPASSWORD

# Global Maps
$global:OrgNameMap = @{}
$global:UserMap = @{}
$global:SiteMap = @{}
$global:TeamMap = @{}
$global:CacheIdMap = @{}

# ---------------------------------------------------------
# HTML REPORT FUNCTION
# ---------------------------------------------------------
function New-HtmlReport {
    param($Results, $OutputFile)
    
    $json = $Results | ConvertTo-Json -Depth 2 -Compress
    $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Veeam Backup 365 Analytics</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://code.highcharts.com/highcharts.js"></script>
    <script src="https://code.highcharts.com/modules/exporting.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/ag-grid-community/dist/ag-grid-community.min.js"></script>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" />
    <style>
        .ag-theme-alpine { --ag-font-size: 13px; --ag-header-height: 40px; } 
    </style>
</head>
<body class="bg-slate-50 text-slate-800">

    <!-- Header -->
    <header class="bg-gradient-to-r from-emerald-600 to-teal-500 text-white p-6 shadow-lg">
        <div class="container mx-auto flex justify-between items-center">
            <div>
                <h1 class="text-3xl font-bold"><i class="fa-solid fa-server mr-3"></i>Veeam Backup 365 Analytics</h1>
                <p class="mt-1 opacity-90 text-sm">Hybrid Storage Report (S3 + Azure)</p>
            </div>
            <div class="text-right">
                <p class="font-mono text-xl" id="totalSizeDisplay">0 GiB</p>
                <p class="text-xs opacity-75">Total Protected Size</p>
            </div>
        </div>
    </header>

    <main class="container mx-auto p-6 space-y-6">
        
        <!-- KPI Cards -->
        <div class="grid grid-cols-1 md:grid-cols-4 gap-6">
            <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200">
                <div class="text-slate-500 text-sm uppercase tracking-wider font-semibold">Total Objects</div>
                <div class="text-3xl font-bold text-slate-700 mt-2" id="kpiObjects">0</div>
            </div>
            <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200">
                <div class="text-slate-500 text-sm uppercase tracking-wider font-semibold">Total Size (GiB)</div>
                <div class="text-3xl font-bold text-emerald-600 mt-2" id="kpiSize">0</div>
            </div>
            <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200">
                <div class="text-slate-500 text-sm uppercase tracking-wider font-semibold">Avg Object Size</div>
                <div class="text-3xl font-bold text-blue-600 mt-2" id="kpiAvg">0 MB</div>
            </div>
            <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200">
                <div class="text-slate-500 text-sm uppercase tracking-wider font-semibold">Repositories</div>
                <div class="text-3xl font-bold text-purple-600 mt-2" id="kpiRepos">0</div>
            </div>
        </div>

        <!-- Charts Row 1 -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200">
                <h3 class="text-lg font-bold mb-4 text-slate-700">Top 10 Largest Objects</h3>
                <div id="chartTop10" style="height: 350px;"></div>
            </div>
            <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200">
                <h3 class="text-lg font-bold mb-4 text-slate-700">Storage Distribution by Type</h3>
                <div id="chartTypeDist" style="height: 350px;"></div>
            </div>
        </div>

        <!-- Charts Row 2 -->
         <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200 lg:col-span-1">
                <h3 class="text-lg font-bold mb-4 text-slate-700">Repository Usage</h3>
                 <div id="chartRepoDist" style="height: 300px;"></div>
            </div>
            <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200 lg:col-span-2">
                 <h3 class="text-lg font-bold mb-4 text-slate-700">Organization Breakdown</h3>
                 <div id="chartOrgDist" style="height: 300px;"></div>
            </div>
        </div>

        <!-- Data Grid -->
        <div class="bg-white rounded-xl shadow-sm border border-slate-200 overflow-hidden">
            <div class="p-4 border-b border-slate-100 flex justify-between items-center bg-slate-50">
                <h3 class="font-bold text-slate-700">Detailed Object List</h3>
                <input type="text" id="filter-text-box" placeholder="Filter..." class="border border-slate-300 rounded px-3 py-1 text-sm focus:outline-none focus:border-emerald-500">
            </div>
            <div id="myGrid" class="ag-theme-alpine" style="height: 600px; width: 100%;"></div>
        </div>

    </main>

    <footer class="text-center py-8 text-slate-400 text-sm">
        Generated by Veeam Backup 365 Hybrid Script • $reportDate
    </footer>

    <script>
        // --- EMBEDDED DATA ---
        const rawData = $json;

        // --- PRE-PROCESS DATA ---
        const data = (Array.isArray(rawData) ? rawData : [rawData]).flat().map(d => ({
            ...d,
            Bytes: Number(d.Bytes),
            GiB: Number(d.GiB)
        }));

        // --- KPIs ---
        const totalBytes = data.reduce((sum, d) => sum + d.Bytes, 0);
        const totalGiB = (totalBytes / (1024**3)).toFixed(2);
        
        document.getElementById('kpiObjects').innerText = data.length.toLocaleString();
        document.getElementById('kpiSize').innerText = totalGiB;
        document.getElementById('totalSizeDisplay').innerText = totalGiB + " GiB";
        
        const avg = data.length ? (totalBytes / data.length / (1024*1024)) : 0;
        document.getElementById('kpiAvg').innerText = avg.toFixed(2) + " MB";
        
        const uniqueRepos = [...new Set(data.map(d => d.RepoName))];
        document.getElementById('kpiRepos').innerText = uniqueRepos.length;

        // --- CHARTS ---
        
        // 1. Top 10 Objects
        const top10 = [...data].sort((a,b) => b.Bytes - a.Bytes).slice(0, 10);
        Highcharts.chart('chartTop10', {
            chart: { type: 'bar' },
            title: { text: null },
            xAxis: { categories: top10.map(d => d.Name), title: { text: null } },
            yAxis: { min: 0, title: { text: 'Size (GiB)', align: 'high' } },
            tooltip: { valueSuffix: ' GiB' },
            plotOptions: { bar: { dataLabels: { enabled: true } } },
            colors: ['#059669'],
            series: [{ name: 'Size', data: top10.map(d => d.GiB) }],
            credits: { enabled: false }
        });

        // 2. Type Dist
        const typeGroup = data.reduce((acc, d) => {
            acc[d.Type] = (acc[d.Type] || 0) + d.Bytes;
            return acc;
        }, {});
        const typeData = Object.keys(typeGroup).map(k => ({ name: k, y: typeGroup[k] }));

        Highcharts.chart('chartTypeDist', {
            chart: { type: 'pie' },
            title: { text: null },
            tooltip: { pointFormat: '<b>{point.percentage:.1f}%</b> ({point.y_formatted})' },
            plotOptions: {
                pie: {
                    allowPointSelect: true,
                    cursor: 'pointer',
                    dataLabels: { enabled: true, format: '<b>{point.name}</b>: {point.percentage:.1f} %' },
                    showInLegend: true
                }
            },
             series: [{
                name: 'Size',
                colorByPoint: true,
                data: typeData.map(d => ({ ...d, y_formatted: (d.y / (1024**3)).toFixed(2) + ' GiB' }))
            }],
            credits: { enabled: false }
        });

        // 3. Repo Dist
        const repoGroup = data.reduce((acc, d) => {
            acc[d.RepoName] = (acc[d.RepoName] || 0) + d.Bytes;
            return acc;
        }, {});
         const repoData = Object.keys(repoGroup).map(k => ({ name: k, y: repoGroup[k] }));
         
          Highcharts.chart('chartRepoDist', {
            chart: { type: 'pie' },
            title: { text: null },
             plotOptions: {
                pie: {
                    innerSize: '50%',
                    dataLabels: { enabled: false },
                    showInLegend: true
                }
            },
            series: [{
                name: 'Size',
                data: repoData.map(d => ({ ...d, y: Number((d.y / (1024**3)).toFixed(2)) }))
            }],
             credits: { enabled: false }
        });
        
        // 4. Organization Breakdown (Top 5 Orgs)
        const orgGroup = data.reduce((acc, d) => {
            acc[d.OrgName] = (acc[d.OrgName] || 0) + d.Bytes;
            return acc;
        }, {});
        const orgData = Object.keys(orgGroup)
            .map(k => ({ name: k, y: orgGroup[k] }))
            .sort((a,b) => b.y - a.y)
            .slice(0, 5);
            
        Highcharts.chart('chartOrgDist', {
             chart: { type: 'column' },
             title: { text: null },
             xAxis: { categories: orgData.map(d => d.name) },
             yAxis: { title: { text: 'GiB' } },
             series: [{
                 name: 'Size',
                 data: orgData.map(d => Number((d.y / (1024**3)).toFixed(2))),
                 color: '#7c3aed'
             }],
             credits: { enabled: false }
        });


        // --- AG GRID ---
        const columnDefs = [
            { field: "RepoName", headerName: "Repository", filter: true, sortable: true },
            { field: "RepoType", headerName: "Type", filter: true, sortable: true, width: 90 },
            { field: "OrgName", headerName: "Organization", filter: true, sortable: true },
            { field: "OrgId", headerName: "Org ID", filter: true, sortable: true, hide: true },
            { field: "Type", headerName: "Obj Type", filter: true, sortable: true, width: 100 },
            { field: "Name", headerName: "Name", filter: true, sortable: true, flex: 1 },
            { field: "GiB", headerName: "Size (GiB)", sortable: true, filter: 'agNumberColumnFilter', width: 110, sort: 'desc' },
            { field: "Id", headerName: "ID", filter: true, sortable: true, hide: true }
        ];

        const gridOptions = {
            columnDefs: columnDefs,
            rowData: data,
            pagination: true,
            paginationPageSize: 20,
            defaultColDef: {
                resizable: true,
                menuTabs: ['filterMenuTab']
            }
        };

        const eGridDiv = document.querySelector('#myGrid');
        const gridApi = agGrid.createGrid(eGridDiv, gridOptions);
        
        // Filter Logic
        document.getElementById('filter-text-box').addEventListener('input', function() {
             gridApi.setGridOption('quickFilterText', document.getElementById('filter-text-box').value);
        });

    </script>
</body>
</html>
"@
    
    $html | Out-File -FilePath $OutputFile -Encoding UTF8
    Write-Host "`nHTML Analytics Report saved to $OutputFile" -ForegroundColor Green
}

# ---------------------------------------------------------
# POSTGRESQL FUNCTIONS
# ---------------------------------------------------------

function Get-VBCacheDbName {
    param([string]$RepoName)
    
    $connStr = "Host=$DbHost;Port=$DbPort;Username=$DbUser;Password=$DbPassword;Database=VeeamBackup365;Timeout=30"
    $conn = New-Object Npgsql.NpgsqlConnection($connStr)
    $conn.Open()
    
    $cacheName = $null
    
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT id, name FROM public.repositories WHERE name = @name"
        $cmd.Parameters.AddWithValue("name", $RepoName) | Out-Null
        
        $reader = $cmd.ExecuteReader()
        if ($reader.Read()) {
            $id = $reader["id"].ToString()
            # Cache DB format is typically "cache_" + id
            if ($id) { $cacheName = "cache_$id" }
        }
        $reader.Close()
    }
    catch {
        Write-Warning "Failed to resolve Cache DB for repo '$RepoName': $_"
    }
    finally {
        $conn.Close()
    }
    
    return $cacheName
}

function Build-GlobalMaps {
    param([string]$CacheDbName)
    
    Write-TS "Building ID Maps (Main DB)..."
    $connStr = "Host=$DbHost;Port=$DbPort;Username=$DbUser;Password=$DbPassword;Database=VeeamBackup365;Timeout=30"
    $conn = New-Object Npgsql.NpgsqlConnection($connStr)
    $conn.Open()

    # 1. Orgs - map both the primary key ID and office_tenant_id to the org name
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT id, office_tenant_id, name FROM public.organizations"
    $r = $cmd.ExecuteReader()
    while ($r.Read()) { 
        $orgName = $r["name"]
        # Map by primary key ID (this is what appears in the S3/Azure folder structure)
        if (-not [string]::IsNullOrWhiteSpace($r["id"])) {
            $global:OrgNameMap[$r["id"].ToString().Replace("-", "").ToLower()] = $orgName
        }
        # Also map by office_tenant_id for backwards compatibility
        if (-not [string]::IsNullOrWhiteSpace($r["office_tenant_id"])) {
            $global:OrgNameMap[$r["office_tenant_id"].ToString().Replace("-", "").ToLower()] = $orgName
        }
    }
    $r.Close()

    # 2. Users
    $cmd.CommandText = "SELECT mailbox_id, display_name FROM public.protected_mailboxes"
    $r = $cmd.ExecuteReader()
    while ($r.Read()) {
        if (-not [string]::IsNullOrWhiteSpace($r["mailbox_id"])) {
            $global:UserMap[$r["mailbox_id"].ToString().Replace("-", "").ToLower()] = $r["display_name"]
        }
    }
    $r.Close()

    # 3. Teams
    $cmd.CommandText = "SELECT team_id, display_name FROM public.protected_teams"
    $r = $cmd.ExecuteReader()
    while ($r.Read()) {
        if (-not [string]::IsNullOrWhiteSpace($r["team_id"])) {
            $global:TeamMap[$r["team_id"].ToString().Replace("-", "").ToLower()] = $r["display_name"]
        }
    }
    $r.Close()

    # 4. Sites
    $cmd.CommandText = "SELECT web_id, title, url FROM public.organization_webs"
    $r = $cmd.ExecuteReader()
    while ($r.Read()) {
        if (-not [string]::IsNullOrWhiteSpace($r["web_id"])) {
            $title = if (-not [string]::IsNullOrWhiteSpace($r["title"])) { $r["title"] } else { $r["url"] }
            $global:SiteMap[$r["web_id"].ToString().Replace("-", "").ToLower()] = $title
        }
    }
    $r.Close()
    $conn.Close()

    # --- Cache DB Mapping ---
    if ($CacheDbName) {
        Write-TS "Mapping additional IDs from Cache DB '$CacheDbName'..."
        try {
            $connStr = "Host=$DbHost;Port=$DbPort;Username=$DbUser;Password=$DbPassword;Database=$CacheDbName;Timeout=30"
            $cConn = New-Object Npgsql.NpgsqlConnection($connStr)
            $cConn.Open()
            
            # --- FIRST: Map Organization IDs from backup.organizations ---
            $cmd = $cConn.CreateCommand()
            $cmd.CommandText = "SELECT id, name FROM backup.organizations"
            $r = $cmd.ExecuteReader()
            while ($r.Read()) {
                if (-not [string]::IsNullOrWhiteSpace($r["id"])) {
                    $cleanId = $r["id"].ToString().Replace("-", "").ToLower()
                    $global:OrgNameMap[$cleanId] = $r["name"]
                }
            }
            $r.Close()
            
            # Map known ID columns to unknown GUIDs (heuristic)
            $cmd.CommandText = "SELECT * FROM backup.web_backups"
            $r = $cmd.ExecuteReader()
            
            while ($r.Read()) {
                $knownName = $null
                $foundAnchors = @()
                
                # Find ALL Anchors first
                for ($i = 0; $i -lt $r.FieldCount; $i++) {
                    if ($r.GetFieldType($i).Name -eq "Guid") {
                        $val = $r.GetValue($i).ToString().Replace("-", "").ToLower()
                        if ($global:SiteMap.ContainsKey($val)) {
                            $foundAnchors += @{ ID = $val; Name = $global:SiteMap[$val] }
                        }
                    }
                }
                
                if ($foundAnchors.Count -eq 1) {
                    $knownName = $foundAnchors[0].Name
                }
                elseif ($foundAnchors.Count -gt 1) {
                    # Heuristic: Pick the Name that appears LEAST often (Minority Rule).
                    # The "Parent" (Site) ID often appears in multiple columns (site_id, root_web_id).
                    # The "Specific" Web ID usually appears once.
                     
                    $groups = $foundAnchors | Group-Object Name | Sort-Object Count
                    $best = $groups[0].Name # Pick lowest count
                     
                    # Debug Log
                    $debugStr = ($groups | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ", "
                    Write-Host "DEBUG: Ambiguous Row. Counts=[$debugStr]. Picking: '$best'" -ForegroundColor Magenta
                     
                    $knownName = $best
                }
                
                # Link Others
                if ($knownName) {
                    for ($i = 0; $i -lt $r.FieldCount; $i++) {
                        if ($r.GetFieldType($i).Name -eq "Guid") {
                            $val = $r.GetValue($i).ToString().Replace("-", "").ToLower()
                            if (-not $global:SiteMap.ContainsKey($val)) {
                                $global:SiteMap[$val] = $knownName # Direct add to Main Map
                            }
                        }
                    }
                }
            }
            $r.Close()
            $cConn.Close()
        }
        catch { Write-Warning "Cache DB skipped: $_" }
    }
}

# ---------------------------------------------------------
# S3 FUNCTIONS
# ---------------------------------------------------------

function New-HmacSHA256([byte[]]$key, [string]$data) {
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $key
    return $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($data))
}

function To-Hex([byte[]]$bytes) {
    ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Get-SigV4Key([string]$secret, [string]$dateStamp, [string]$region, [string]$service) {
    $kDate = New-HmacSHA256 -key ([Text.Encoding]::UTF8.GetBytes("AWS4$secret")) -data $dateStamp
    $kRegion = New-HmacSHA256 -key $kDate -data $region
    $kService = New-HmacSHA256 -key $kRegion -data $service
    $kSigning = New-HmacSHA256 -key $kService -data "aws4_request"
    return $kSigning
}

function Invoke-WasabiListV2 {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$Bucket,
        [Parameter(Mandatory = $true)][string]$AccessKey,
        [Parameter(Mandatory = $true)][string]$SecretKey,
        [Parameter(Mandatory = $false)][string]$Prefix,
        [Parameter(Mandatory = $false)][string]$Delimiter,
        [Parameter(Mandatory = $false)][string]$ContinuationToken,
        [Parameter(Mandatory = $false)][int]$MaxKeys = 1000
    )

    $Region = $Region.Trim()
    $Bucket = $Bucket.Trim()
    $AccessKey = $AccessKey.Trim()
    $SecretKey = $SecretKey.Trim()

    $uri = [Uri]$Endpoint
    $hostHeader = $uri.Host
    $scheme = $uri.Scheme
    $port = $uri.Port

    $amzDate = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $dateStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd")

    # Query params (sorted)
    $q = New-Object System.Collections.Generic.List[System.String]
    $q.Add("list-type=2")
    $q.Add("max-keys=$MaxKeys")
    if ($Prefix) { $q.Add("prefix=$([uri]::EscapeDataString($Prefix))") }
    if ($Delimiter) { $q.Add("delimiter=$([uri]::EscapeDataString($Delimiter))") }
    if ($ContinuationToken) { $q.Add("continuation-token=$([uri]::EscapeDataString($ContinuationToken))") }

    $canonicalQuery = ($q | Sort-Object) -join "&"
    $canonicalUri = "/$Bucket"
    $payloadHash = "UNSIGNED-PAYLOAD"

    $canonicalHeaders = "host:$hostHeader`n" + "x-amz-content-sha256:$payloadHash`n" + "x-amz-date:$amzDate`n"
    $signedHeaders = "host;x-amz-content-sha256;x-amz-date"
    $canonicalRequest = "GET`n$canonicalUri`n$canonicalQuery`n$canonicalHeaders`n$signedHeaders`n$payloadHash"
    $canonicalRequestHash = To-Hex ([System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalRequest)))
    
    $scope = "$dateStamp/$Region/s3/aws4_request"
    $stringToSign = "AWS4-HMAC-SHA256`n$amzDate`n$scope`n$canonicalRequestHash"
    $signingKey = Get-SigV4Key -secret $SecretKey -dateStamp $dateStamp -region $Region -service "s3"
    $signature = To-Hex (New-HmacSHA256 -key $signingKey -data $stringToSign)
    $authHeader = "AWS4-HMAC-SHA256 Credential=$AccessKey/$scope, SignedHeaders=$signedHeaders, Signature=$signature"

    $url = "${scheme}://${hostHeader}"
    if ($port -and $port -ne 443 -and $port -ne 80) { $url += ":$port" }
    $url += "/$Bucket`?$canonicalQuery"

    try {
        $client = New-Object System.Net.Http.HttpClient
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
        $req.Headers.TryAddWithoutValidation("Authorization", $authHeader) | Out-Null
        $req.Headers.TryAddWithoutValidation("x-amz-date", $amzDate) | Out-Null
        $req.Headers.TryAddWithoutValidation("x-amz-content-sha256", $payloadHash) | Out-Null
        $req.Headers.TryAddWithoutValidation("host", $hostHeader) | Out-Null

        $task = $client.SendAsync($req)
        $task.Wait()
        $resp = $task.Result
        $contentBytes = $resp.Content.ReadAsByteArrayAsync().Result
        $contentStr = [System.Text.Encoding]::UTF8.GetString($contentBytes)

        return [pscustomobject]@{
            StatusCode = [int]$resp.StatusCode
            Content    = $contentStr
        }
    }
    catch {
        throw ("S3 LIST FAILED url='{0}' error='{1}'" -f $url, $_.Exception.Message)
    }
}

function Parse-ListObjectsV2Xml {
    param([Parameter(Mandatory = $true)][string]$XmlText)
    [xml]$x = $XmlText
    $ns = New-Object Xml.XmlNamespaceManager($x.NameTable)
    if ($x.DocumentElement.NamespaceURI) { $ns.AddNamespace("s3", $x.DocumentElement.NamespaceURI) } 
    else { $ns.AddNamespace("s3", "http://s3.amazonaws.com/doc/2006-03-01/") }

    $isTrunc = $x.SelectSingleNode("//s3:IsTruncated", $ns)
    $nextTok = $x.SelectSingleNode("//s3:NextContinuationToken", $ns)

    $objs = @()
    foreach ($n in $x.SelectNodes("//s3:Contents", $ns)) {
        $k = $n.SelectSingleNode("s3:Key", $ns).InnerText
        $s = [int64]$n.SelectSingleNode("s3:Size", $ns).InnerText
        $objs += [pscustomobject]@{ Key = $k; Size = $s }
    }
    
    $prefixes = @()
    foreach ($p in $x.SelectNodes("//s3:CommonPrefixes/s3:Prefix", $ns)) {
        $prefixes += $p.InnerText
    }

    $tr = $false
    if ($isTrunc -and $isTrunc.InnerText -eq "true") { $tr = $true }

    return [pscustomobject]@{
        IsTruncated           = $tr
        NextContinuationToken = $(if ($nextTok) { $nextTok.InnerText } else { "" })
        Objects               = $objs
        CommonPrefixes        = $prefixes
    }
}

function Get-WasabiCommonPrefixes {
    param([string]$Endpoint, [string]$Region, [string]$Bucket, [string]$AccessKey, [string]$SecretKey, [string]$Prefix)
    $all = @()
    $token = $null
    while ($true) {
        $r = Invoke-WasabiListV2 -Endpoint $Endpoint -Region $Region -Bucket $Bucket -AccessKey $AccessKey -SecretKey $SecretKey -Prefix $Prefix -Delimiter "/" -ContinuationToken $token
        $p = Parse-ListObjectsV2Xml -XmlText $r.Content
        $all += $p.CommonPrefixes
        if (-not $p.IsTruncated) { break }
        $token = $p.NextContinuationToken
    }
    return $all
}

function Get-WasabiPrefixSizeBytes {
    param([string]$Endpoint, [string]$Region, [string]$Bucket, [string]$AccessKey, [string]$SecretKey, [string]$Prefix)
    $sum = [int64]0
    $token = $null
    while ($true) {
        $r = Invoke-WasabiListV2 -Endpoint $Endpoint -Region $Region -Bucket $Bucket -AccessKey $AccessKey -SecretKey $SecretKey -Prefix $Prefix -ContinuationToken $token
        $p = Parse-ListObjectsV2Xml -XmlText $r.Content
        foreach ($o in $p.Objects) { $sum += $o.Size }
        if (-not $p.IsTruncated) { break }
        $token = $p.NextContinuationToken
    }
    return $sum
}

# ---------------------------------------------------------
# AZURE BLOB FUNCTIONS
# ---------------------------------------------------------

function Compute-AzureHmacSHA256 {
    param([string]$StringData, [string]$KeyBase64)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [Convert]::FromBase64String($KeyBase64)
    [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($StringData)))
}

function Invoke-AzureBlobList {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [string]$Container,
        [string]$Prefix
    )
    
    $date = (Get-Date).ToUniversalTime().ToString("R") # RFC1123
    $version = "2020-04-08" # API Version
    
    # REST Params
    $comp = "list"
    $restype = "container"
    
    # Canonicalized Resources
    # /{account}/{container}\ncomp:list\nprefix:{prefix}\nrestype:container
    $canonRes = "/$AccountName/$Container`ncomp:$comp`nprefix:$Prefix`nrestype:$restype"
    
    # Header Construction
    $headers = "x-ms-date:$date`nx-ms-version:$version"
    
    # String to Sign
    # GET\n\n\n\n\n\n\n\n\n\n\n\n{headers}\n{canonRes}
    $stringToSign = "GET`n`n`n`n`n`n`n`n`n`n`n`n$headers`n$canonRes"
    
    $sig = Compute-AzureHmacSHA256 -StringData $stringToSign -KeyBase64 $AccountKey
    $authParams = "SharedKey ${AccountName}:$sig"
    
    $uri = "https://${AccountName}.blob.core.windows.net/${Container}?restype=container&comp=list&prefix=$Prefix"
    
    $req = New-Object System.Net.Http.HttpClient
    $msg = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $uri)
    
    $msg.Headers.Add("x-ms-date", $date)
    $msg.Headers.Add("x-ms-version", $version)
    $msg.Headers.Add("Authorization", $authParams)
    
    try {
        $resp = $req.SendAsync($msg).Result
        if (-not $resp.IsSuccessStatusCode) {
            Write-Warning "Azure Error: $($resp.StatusCode)"
            return @()
        }
        $xmlContent = $resp.Content.ReadAsStringAsync().Result
        
        # Parse XML
        [xml]$x = $xmlContent
        $blobs = @()
        
        # Use XPath to safely select nodes (handles 0, 1, or many blobs)
        $nodes = $x.SelectNodes("//Blob")
        if ($nodes) {
            foreach ($b in $nodes) {
                # Name is a direct child of Blob
                $name = $b.Name
                # Properties/Content-Length
                $size = [int64]$b.Properties."Content-Length"
                
                $blobs += [pscustomobject]@{
                    Name = $name
                    Size = $size
                }
            }
        }
        return $blobs
    }
    catch {
        Write-Error "Azure List Failed: $_"
        return @()
    }
}

# ---------------------------------------------------------
# MAIN
# ---------------------------------------------------------

$GlobalResults = New-Object System.Collections.Generic.List[object]

foreach ($repo in $Repositories) {
    Write-Host "---------------------------------------------------"
    Write-TS "Processing Repository: $($repo.Name) (Type: $($repo.Type))"
    
    # 1. Auto-Discover Cache DB
    $cacheDb = Get-VBCacheDbName -RepoName $repo.Name
    if ($cacheDb) {
        Write-TS "Discovered Cache DB: $cacheDb"
        Build-GlobalMaps -CacheDbName $cacheDb
    }
    else {
        Write-Warning "Could not find Cache DB for '$($repo.Name)'. Naming might be incomplete."
        Build-GlobalMaps # Build clean maps anyway
    }
    
    # 2. Scan Storage
    # 2. Scan Storage
    # Normalize Folder: Prepend standard "Veeam/Backup365/" if usually missing
    $baseFolder = $repo.Folder
    if (-not $baseFolder.StartsWith("Veeam/Backup365")) {
        $baseFolder = "Veeam/Backup365/$baseFolder"
    }
    
    $basePrefix = $baseFolder
    if (-not $basePrefix.EndsWith("/")) { $basePrefix += "/" }
    $orgsPrefix = "${basePrefix}Organizations/"
    
    Write-TS "Scanning Cloud Path: $orgsPrefix"
    
    # Retrieve Org Folders based on Type
    $orgFolders = @()
    
    if ($repo.Type -eq "S3") {
        Write-TS "List Organizations folders (S3)..."
        $orgRootPrefixes = @(Get-WasabiCommonPrefixes -Endpoint $repo.Endpoint -Region $repo.Region -Bucket $repo.Bucket -AccessKey $repo.AccessKey -SecretKey $repo.SecretKey -Prefix $orgsPrefix)
        
        Write-TS "Found $($orgRootPrefixes.Count) Organization folders."
        
        foreach ($orgFolder in $orgRootPrefixes) {
            $parts = $orgFolder.Split('/')
            $orgId = $parts[$parts.Count - 2]
            
            $cleanOrgId = $orgId.Replace("-", "").ToLower()
            $orgName = if ($global:OrgNameMap.ContainsKey($cleanOrgId)) { $global:OrgNameMap[$cleanOrgId] } else { $orgId }
            
            Write-Host "Processing Org: $(Get-MaskedName $orgName) ($orgId)" -ForegroundColor Cyan
            
            # --- MAILBOXES ---
            $mbxPrefix = "${orgFolder}Mailboxes/"
            $users = @(Get-WasabiCommonPrefixes -Endpoint $repo.Endpoint -Region $repo.Region -Bucket $repo.Bucket -AccessKey $repo.AccessKey -SecretKey $repo.SecretKey -Prefix $mbxPrefix)
            foreach ($uPath in $users) {
                $uParts = $uPath.Split('/')
                $uId = $uParts[$uParts.Count - 2]
                $cleanUid = $uId.Replace("-", "").ToLower()
                $uName = if ($global:UserMap.ContainsKey($cleanUid)) { $global:UserMap[$cleanUid] } else { $uId }
                
                $sizeBytes = Get-WasabiPrefixSizeBytes -Endpoint $repo.Endpoint -Region $repo.Region -Bucket $repo.Bucket -AccessKey $repo.AccessKey -SecretKey $repo.SecretKey -Prefix $uPath
                $sizeGib = [math]::Round($sizeBytes / 1GB, 2)
                
                if ($sizeBytes -gt 0) {
                    Write-Host "  Mailbox: $(Get-MaskedName $uName) ($uId) - $sizeGib GiB"
                    $GlobalResults.Add([pscustomobject]@{
                            RepoName = $repo.Name; RepoType = "S3"; OrgId = $orgId; OrgName = (Get-MaskedName $orgName); Type = "Mailbox"; Name = (Get-MaskedName $uName); Id = $uId; Bytes = $sizeBytes; GiB = $sizeGib
                        })
                }
            }

            # --- TEAMS ---
            $teamPrefix = "${orgFolder}Teams/"
            $teams = @(Get-WasabiCommonPrefixes -Endpoint $repo.Endpoint -Region $repo.Region -Bucket $repo.Bucket -AccessKey $repo.AccessKey -SecretKey $repo.SecretKey -Prefix $teamPrefix)
            foreach ($tPath in $teams) {
                $tParts = $tPath.Split('/')
                $tId = $tParts[$tParts.Count - 2]
                $cleanTid = $tId.Replace("-", "").ToLower()
                $tName = if ($global:TeamMap.ContainsKey($cleanTid)) { $global:TeamMap[$cleanTid] } else { $tId }
                
                $sizeBytes = Get-WasabiPrefixSizeBytes -Endpoint $repo.Endpoint -Region $repo.Region -Bucket $repo.Bucket -AccessKey $repo.AccessKey -SecretKey $repo.SecretKey -Prefix $tPath
                $sizeGib = [math]::Round($sizeBytes / 1GB, 2)
                
                if ($sizeBytes -gt 0) {
                    Write-Host "  Team: $(Get-MaskedName $tName) ($tId) - $sizeGib GiB"
                    $GlobalResults.Add([pscustomobject]@{
                            RepoName = $repo.Name; RepoType = "S3"; OrgId = $orgId; OrgName = (Get-MaskedName $orgName); Type = "Team"; Name = (Get-MaskedName $tName); Id = $tId; Bytes = $sizeBytes; GiB = $sizeGib
                        })
                }
            }

            # --- SITES ---
            $webPrefix = "${orgFolder}Webs/"
            $sites = @(Get-WasabiCommonPrefixes -Endpoint $repo.Endpoint -Region $repo.Region -Bucket $repo.Bucket -AccessKey $repo.AccessKey -SecretKey $repo.SecretKey -Prefix $webPrefix)
            foreach ($sPath in $sites) {
                $sParts = $sPath.Split('/')
                $sId = $sParts[$sParts.Count - 2]
                $cleanSid = $sId.Replace("-", "").ToLower()
                $sName = if ($global:SiteMap.ContainsKey($cleanSid)) { $global:SiteMap[$cleanSid] } else { $sId }
                
                $sizeBytes = Get-WasabiPrefixSizeBytes -Endpoint $repo.Endpoint -Region $repo.Region -Bucket $repo.Bucket -AccessKey $repo.AccessKey -SecretKey $repo.SecretKey -Prefix $sPath
                $sizeGib = [math]::Round($sizeBytes / 1GB, 2)
                
                if ($sizeBytes -gt 0) {
                    Write-Host "  Site: $(Get-MaskedName $sName) ($sId) - $sizeGib GiB"
                    $GlobalResults.Add([pscustomobject]@{
                            RepoName = $repo.Name; RepoType = "S3"; OrgId = $orgId; OrgName = (Get-MaskedName $orgName); Type = "Site"; Name = (Get-MaskedName $sName); Id = $sId; Bytes = $sizeBytes; GiB = $sizeGib
                        })
                }
            }
        }
    }
    elseif ($repo.Type -eq "Azure") {
        # Azure Listing Logic (Directory simulation)
        # Azure lists Blobs, not folders. We need to listing with delimiter or parse blobs unique paths.
        # Actually, standard efficient way: List ALL blobs with prefix, then group by folder locally for summary?
        # Or emulate "CommonPrefixes" by using delimiter in REST API (supported).
        
        # NOTE: Azure 'delimiter' param is supported but my function above needs update to handle it.
        # For 'Sizing', we usually want recursive sum.
        # Let's list top level Orgs manually.
        
        # IMPLEMENTATION NOTE: Azure Listing Recursive
        Write-TS "  Listing Azure Container..."
        $allBlobs = Invoke-AzureBlobList -AccountName $repo.AccountName -AccountKey $repo.AccountKey -Container $repo.Container -Prefix $orgsPrefix
        
        $countBefore = $GlobalResults.Count

        # Process Blobs -> Group by Organization/User
        # Expected: Veeam/Backup365/Folder/Organizations/{OrgID}/{Type}/{ObjID}/...
        
        # Use a hashtable to aggregate size per object
        $azureAggr = @{}
        
        foreach ($blob in $allBlobs) {
            # Remove Base Prefix
            if ($blob.Name.StartsWith($orgsPrefix)) {
                $relPath = $blob.Name.Substring($orgsPrefix.Length)
                $parts = $relPath.Split("/")
                
                # Minimum depth: {OrgID}/{Type}/{ObjID}/file
                if ($parts.Count -ge 4) {
                    $orgId = $parts[0]
                    $pType = $parts[1]
                    $objId = $parts[2]
                    
                    # Group by this key
                    $key = "$orgId|$pType|$objId"
                    if (-not $azureAggr.ContainsKey($key)) { $azureAggr[$key] = [int64]0 }
                    $azureAggr[$key] += $blob.Size
                }
            }
        }
        
        # Convert Aggregation to Results
        foreach ($key in $azureAggr.Keys) {
            $kParts = $key.Split('|')
            $orgId = $kParts[0]
            $pType = $kParts[1] # Mailboxes, Teams, Webs
            $objId = $kParts[2]
            $bytes = $azureAggr[$key]
            
            # Map Names
            $cleanOrg = $orgId.Replace("-", "").ToLower()
            $orgName = if ($global:OrgNameMap.ContainsKey($cleanOrg)) { $global:OrgNameMap[$cleanOrg] } else { $orgId }
            
            $cleanObj = $objId.Replace("-", "").ToLower()
            $objName = $objId
            $finalType = "Unknown"
            
            if ($pType -eq "Mailboxes") {
                $finalType = "Mailbox"
                if ($global:UserMap.ContainsKey($cleanObj)) { $objName = $global:UserMap[$cleanObj] }
            }
            elseif ($pType -eq "Teams") {
                $finalType = "Team"
                if ($global:TeamMap.ContainsKey($cleanObj)) { $objName = $global:TeamMap[$cleanObj] }
            }
            elseif ($pType -eq "Webs") {
                $finalType = "Site"
                if ($global:SiteMap.ContainsKey($cleanObj)) { $objName = $global:SiteMap[$cleanObj] }
            }
            
            $sizeGib = [math]::Round($bytes / 1GB, 2)
            
            if ($bytes -gt 0) {
                Write-Host "  $finalType : $(Get-MaskedName $objName) ($objId) - $sizeGib GiB"
                $GlobalResults.Add([pscustomobject]@{
                        RepoName = $repo.Name
                        RepoType = "Azure"
                        OrgId    = $orgId
                        OrgName  = (Get-MaskedName $orgName)
                        Type     = $finalType
                        Name     = (Get-MaskedName $objName)
                        Id       = $objId
                        Bytes    = $bytes
                        GiB      = $sizeGib
                    })
            }
        }
        Write-TS "Azure Processing Complete. Added $($GlobalResults.Count - $countBefore) new objects."
    }
}



if ($GlobalResults.Count -gt 0) {
    # CSV Export
    $reportFile = ".\VB365_Hybrid_Report.csv"
    $GlobalResults | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8
    Write-Host "`nDONE! CSV Report saved to $reportFile" -ForegroundColor Green
    
    # Optional: Group summary
    $groups = $GlobalResults | Group-Object RepoName
    foreach ($g in $groups) {
        $sum = ($g.Group | Measure-Object -Property Bytes -Sum).Sum
        $gb = [math]::Round($sum / 1GB, 2)
        Write-Host "  Repo '$($g.Name)': $gb GiB" -ForegroundColor Cyan
    }

    # HTML Report (conditional)
    if ($ExportHtml) {
        New-HtmlReport -Results $GlobalResults -OutputFile ".\VB365_Hybrid_Analytics.html"
    }
}
else {
    Write-Warning "No backup objects found."
}
