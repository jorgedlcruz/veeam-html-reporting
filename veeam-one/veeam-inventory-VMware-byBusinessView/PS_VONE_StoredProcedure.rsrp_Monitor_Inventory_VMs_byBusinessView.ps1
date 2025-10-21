<#
.SYNOPSIS
    Generates an HTML + Email inventory report for Veeam ONE Business View (BV) Categories.

.DESCRIPTION
    This PowerShell script connects to the Veeam ONE SQL database and executes:
      - reportpack.rsrp_Monitor_ChartDetails          → VM inventory with BV category, host/DC/cluster, power/tools.
      - reportpack.rsrp_Monitor_VMAggregateChart      → Aggregated VM counts by BV category (ChartType = 2).

    It produces:
      - A clean HTML report with a summary, a donut chart (PNG), category summary, and per-category details.
      - CSV exports (Inventory.csv, BVCategory_Summary.csv, BVAggregateChart.csv).
      - Optional email delivery via Microsoft Graph (App-only) with the HTML inline, PNG chart embedded (CID),
        and the CSV files attached.

.OUTPUTS
    Files written to $OutDir:
      - InventoryByBVCategory.html
      - Inventory.csv
      - BVCategory_Summary.csv
      - BVAggregateChart.csv
      - BVAggregateChart.png
    Optionally sends an email (inline HTML + CID PNG + CSV attachments) via Microsoft Graph.

.EXAMPLE
    .\PS_VONE_StoredProcedure.rsrp_Monitor_Inventory_VMs_byBusinessView.ps1
    Runs with parameters defined at the top of the script and writes outputs to $OutDir.
    If Graph parameters are set, sends the HTML inline with the chart embedded and CSVs attached.

.NOTES
    NAME:    PS_VONE_StoredProcedure.rsrp_Monitor_Inventory_VMs_byBusinessView.ps1
    VERSION: 1.0
    AUTHOR:  Jorge de la Cruz
    TWITTER: @jorgedelacruz
    GITHUB:  https://github.com/jorgedelacruz

    REQUIREMENTS:
      - Windows PowerShell 5.1
      - Read access to Veeam ONE SQL DB (Integrated Security used by default)
      - .NET GDI+ (System.Drawing) available for PNG chart rendering
      - (Email) MSAL.PS module and Azure App with Application permission "Mail.Send" (admin consent)

    SECURITY:
      - Store Client Secrets securely (Key Vault, DPAPI, environment variables). Avoid committing secrets to git.
      - App-only Mail.Send allows sending as specified mailbox. Limit scope and monitor usage.

.LINK
    https://jorgedelacruz.uk/
#>


$SQLServer    = "VEEAMONE\VEEAMSQL2017"
$SQLDBName    = "VEEAMONE"
$StoredProc   = "reportpack.rsrp_Monitor_ChartDetails"

$cbBVCategory = "VM Location" # Introduce here your Business View Category
$SID          = $null
$RootIDsXml   = "<root><id>1000</id></root>"

$OutDir       = "$PSScriptRoot\Output-MonitorChartDetails"
$ReportTitle  = "Inventory by BV Category"

# Email (Microsoft Graph App-only)
$RecipientEmail = "YOUREMAIL@YOURDOMAIN.COM"
$TenantId = "YOURTENANT.onmicrosoft.com"
$ClientId = "YOURCLIENTID"
$ClientSecret = ConvertTo-SecureString "YOURSECRETFORTHEAPP" -AsPlainText -Force

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-Step($m,[ConsoleColor]$c="Cyan"){ Write-Host "[ $(Get-Date -Format HH:mm:ss) ] $m" -ForegroundColor $c }
function Throw-IfEmpty($dt,$w){ if(-not $dt -or $dt.Rows.Count -eq 0){ throw "No rows returned for $w." } }

function Get-Badge([string]$value,[string]$kind){
    $css = switch ($kind) {
        "power" { switch ($value) { "Powered On"{"badge-on"} "Powered Off"{"badge-off"} default{"badge-na"} } }
        "tools" { switch ($value) {
            "Guest Tools Running"{"badge-on"}
            "Guest Tools Not Running"{"badge-warn"}
            "Guest Tools Not Installed"{"badge-off"}
            default{"badge-na"} } }
        default {"badge-na"}
    }
    "<span class='badge $css'>$value</span>"
}

function New-DonutPng {
    param(
        [Parameter(Mandatory)] [array] $Data,
        [Parameter(Mandatory)] [hashtable] $Palette,
        [Parameter(Mandatory)] [string] $Path,
        [int] $Size = 420,
        [int] $Stroke = 48
    )
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::White)

    $pad = [int]([math]::Ceiling($Stroke/2.0) + 2)
    $rect = New-Object System.Drawing.Rectangle `
        ([int]$pad), ([int]$pad), `
        ([int]($Size - 2*$pad)), ([int]($Size - 2*$pad))

    $start = -90.0   # start at 12 o’clock
    foreach ($item in $Data) {
        $pct   = [math]::Max(0.0, [double]$item.Percent)
        if ($pct -le 0) { continue }
        $sweep = 360.0 * $pct
        $hex   = if ($Palette.ContainsKey($item.Name)) { $Palette[$item.Name] } else { "#A0AEC0" }
        $color = [System.Drawing.ColorTranslator]::FromHtml($hex)
        $pen   = New-Object System.Drawing.Pen $color, $Stroke
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Flat
        $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Flat
        $g.DrawArc($pen, $rect, $start, $sweep)
        $pen.Dispose()
        $start += $sweep
    }

    $hole = $Size - (2*$Stroke) - 16
    if ($hole -gt 0) {
        $x = [int](($Size - $hole)/2)
        $y = $x
        $g.FillEllipse([System.Drawing.Brushes]::White, $x, $y, $hole, $hole)
    }

    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Send-EmailViaGraph {
    param(
        [Parameter(Mandatory)] [string] $HtmlBody,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $RecipientEmail,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [securestring] $ClientSecret,
        [string[]] $AttachmentPaths,
        [string] $InlineImagePath,
        [string] $FromUser = $RecipientEmail
    )

    if (-not (Get-Module -ListAvailable -Name MSAL.PS)) { Import-Module MSAL.PS -ErrorAction Stop } else { Import-Module MSAL.PS | Out-Null }

    # Acquire app-only token with explicit scope to avoid stalls
    $token = Get-MsalToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -Scopes "https://graph.microsoft.com/.default" -ErrorAction Stop

    $attachments = @()

    $cid = $null
    if ($InlineImagePath -and (Test-Path $InlineImagePath)) {
        $cid   = "chart1"
        $name  = [IO.Path]::GetFileName($InlineImagePath)
        $bytes = [IO.File]::ReadAllBytes($InlineImagePath)
        $b64   = [Convert]::ToBase64String($bytes)

        $attachments += @{
            "@odata.type" = "#microsoft.graph.fileAttachment"
            name          = $name
            contentType   = "image/png"
            contentBytes  = $b64
            isInline      = $true
            contentId     = $cid
        }

        $HtmlBody = $HtmlBody -replace "src=['""]BVAggregateChart\.png['""]", "src='cid:$cid'"
    }

    # File attachments
    foreach ($p in ($AttachmentPaths | Where-Object { Test-Path $_ })) {
        $name = [IO.Path]::GetFileName($p)
        $bytes = [IO.File]::ReadAllBytes($p)
        $b64 = [Convert]::ToBase64String($bytes)
        $contentType =
            if ($name -like "*.csv")  { "text/csv" }
            elseif ($name -like "*.htm*" ) { "text/html" }
            else { "application/octet-stream" }

        $attachments += @{
            "@odata.type" = "#microsoft.graph.fileAttachment"
            name          = $name
            contentType   = $contentType
            contentBytes  = $b64
        }
    }

    $payload = @{
        message = @{
            subject      = $Subject
            body         = @{ contentType = "HTML"; content = $HtmlBody }
            toRecipients = @(@{ emailAddress = @{ address = $RecipientEmail } })
            attachments  = $attachments
        }
        saveToSentItems = $true
    } | ConvertTo-Json -Depth 8

    $uri = "https://graph.microsoft.com/v1.0/users/$FromUser/sendMail"
    Invoke-RestMethod -Method Post -Headers @{ Authorization = $token.CreateAuthorizationHeader() } -Uri $uri -ContentType "application/json" -Body $payload -TimeoutSec 60
}

# 1) First SQL call for the data itself
Write-Step "Preparing SQL connection..."
$cs = "Server=$SQLServer;Database=$SQLDBName;Integrated Security=True;"

$dt = New-Object System.Data.DataTable
try{
    Write-Step "Executing stored procedure [$StoredProc]..." "Yellow"
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cmd  = New-Object System.Data.SqlClient.SqlCommand
    $cmd.Connection     = $conn
    $cmd.CommandType    = [System.Data.CommandType]::StoredProcedure
    $cmd.CommandText    = $StoredProc
    $cmd.CommandTimeout = 600

    # Correct parameter add pattern
    $p1 = $cmd.Parameters.Add("@cbBVCategory",[Data.SqlDbType]::NVarChar,11);   $p1.Value = $cbBVCategory
    $p2 = $cmd.Parameters.Add("@SID",[Data.SqlDbType]::NVarChar,4000);          $p2.Value = $SID
    $p3 = $cmd.Parameters.Add("@RootIDsXml",[Data.SqlDbType]::NVarChar,26);     $p3.Value = $RootIDsXml

    $adp = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    [void]$adp.Fill($dt)
    $conn.Close()
    Write-Step "SQL data fetched successfully. Rows: $($dt.Rows.Count)" "Green"
}catch{
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

Throw-IfEmpty $dt "Monitor Chart Details"

# 2) Shape rows
Write-Step "Shaping rows for export..."
$rows = $dt | Select-Object `
    @{n='ObjectID';e={$_.'ObjectID'}},
    @{n='VMName';e={$_.'VMName'}},
    @{n='IsTemplate';e={$_.'IsTemplate'}},
    @{n='HostName';e={$_.'HostName'}},
    @{n='DatacenterName';e={$_.'DatacenterName'}},
    @{n='ClusterName';e={$_.'ClusterName'}},
    @{n='PowerState';e={$_.'PowerState'}},
    @{n='ToolsStatus';e={$_.'ToolsStatus'}},
    @{n='BVCategory';e={$_.'BVCategory'}}

# 3) Group and sort correctly
Write-Step "Grouping by BV Category..."
$byCat = $rows |
    Group-Object BVCategory |
    ForEach-Object { [PSCustomObject]@{ BVCategory = $_.Name; Count = $_.Count } } |
    Sort-Object -Property @{Expression="Count";Descending=$true}, @{Expression="BVCategory";Descending=$false}

# 4) Export to CSV
Write-Step "Exporting CSV files..."
$invCsv = Join-Path $OutDir "Inventory.csv"
$catCsv = Join-Path $OutDir "BVCategory_Summary.csv"
$rows  | Export-Csv -Path $invCsv -Delimiter ';' -NoTypeInformation
$byCat | Export-Csv -Path $catCsv -Delimiter ';' -NoTypeInformation

# === Now we prepare the chart: reportpack.rsrp_Monitor_VMAggregateChart (ChartType=2) ===
Write-Step "Executing stored procedure [reportpack.rsrp_Monitor_VMAggregateChart]..." "Yellow"
$dtAgg = New-Object System.Data.DataTable
try {
    $conn2 = New-Object System.Data.SqlClient.SqlConnection $cs
    $cmd2  = New-Object System.Data.SqlClient.SqlCommand
    $cmd2.Connection     = $conn2
    $cmd2.CommandType    = [System.Data.CommandType]::StoredProcedure
    $cmd2.CommandText    = "reportpack.rsrp_Monitor_VMAggregateChart"
    $cmd2.CommandTimeout = 600

    $x1 = $cmd2.Parameters.Add("@ChartType",[Data.SqlDbType]::Int);                $x1.Value = 2
    $x2 = $cmd2.Parameters.Add("@cbBVCategory",[Data.SqlDbType]::NVarChar,11);     $x2.Value = $cbBVCategory
    $x3 = $cmd2.Parameters.Add("@SID",[Data.SqlDbType]::NVarChar,4000);            $x3.Value = $SID
    $x4 = $cmd2.Parameters.Add("@RootIDsXml",[Data.SqlDbType]::NVarChar,26);       $x4.Value = $RootIDsXml

    $adp2 = New-Object System.Data.SqlClient.SqlDataAdapter $cmd2
    [void]$adp2.Fill($dtAgg)
    $conn2.Close()
    Write-Step "Aggregate data fetched. Rows: $($dtAgg.Rows.Count)" "Green"
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

$aggRaw = $dtAgg | Select-Object @{n='Category';e={$_.'Category'}},
                             @{n='VMCount';e={[int]$_.VMCount}}
$agg = $aggRaw | Group-Object Category | ForEach-Object {
    [PSCustomObject]@{
        Name   = $_.Name
        Count  = ($_.Group | Measure-Object VMCount -Sum).Sum
    }
}

$aggTotal = ($agg | Measure-Object Count -Sum).Sum
$agg = $agg | ForEach-Object {
    [PSCustomObject]@{
        Name    = $_.Name
        Count   = $_.Count
        Percent = if ($aggTotal -gt 0) { [math]::Round($_.Count / $aggTotal, 6) } else { 0 }
    }
} | Sort-Object Count -Descending

# Export Chart to CSV
$agg | Export-Csv -Path (Join-Path $OutDir "BVAggregateChart.csv") -NoTypeInformation -Delimiter ';'

# 50-color base palette
$basePalette = @(
  '#4E79A7','#F28E2B','#E15759','#76B7B2','#59A14F','#EDC948','#B07AA1','#FF9DA7','#9C755F','#BAB0AC',
  '#1F77B4','#AEC7E8','#FF7F0E','#FFBB78','#2CA02C','#98DF8A','#D62728','#FF9896','#9467BD','#C5B0D5',
  '#8C564B','#C49C94','#E377C2','#F7B6D2','#7F7F7F','#C7C7C7','#BCBD22','#DBDB8D','#17BECF','#9EDAE5',
  '#6B8E23','#20B2AA','#008B8B','#4169E1','#9932CC','#8B0000','#B22222','#CD853F','#FF8C00','#FFD700',
  '#32CD32','#00FA9A','#40E0D0','#00CED1','#1E90FF','#6495ED','#7B68EE','#DA70D6','#FF69B4','#708090'
)

# Build a deterministic color map per category (order = sorted by count desc)
$categoryOrder = ($agg | Sort-Object Count -Descending | Select-Object -ExpandProperty Name)
$paletteMap = @{}
$i = 0
foreach ($name in $categoryOrder) {
    $paletteMap[$name] = $basePalette[$i % $basePalette.Count]
    $i++
}

# Legend HTML
$legend = ($agg | ForEach-Object {
    $clr = $paletteMap[$_.Name]
    $pct = [math]::Round($_.Percent * 100, 2)
@"
<div style='display:inline-flex;align-items:center;margin-right:14px;margin-bottom:6px'>
  <span style='display:inline-block;width:12px;height:12px;background:$clr;margin-right:6px;border:1px solid #ddd'></span>
  <span style='font-size:13px'>$($_.Name) &ndash; $($_.Count) ($pct%)</span>
</div>
"@
}) -join "`n"


# Final chart block to inject into the HTML later
$chartHtml = @"
<div class='card'>
  <h2>BV Chart ($cbBVCategory)</h2>
  <div style='display:flex;flex-direction:column;gap:16px;align-items:center;flex-wrap:wrap'>
    <img src='BVAggregateChart.png' alt='BV Chart' style='max-width:360px;width:100%;height:auto;border:0;' />
    <div>$legend</div>
  </div>
</div>
"@


# 5) HTML
Write-Step "Building HTML report..."
$style = @"
<style>
body{font-family:Segoe UI,Roboto,Arial,sans-serif;margin:24px}
h1{font-size:22px;margin:0 0 8px 0}
h2{font-size:18px;margin-top:24px}
.small{color:#666;font-size:12px}
table{border-collapse:collapse;width:100%;margin:12px 0}
th,td{border:1px solid #e5e5e5;padding:8px;text-align:left;font-size:13px}
th{background:#f7f7f7}
.badge{display:inline-block;padding:2px 8px;border-radius:12px;font-size:12px}
.badge-on{background:#e7f6ec;color:#09653c;border:1px solid #b7e1c2}
.badge-off{background:#fdecec;color:#8a1224;border:1px solid #f2b6bf}
.badge-warn{background:#fff7e6;color:#8a6100;border:1px solid #ffd48a}
.badge-na{background:#eef1f5;color:#4a5568;border:1px solid #d7dde6}
.card{border:1px solid #e5e5e5;border-radius:12px;padding:16px;margin-top:12px}
.summary{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.kv{border:1px solid #e5e5e5;border-radius:10px;padding:12px}
.kv h3{margin:0 0 6px 0;font-size:14px;color:#333}
details{margin-top:8px}
details>summary{cursor:pointer;font-weight:600}
footer{margin-top:24px;color:#666;font-size:12px}
</style>
"@

$totalVMs    = $rows.Count
$totalCats   = $byCat.Count
$topLine     = $byCat | Select-Object -First 1
$topCatName  = if($topLine){$topLine.BVCategory}else{"n/a"}
$topCatCount = if($topLine){$topLine.Count}else{0}

$summaryHtml = @"
<div class='summary'>
  <div class='kv'><h3>Total objects</h3><div style='font-size:22px'>$totalVMs</div></div>
  <div class='kv'><h3>Total categories</h3><div style='font-size:22px'>$totalCats</div></div>
  <div class='kv'><h3>Largest category</h3><div><strong>$topCatName</strong> ($topCatCount)</div></div>
  <div class='kv'><h3>Database</h3><div>$SQLServer / $SQLDBName</div></div>
</div>
"@

$catTable = ($byCat | ConvertTo-Html -Fragment -PreContent "<h2>BV Category summary</h2>").Replace("<table>","<table id='tblCats'>")

# Build per-category tables, fix previous Out-String issue
$catSections = foreach ($cat in $byCat) {
    $catRows = $rows | Where-Object { $_.BVCategory -eq $cat.BVCategory } | Sort-Object VMName
    $rowsHtml = ($catRows | ForEach-Object {
        $pwr   = Get-Badge $_.PowerState "power"
        $tools = Get-Badge $_.ToolsStatus "tools"
        "<tr><td>$($_.VMName)</td><td>$($_.IsTemplate)</td><td>$($_.HostName)</td><td>$($_.DatacenterName)</td><td>$($_.ClusterName)</td><td>$pwr</td><td>$tools</td></tr>"
    }) -join "`n"

@"
<div class='card'>
  <details open>
    <summary>$($cat.BVCategory) &ndash; $($cat.Count) objects</summary>
    <table>
      <thead><tr>
        <th>VM Name</th><th>Is Template</th><th>Host</th><th>Datacenter</th><th>Cluster</th><th>Power</th><th>VM Tools</th>
      </tr></thead>
      <tbody>
        $rowsHtml
      </tbody>
    </table>
  </details>
</div>
"@
}

$html = @"
<!doctype html>
<html><head><meta charset='utf-8'><title>$ReportTitle</title>
$style
</head>
<body>
  <h1>$ReportTitle</h1>
  <div class='small'>Generated $ts</div>
  $summaryHtml
  $chartHtml
  <div class='card'>$catTable</div>
  $($catSections -join "`n")
  <footer>Source: $StoredProc | cbBVCategory='$cbBVCategory' | RootIDsXml='$RootIDsXml'</footer>
</body></html>
"@

$reportPath = Join-Path $OutDir "InventoryByBVCategory.html"
$html | Out-File -FilePath $reportPath -Encoding UTF8

Write-Step "Done. Files created:" "Green"
Write-Host "  $invCsv"
Write-Host "  $catCsv"
Write-Host "  $reportPath"

# Render PNG donut for email (and for the HTML report)
$chartPng = Join-Path $OutDir "BVAggregateChart.png"
New-DonutPng -Data $agg -Palette $paletteMap -Path $chartPng -Size 360 -Stroke 44

Write-Step "Sending Email"
# Email: inline HTML body + CSV attachments
$aggCsv = Join-Path $OutDir "BVAggregateChart.csv"
$subject = "Veeam ONE Inventory by BV Category ($cbBVCategory) $ts"

Send-EmailViaGraph `
    -HtmlBody $html `
    -Subject $subject `
    -RecipientEmail $RecipientEmail `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ClientSecret $ClientSecret `
    -AttachmentPaths @($invCsv, $catCsv, $aggCsv) `
    -InlineImagePath $chartPng

Write-Step "Done. Email Sent" "Green"
