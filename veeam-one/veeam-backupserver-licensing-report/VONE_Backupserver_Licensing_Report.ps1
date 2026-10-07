#requires -Version 5.1
<#
.SYNOPSIS
    Exports a Veeam ONE Backup Inventory license report to email-ready HTML.
.DESCRIPTION
    Runs reportpack.rsrp_Backup_BackupInventory, and evaluates sockets, instances 
    and capacity independently.
    A server appears once, in its highest-severity section. Optional Microsoft
    Graph email uses application OAuth; the report is embedded in the message.
    Edit the configuration below. No email is sent unless EnableEmail is true.
.PARAMETER InputPath
    Optional tab-delimited .tsv/.txt or comma-delimited .csv SQL export. Bypasses SQL.
.PARAMETER OutputPath
    HTML destination. Defaults to BackupLicenseInventory.html beside this script,
    or in the current filesystem folder when run as pasted code or an ISE selection.
.PARAMETER WarningThresholdPercent
    Near-limit threshold, inclusive; defaults to 90. Values over 100% are overused.
.EXAMPLE
    .\VONE_Backupserver_Licensing_Report.ps1 -SQLServer 'SQL01\VEEAM' -SQLDBName 'VeeamONE'
.EXAMPLE
    .\VONE_Backupserver_Licensing_Report.ps1 -InputPath '.\inventory.tsv' -WarningThresholdPercent 85
.NOTES
    Windows PowerShell 5.1 and PowerShell 7 on Windows. No external modules required.
    Stored-procedure schemas can change: verify LicenseSectionId after upgrades.
    Capacity field raw units are not established by the supplied sample; configure
    CapacityDisplayDivisor and CapacityUnit only after verifying your database.
    Dot-source the script to load functions without executing the report.
#>
[CmdletBinding()]
param(
    [string]$SQLServer = 'VEEAMONE\VEEAMSQL2017',
    [string]$SQLDBName = 'VeeamONE',
    [string]$InputPath = '',
    [string]$OutputPath = '',
    [ValidateRange(1, 100)][double]$WarningThresholdPercent = 90
)

# ======================== EDIT CONFIGURATION HERE ========================
$Config = @{
    RootIds                        = @(1002)
    LicenseSectionId               = 0
    MetadataSectionId              = 1
    SqlCommandTimeoutSeconds       = 180
    SqlConnectionTimeout           = 30
    SqlEncrypt                     = $false
    SqlTrustServerCertificate      = $false
    # Integrated Windows authentication uses the account running this script.
    # Optional SQL authentication: user here, password in the named environment variable.
    SqlUsername                    = ''
    SqlPasswordEnvironmentVariable = 'VONE_SQL_PASSWORD'
    ReportTitle                    = 'Backup license inventory'
    Organisation                   = 'Veeam ONE'
    CapacityDisplayDivisor         = 1
    CapacityUnit                   = 'source units'
    OpenReportAfterExport          = $false

    EnableEmail                    = $true
    AuthMode                       = 'ClientSecret' # Certificate or ClientSecret
    TenantId                       = 'YOURTENANTID'
    ClientId                       = 'YOURCLIENTID'
    CertificateThumbprint          = 'YOUR-CERTIFICATE-THUMBPRINT'
    CertificateStoreLocation       = 'CurrentUser' # CurrentUser or LocalMachine
    ClientSecret                   = 'YOURSECRET' # Paste your NEW app secret VALUE between these quotes.
    SenderEmail                    = 'YOURSENDEREMAIL'
    ToRecipients                   = @('YOURTOCEMAIL')
    CcRecipients                   = @()
    EmailSubjectPrefix             = '[Veeam ONE] Backup license inventory'
    AttachHtmlReport               = $false
    SaveToSentItems                = $true
}
# ========================================================================

function Get-CellValue {
    param([object]$Row, [string]$Name)
    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -is [DBNull]) { return $null }
    $value = [string]$property.Value
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Trim() -eq 'NULL') { return $null }
    return $property.Value
}

function ConvertTo-HtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-LicenseNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [DBNull]) { return $null }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq 'NULL') { return $null }
    # Native numeric SQL values must not pass through a locale-sensitive string.
    if ($Value -is [ValueType] -and $Value -isnot [DateTime] -and $Value -isnot [bool]) {
        try { $number = [decimal]$Value } catch { return $null }
    }
    else {
        $number = [decimal]0
        $styles = [System.Globalization.NumberStyles]::AllowLeadingSign -bor [System.Globalization.NumberStyles]::AllowDecimalPoint
        if (-not [decimal]::TryParse($text, $styles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    }
    if ($number -lt 0) { return $null }
    return $number
}

function Format-LicenseNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'Unavailable' }
    return ([decimal]$Value).ToString('#,##0.##', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-LicenseMetric {
    param(
        [string]$Name,
        [AllowNull()][object]$LicensedValue,
        [AllowNull()][object]$UsedValue,
        [double]$Threshold = 90,
        [decimal]$DisplayDivisor = 1,
        [string]$Unit = ''
    )
    if ($DisplayDivisor -le 0) { throw 'CapacityDisplayDivisor must be greater than zero.' }
    $licensed = ConvertTo-LicenseNumber $LicensedValue
    $used = ConvertTo-LicenseNumber $UsedValue
    $state = 'Unknown'; $percent = $null; $remaining = $null; $severity = 0
    $reason = 'Licensed or used value is missing or invalid.'
    if ($null -ne $licensed -and $null -ne $used) {
        $remaining = $licensed - $used
        if ($licensed -eq 0 -and $used -eq 0) {
            $state = 'Inactive'; $reason = 'No allowance and no usage reported.'
        }
        elseif ($licensed -eq 0 -and $used -gt 0) {
            $state = 'Overused'; $severity = 2; $reason = 'Usage reported against a zero allowance.'
        }
        else {
            $percent = ($used / $licensed) * 100
            if ($used -gt $licensed) { $state = 'Overused'; $severity = 2; $reason = 'Usage exceeds the allowance.' }
            elseif ($percent -ge $Threshold) { $state = 'NearLimit'; $severity = 1; $reason = 'Usage has reached the near-limit threshold.' }
            else { $state = 'WithinLimit'; $reason = 'Usage is below the near-limit threshold.' }
        }
    }
    [PSCustomObject]@{
        Name = $Name; Licensed = $licensed; Used = $used; Percent = $percent
        Remaining = $remaining; State = $state; Severity = $severity; Reason = $reason
        DisplayDivisor = $DisplayDivisor; Unit = $Unit
    }
}

function Invoke-BackupInventorySql {
    param([string]$Server, [string]$Database, [hashtable]$Settings)
    if ([string]::IsNullOrWhiteSpace($Server) -or $Server -eq 'YOURSQL\INSTANCE') {
        throw 'Set SQLServer to your SQL Server instance, or use -InputPath for an exported result.'
    }
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    # Canonical keys avoid PowerShell's IDictionary adapter treating property names
    # such as DataSource as unsupported connection-string keywords.
    $builder['Data Source'] = $Server
    $builder['Initial Catalog'] = $Database
    $builder['Application Name'] = 'Veeam ONE Backup License Report'
    $builder['Connect Timeout'] = $Settings.SqlConnectionTimeout
    $builder['Encrypt'] = $Settings.SqlEncrypt
    $builder['TrustServerCertificate'] = $Settings.SqlTrustServerCertificate
    if ([string]::IsNullOrWhiteSpace($Settings.SqlUsername)) {
        $builder['Integrated Security'] = $true
    }
    else {
        $password = [Environment]::GetEnvironmentVariable($Settings.SqlPasswordEnvironmentVariable)
        if ([string]::IsNullOrWhiteSpace($password)) { throw "Set environment variable $($Settings.SqlPasswordEnvironmentVariable) for SQL authentication." }
        $builder['Integrated Security'] = $false
        $builder['User ID'] = $Settings.SqlUsername
        $builder['Password'] = $password
        $password = $null
    }
    if (@($Settings.RootIds).Count -eq 0) { throw 'RootIds must contain at least one positive integer.' }
    $xmlBuilder = New-Object System.Text.StringBuilder
    [void]$xmlBuilder.Append('<root>')
    foreach ($rootId in $Settings.RootIds) {
        $id = 0
        if (-not [int]::TryParse([string]$rootId, [ref]$id) -or $id -le 0) { throw "Invalid RootIds entry: $rootId" }
        [void]$xmlBuilder.Append('<id>').Append($id).Append('</id>')
    }
    [void]$xmlBuilder.Append('</root>')
    $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    $command = $connection.CreateCommand()
    $command.CommandText = 'reportpack.rsrp_Backup_BackupInventory'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    $command.CommandTimeout = $Settings.SqlCommandTimeoutSeconds
    $parameter = $command.Parameters.Add('@RootIDsXml', [System.Data.SqlDbType]::Xml)
    $parameter.Value = $xmlBuilder.ToString()
    $reader = $null
    $result = New-Object 'System.Collections.Generic.List[object]'
    try {
        $connection.Open()
        $reader = $command.ExecuteReader()
        do {
            while ($reader.Read()) {
                $record = [ordered]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $record[$reader.GetName($i)] = $reader.GetValue($i)
                }
                $result.Add([PSCustomObject]$record)
            }
        } while ($reader.NextResult())
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $command.Dispose()
        $connection.Dispose()
        $builder.Clear()
    }
    return $result.ToArray()
}

function Get-BackupLicenseServers {
    param([AllowEmptyCollection()][object[]]$Rows, [hashtable]$Settings, [double]$Threshold = 90)
    $licenseRows = @($Rows | Where-Object { (Get-CellValue $_ 'section_id') -eq $Settings.LicenseSectionId })
    if ($Rows.Count -gt 0 -and $licenseRows.Count -eq 0) {
        throw "No license rows for section_id $($Settings.LicenseSectionId). Verify the stored-procedure schema and LicenseSectionId; refusing to report a healthy empty inventory."
    }
    $required = @('section_id', 'bs_id', 'bs_name', 'licensed_sockets', 'used_sockets', 'licensed_instances', 'used_instances')
    foreach ($row in $licenseRows) {
        foreach ($column in $required) {
            if ($null -eq $row.PSObject.Properties[$column]) { throw "License result is missing required column '$column'. Verify the stored-procedure schema." }
        }
        if ($null -eq (Get-CellValue $row 'bs_id') -and $null -eq (Get-CellValue $row 'bs_name')) {
            throw 'A license row has neither bs_id nor bs_name; cannot identify its server.'
        }
    }
    $groups = @($licenseRows | Group-Object -Property {
            $id = Get-CellValue $_ 'bs_id'
            if ($null -ne $id) { 'id:' + [string]$id } else { 'name:' + ([string](Get-CellValue $_ 'bs_name')).Trim().ToLowerInvariant() }
        })
    $signatureColumns = @('bs_name', 'licensed_sockets', 'used_sockets', 'licensed_instances', 'used_instances',
        'license_total_capacity', 'license_used_capacity', 'lic_type', 'ls_type', 'ls_package', 'lic_exp_date', 'supp_exp_date',
        'license_support_id', 'license_licensed_to', 'vm_used_inst', 'workstation_used_inst', 'server_used_inst',
        'plugin_server_used_inst', 'objects_used_inst', 'cloud_vm_used_inst', 'file_shares_250_inst')
    foreach ($group in $groups) {
        $row = $group.Group[0]
        if ($group.Count -gt 1) {
            $signatures = @($group.Group | ForEach-Object {
                    $item = $_
                    $signature = [ordered]@{}
                    foreach ($column in $signatureColumns) { $signature[$column] = Get-CellValue $item $column }
                    $signature | ConvertTo-Json -Compress -Depth 3
                } | Select-Object -Unique)
            if ($signatures.Count -gt 1) { throw "Conflicting license rows for $($group.Name). Resolve the duplicate snapshots before reporting; allowances are never summed." }
        }
        $name = Get-CellValue $row 'bs_name'
        $id = Get-CellValue $row 'bs_id'
        if ($null -eq $name) { $name = "Backup server $id" }
        $metadata = @($Rows | Where-Object {
                (Get-CellValue $_ 'section_id') -eq $Settings.MetadataSectionId -and
                (($null -ne $id -and (Get-CellValue $_ 'bs_id') -eq $id) -or
                ($null -eq $id -and (Get-CellValue $_ 'bs_name') -eq $name))
            })
        $version = Get-CellValue $row 'bs_version'
        if ($null -eq $version -and $metadata.Count -gt 0) { $version = Get-CellValue $metadata[0] 'bs_version' }
        $metrics = @(
            Get-LicenseMetric -Name 'Instances' -LicensedValue (Get-CellValue $row 'licensed_instances') -UsedValue (Get-CellValue $row 'used_instances') -Threshold $Threshold
            Get-LicenseMetric -Name 'Sockets' -LicensedValue (Get-CellValue $row 'licensed_sockets') -UsedValue (Get-CellValue $row 'used_sockets') -Threshold $Threshold
            Get-LicenseMetric -Name 'Capacity' -LicensedValue (Get-CellValue $row 'license_total_capacity') -UsedValue (Get-CellValue $row 'license_used_capacity') -Threshold $Threshold -DisplayDivisor $Settings.CapacityDisplayDivisor -Unit $Settings.CapacityUnit
        )
        $severity = 0
        foreach ($metric in $metrics) { if ($metric.Severity -gt $severity) { $severity = $metric.Severity } }
        $bucket = if ($severity -eq 2) { 'Overused' } elseif ($severity -eq 1) { 'NearLimit' } else { 'Rest' }
        $active = @($metrics | Where-Object { $_.State -in @('WithinLimit', 'NearLimit', 'Overused') })
        $highest = @($active | Sort-Object @{Expression = 'Severity'; Descending = $true }, @{Expression = 'Percent'; Descending = $true })
        $displayStatus = if ($bucket -eq 'Overused') { 'Allowance exceeded' } elseif ($bucket -eq 'NearLimit') { 'Near limit' }
        elseif ($active.Count -eq 0) { 'Usage unverified' } else { 'Within reported limits' }
        $sortPercent = if (@($metrics | Where-Object { $_.State -eq 'Overused' -and $null -eq $_.Percent }).Count -gt 0) { [double]::MaxValue }
        elseif ($highest.Count -gt 0) { [double]$highest[0].Percent } else { -1 }
        [PSCustomObject]@{
            Id = $id; Name = [string]$name; Version = $version; Bucket = $bucket; Status = $displayStatus
            Metrics = $metrics; HighestPercent = $sortPercent; Edition = Get-CellValue $row 'lic_type'
            LicenseType = Get-CellValue $row 'ls_type'; Package = Get-CellValue $row 'ls_package'
            LicenseExpiry = Get-CellValue $row 'lic_exp_date'; SupportExpiry = Get-CellValue $row 'supp_exp_date'
            Licensee = Get-CellValue $row 'license_licensed_to'; SupportId = Get-CellValue $row 'license_support_id'
            SourceRow = $row
        }
    }
}

function Format-InventoryDate {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'Not reported' }
    if ($Value -is [DateTime]) { return $Value.ToString('dd MMM yyyy', [System.Globalization.CultureInfo]::InvariantCulture) }
    $date = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$date)) {
        return $date.ToString('dd MMM yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return 'Unrecognized date'
}

function Get-LicenseMetricHtml {
    param([object]$Metric)
    $color = switch ($Metric.State) {
        'Overused' { '#b42318' }
        'NearLimit' { '#a15c00' }
        'WithinLimit' { '#334155' }
        default { '#64748b' }
    }
    $usedText = if ($null -ne $Metric.Used) { Format-LicenseNumber ($Metric.Used / $Metric.DisplayDivisor) } else { 'N/A' }
    $licensedText = if ($null -ne $Metric.Licensed) { Format-LicenseNumber ($Metric.Licensed / $Metric.DisplayDivisor) } else { 'N/A' }
    if ($null -ne $Metric.Percent) {
        $detail = $Metric.Percent.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture) + '%'
        $balance = Format-LicenseNumber ([Math]::Abs($Metric.Remaining) / $Metric.DisplayDivisor)
        $detail += if ($Metric.Remaining -lt 0) { " ($balance over)" } else { " ($balance left)" }
    }
    elseif ($Metric.State -eq 'Overused') { $detail = 'Zero allowance' }
    elseif ($Metric.State -eq 'Inactive') { $detail = 'Inactive' }
    else { $detail = 'Unavailable' }
    return @"
<td align="right" valign="top" style="border:1px solid #d9e1e5;padding:7px 8px;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:16px;color:$color;"><b>$(ConvertTo-HtmlText $usedText) / $(ConvertTo-HtmlText $licensedText)</b><br><span style="font-size:11px;">$(ConvertTo-HtmlText $detail)</span></td>
"@
}

function Get-ServerGridRowHtml {
    param([object]$Server, [int]$RowIndex = 0)
    $background = if ($RowIndex % 2 -eq 0) { '#ffffff' } else { '#f4f7f8' }
    $cellStyle = 'border:1px solid #d9e1e5;padding:7px 8px;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:16px;color:#1f2937;'
    $version = if ($null -eq $Server.Version) { 'Version N/A' } else { 'v' + [string]$Server.Version }
    $serverNote = if ($Server.Status -eq 'Usage unverified') { '<br><span style="font-size:11px;color:#64748b;">Usage unverified</span>' } else { '' }
    $licenseBits = @($Server.LicenseType, $Server.Package) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() }
    $licenseLabel = if (@($licenseBits).Count -gt 0) { $licenseBits -join ' / ' } else { 'Not reported' }
    $edition = if ($null -ne $Server.Edition) { '<br><span style="font-size:11px;color:#64748b;">' + (ConvertTo-HtmlText $Server.Edition) + '</span>' } else { '' }
    $metricHtml = ($Server.Metrics | ForEach-Object { Get-LicenseMetricHtml $_ }) -join "`n"
    return @"
<tr class="server-row" bgcolor="$background" style="background-color:$background;">
<td valign="top" style="$cellStyle"><b>$(ConvertTo-HtmlText $Server.Name)</b><br><span style="font-size:11px;color:#64748b;">$(ConvertTo-HtmlText $version)</span>$serverNote</td>
<td valign="top" style="$cellStyle">$(ConvertTo-HtmlText $licenseLabel)$edition</td>
$metricHtml
<td valign="top" style="$cellStyle">$(ConvertTo-HtmlText (Format-InventoryDate $Server.LicenseExpiry))<br><span style="font-size:11px;color:#64748b;">Support: $(ConvertTo-HtmlText (Format-InventoryDate $Server.SupportExpiry))</span></td>
</tr>
"@
}

function New-BackupLicenseHtml {
    param([AllowEmptyCollection()][object[]]$Servers, [hashtable]$Settings, [double]$Threshold, [string]$SourceLabel)
    $over = @($Servers | Where-Object { $_.Bucket -eq 'Overused' })
    $near = @($Servers | Where-Object { $_.Bucket -eq 'NearLimit' })
    $rest = @($Servers | Where-Object { $_.Bucket -eq 'Rest' })
    $unverified = @($Servers | Where-Object { $_.Status -eq 'Usage unverified' }).Count
    $thresholdText = $Threshold.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
    $now = [DateTimeOffset]::Now
    $generated = $now.ToString('dd MMM yyyy', [System.Globalization.CultureInfo]::InvariantCulture) + ' &middot; ' + $now.ToString('HH:mm zzz', [System.Globalization.CultureInfo]::InvariantCulture)
    $headline = if ($Servers.Count -eq 0) { 'No license records returned' }
    elseif ($over.Count -gt 0) { "$($over.Count) server(s) exceed their allowance" }
    elseif ($near.Count -gt 0) { "$($near.Count) server(s) are approaching the limit" }
    elseif ($unverified -eq $Servers.Count) { 'License usage needs verification' }
    else { 'Reported usage is below the alert threshold' }
    $sections = @(
        @{Key = 'Overused'; Title = 'Backup Servers with over-using licenses'; Color = '#b42318'; Rows = $over; Description = 'At least one pool exceeds its licensed allowance. Highest usage first.'; Empty = 'No backup servers exceed their reported allowance.' }
        @{Key = 'NearLimit'; Title = 'Backup Servers close to reach the limit'; Color = '#a15c00'; Rows = $near; Description = "At least one pool is at $thresholdText% through 100%, with no pool over its allowance. Highest usage first."; Empty = "No backup servers are between $thresholdText% and 100% usage." }
        @{Key = 'Rest'; Title = 'Rest of Backup Servers'; Color = '#087f5b'; Rows = $rest; Description = "Available pools are below $thresholdText%, or usage is unverified. Sorted by server name."; Empty = 'No other backup servers were returned.' }
    )
    $sectionHtml = New-Object System.Text.StringBuilder
    $headerStyle = 'border:1px solid #c8d4da;padding:7px 8px;font-family:Arial,Helvetica,sans-serif;font-size:11px;line-height:15px;color:#334155;background-color:#e9eff2;'
    foreach ($section in $sections) {
        $count = @($section.Rows).Count
        [void]$sectionHtml.Append(@"
<tr><td style="padding:20px 16px 0;font-family:Arial,Helvetica,sans-serif;">
<p style="margin:0 0 5px;font-family:Arial,Helvetica,sans-serif;font-size:17px;font-weight:bold;color:$($section.Color);">$(ConvertTo-HtmlText $section.Title) ($count)</p>
<p style="margin:0 0 8px;font-family:Arial,Helvetica,sans-serif;font-size:11px;color:#64748b;">$(ConvertTo-HtmlText $section.Description)</p>
<table class="inventory-grid" aria-label="$(ConvertTo-HtmlText $section.Title)" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;border-collapse:collapse;font-family:Arial,Helvetica,sans-serif;">
<thead><tr bgcolor="#e9eff2">
<th scope="col" width="27%" align="left" valign="top" style="$headerStyle">Backup server</th>
<th scope="col" width="17%" align="left" valign="top" style="$headerStyle">License</th>
<th scope="col" width="14%" align="right" valign="top" style="$headerStyle">Instances<br><span style="font-weight:normal;">Used / licensed</span></th>
<th scope="col" width="12%" align="right" valign="top" style="$headerStyle">Sockets<br><span style="font-weight:normal;">Used / licensed</span></th>
<th scope="col" width="16%" align="right" valign="top" style="$headerStyle">Capacity ($(ConvertTo-HtmlText $Settings.CapacityUnit))<br><span style="font-weight:normal;">Used / licensed</span></th>
<th scope="col" width="14%" align="left" valign="top" style="$headerStyle">Expires<br><span style="font-weight:normal;">License / support</span></th>
</tr></thead><tbody>
"@)
        if ($count -eq 0) {
            [void]$sectionHtml.Append('<tr><td colspan="6" style="border:1px solid #d9e1e5;padding:8px;font-family:Arial,Helvetica,sans-serif;font-size:12px;color:#64748b;">' + (ConvertTo-HtmlText $section.Empty) + '</td></tr>')
        }
        else {
            $sorted = if ($section.Key -eq 'Rest') { @($section.Rows | Sort-Object Name) }
            else { @($section.Rows | Sort-Object @{Expression = 'HighestPercent'; Descending = $true }, Name) }
            $rowIndex = 0
            foreach ($server in $sorted) {
                [void]$sectionHtml.Append((Get-ServerGridRowHtml -Server $server -RowIndex $rowIndex))
                $rowIndex++
            }
        }
        [void]$sectionHtml.Append('</tbody></table></td></tr>')
    }
    $unverifiedText = if ($unverified -gt 0) { " $unverified server(s) have no verifiable active pool." } else { '' }
    return @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$(ConvertTo-HtmlText $Settings.ReportTitle)</title></head>
<body bgcolor="#ffffff" style="margin:0;padding:0;background-color:#ffffff;font-family:Arial,Helvetica,sans-serif;color:#1f2937;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;border-collapse:collapse;font-family:Arial,Helvetica,sans-serif;">
<tr><td bgcolor="#102f2a" style="padding:20px 16px;background-color:#102f2a;border-top:4px solid #00b77a;font-family:Arial,Helvetica,sans-serif;">
<p style="margin:0 0 6px;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:bold;color:#9ee5c4;">$(ConvertTo-HtmlText $Settings.Organisation) / LICENSE INVENTORY</p>
<p style="margin:0 0 8px;font-family:Arial,Helvetica,sans-serif;font-size:26px;font-weight:bold;color:#ffffff;">$(ConvertTo-HtmlText $Settings.ReportTitle)</p>
<p style="margin:0 0 8px;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#e1eee8;">$(ConvertTo-HtmlText $headline)</p>
<p style="margin:0;font-family:Arial,Helvetica,sans-serif;font-size:11px;color:#c0d4cd;">$generated &middot; Near-limit threshold: $thresholdText%</p>
</td></tr>
<tr><td style="padding:16px 16px 0;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#f4f7f8" style="width:100%;border-collapse:collapse;background-color:#f4f7f8;font-family:Arial,Helvetica,sans-serif;"><tr>
<td width="25%" align="center" valign="top" style="border:1px solid #d9e1e5;padding:12px 6px;font-family:Arial,Helvetica,sans-serif;"><b style="font-size:26px;color:#102f2a;">$($Servers.Count)</b><br><span style="font-size:11px;color:#475569;">BACKUP SERVERS</span></td>
<td width="25%" align="center" valign="top" style="border:1px solid #d9e1e5;padding:12px 6px;font-family:Arial,Helvetica,sans-serif;"><b style="font-size:26px;color:#b42318;">$($over.Count)</b><br><span style="font-size:11px;color:#475569;">OVER ALLOWANCE</span></td>
<td width="25%" align="center" valign="top" style="border:1px solid #d9e1e5;padding:12px 6px;font-family:Arial,Helvetica,sans-serif;"><b style="font-size:26px;color:#a15c00;">$($near.Count)</b><br><span style="font-size:11px;color:#475569;">NEAR LIMIT</span></td>
<td width="25%" align="center" valign="top" style="border:1px solid #d9e1e5;padding:12px 6px;font-family:Arial,Helvetica,sans-serif;"><b style="font-size:26px;color:#087f5b;">$($rest.Count)</b><br><span style="font-size:11px;color:#475569;">OTHER SERVERS</span></td>
</tr></table></td></tr>
$($sectionHtml.ToString())
<tr><td style="padding:18px 16px;font-family:Arial,Helvetica,sans-serif;font-size:11px;line-height:16px;color:#64748b;">
<b>Reading the table:</b> Each server appears once, in its most urgent section. Pool cells show used / licensed, percentage, and allowance left or over. Used &gt; licensed is over allowance; $thresholdText% through 100% is near limit. N/A means unavailable or invalid; 0 / 0 is inactive. Unavailable pools are unverified; available pools determine the section.$unverifiedText<br>
Socket, instance and capacity pools are independent; shared license allowances are not added across servers. Capacity uses $(ConvertTo-HtmlText $Settings.CapacityUnit). Expiration dates are informational; percentages are classified before rounding.<br>
Source: $(ConvertTo-HtmlText $SourceLabel) &middot; Veeam ONE Backup Inventory
</td></tr></table></body></html>
"@
}

function ConvertTo-GraphBase64Url {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GraphCertificateAssertion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TokenEndpoint,
        [Parameter(Mandatory = $true)][guid]$ClientId,
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    if (-not $Certificate.HasPrivateKey) {
        throw 'The Graph authentication certificate must have an accessible private key.'
    }
    $now = [DateTime]::UtcNow
    if ($now -lt $Certificate.NotBefore.ToUniversalTime() -or $now -ge $Certificate.NotAfter.ToUniversalTime()) {
        throw 'The Graph authentication certificate is not currently valid. Renew or select a valid certificate.'
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $rsa = $null
    try {
        $certificateHash = $sha256.ComputeHash($Certificate.RawData)
        $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc)
        $nowSeconds = [long][Math]::Floor(($now - $epoch).TotalSeconds)
        $header = [ordered]@{
            alg        = 'PS256'
            typ        = 'JWT'
            'x5t#S256' = ConvertTo-GraphBase64Url -Bytes $certificateHash
        }
        $claims = [ordered]@{
            aud = $TokenEndpoint
            iss = $ClientId.ToString()
            sub = $ClientId.ToString()
            jti = [guid]::NewGuid().ToString()
            iat = $nowSeconds
            nbf = $nowSeconds - 30
            exp = $nowSeconds + 300
        }
        $encodedHeader = ConvertTo-GraphBase64Url -Bytes ([Text.Encoding]::UTF8.GetBytes(($header | ConvertTo-Json -Compress)))
        $encodedClaims = ConvertTo-GraphBase64Url -Bytes ([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress)))
        $unsignedAssertion = '{0}.{1}' -f $encodedHeader, $encodedClaims
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
        if ($null -eq $rsa) {
            throw 'The Graph authentication certificate must use an RSA private key.'
        }
        try {
            $signature = $rsa.SignData(
                [Text.Encoding]::UTF8.GetBytes($unsignedAssertion),
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pss
            )
        }
        catch {
            throw 'Certificate signing failed. Use an RSA certificate whose private key supports PSS, such as one created with Microsoft Software Key Storage Provider; ensure the scheduled-task identity can read that private key.'
        }
        return '{0}.{1}' -f $unsignedAssertion, (ConvertTo-GraphBase64Url -Bytes $signature)
    }
    finally {
        if ($null -ne $rsa) { $rsa.Dispose() }
        $sha256.Dispose()
    }
}

function Get-M365GraphAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$TenantId,
        [Parameter(Mandatory = $true)][guid]$ClientId,
        [ValidateSet('Certificate', 'ClientSecret')][string]$AuthMode = 'Certificate',
        [string]$CertificateThumbprint,
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$CertificateStoreLocation = 'CurrentUser',
        [string]$ClientSecret = '',
        [ValidateRange(1, 300)][int]$TimeoutSec = 60
    )

    # Public Microsoft 365 cloud. Credentials and tokens are not printed or logged.
    $tokenEndpoint = 'https://login.microsoftonline.com/{0}/oauth2/v2.0/token' -f [Uri]::EscapeDataString($TenantId)
    $tokenRequest = @{
        client_id  = $ClientId.ToString()
        scope      = 'https://graph.microsoft.com/.default'
        grant_type = 'client_credentials'
    }
    $certificate = $null
    try {
        if ($AuthMode -eq 'Certificate') {
            $thumbprint = ($CertificateThumbprint -replace '\s', '').ToUpperInvariant()
            if ($thumbprint -notmatch '^[0-9A-F]{40}$') {
                throw 'Set CertificateThumbprint to the 40-character thumbprint of the registered certificate.'
            }
            $certificatePath = 'Cert:\{0}\My\{1}' -f $CertificateStoreLocation, $thumbprint
            $certificate = Get-Item -LiteralPath $certificatePath -ErrorAction Stop
            $tokenRequest.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            $tokenRequest.client_assertion = New-GraphCertificateAssertion -TokenEndpoint $tokenEndpoint -ClientId $ClientId -Certificate $certificate
        }
        else {
            if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
                throw 'Set Config.ClientSecret to your app client secret VALUE before enabling email with ClientSecret authentication.'
            }
            $tokenRequest.client_secret = $ClientSecret
        }

        # A hashtable is form encoded by PowerShell, including special characters in secret values.
        try {
            $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $tokenRequest -ContentType 'application/x-www-form-urlencoded' -TimeoutSec $TimeoutSec -ErrorAction Stop
        }
        catch {
            throw ('Microsoft 365 authentication failed. Check TenantId, ClientId, credential validity, certificate/private-key access, and admin consent. {0}' -f $_.Exception.Message)
        }
        if ([string]::IsNullOrWhiteSpace([string]$tokenResponse.access_token)) {
            throw 'Microsoft Entra ID returned no access token.'
        }
        return [string]$tokenResponse.access_token
    }
    finally {
        if ($null -ne $certificate) { $certificate.Dispose() }
        if ($null -ne $tokenRequest) { $tokenRequest.Clear() }
        $clientSecret = $null
        $tokenResponse = $null
    }
}

function ConvertTo-GraphMailRecipients {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Addresses = @())

    foreach ($address in $Addresses) {
        if ([string]::IsNullOrWhiteSpace($address)) {
            throw 'Email recipient lists must contain valid, non-empty email addresses.'
        }
        try { $parsed = New-Object System.Net.Mail.MailAddress($address.Trim()) }
        catch { throw ('Invalid email address: {0}' -f $address) }
        if ($parsed.Address -ne $address.Trim()) {
            throw ('Use an email address without a display name: {0}' -f $address)
        }
        @{ emailAddress = @{ address = $parsed.Address } }
    }
}

function New-M365HtmlMailPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$ToRecipients,
        [string[]]$CcRecipients = @(),
        [string[]]$BccRecipients = @(),
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Subject,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$HtmlBody,
        [bool]$AttachHtmlReport = $false,
        [string]$AttachmentFileName = 'Veeam-ONE-License-Report.html',
        [bool]$SaveToSentItems = $true
    )

    $message = [ordered]@{
        subject      = $Subject
        body         = @{ contentType = 'HTML'; content = $HtmlBody }
        toRecipients = @(ConvertTo-GraphMailRecipients -Addresses $ToRecipients)
    }
    if (@($CcRecipients).Count -gt 0) { $message.ccRecipients = @(ConvertTo-GraphMailRecipients -Addresses $CcRecipients) }
    if (@($BccRecipients).Count -gt 0) { $message.bccRecipients = @(ConvertTo-GraphMailRecipients -Addresses $BccRecipients) }
    if ($AttachHtmlReport) {
        if ([string]::IsNullOrWhiteSpace($AttachmentFileName)) { throw 'AttachmentFileName cannot be empty when an attachment is enabled.' }
        $attachmentBytes = [Text.Encoding]::UTF8.GetBytes($HtmlBody)
        if ($attachmentBytes.Length -ge 3000000) {
            throw 'The HTML attachment must be smaller than 3 MB for this simple sendMail implementation. Disable AttachHtmlReport or narrow the report scope.'
        }
        $message.attachments = @(@{
                '@odata.type' = '#microsoft.graph.fileAttachment'
                name          = [IO.Path]::GetFileName($AttachmentFileName)
                contentType   = 'text/html'
                contentBytes  = [Convert]::ToBase64String($attachmentBytes)
            })
    }
    # A real JSON Boolean is required; avoid the string "false".
    $payload = [ordered]@{ message = $message; saveToSentItems = $SaveToSentItems }
    return ($payload | ConvertTo-Json -Depth 12 -Compress)
}

function Send-M365HtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$TenantId,
        [Parameter(Mandatory = $true)][guid]$ClientId,
        [ValidateSet('Certificate', 'ClientSecret')][string]$AuthMode = 'Certificate',
        [string]$CertificateThumbprint,
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$CertificateStoreLocation = 'CurrentUser',
        [string]$ClientSecret = '',
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SenderEmail,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$ToRecipients,
        [string[]]$CcRecipients = @(),
        [string[]]$BccRecipients = @(),
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Subject,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$HtmlBody,
        [bool]$AttachHtmlReport = $false,
        [string]$AttachmentFileName = 'Veeam-ONE-License-Report.html',
        [bool]$SaveToSentItems = $true,
        [ValidateRange(1, 300)][int]$TimeoutSec = 60
    )

    # Validate and build the request before obtaining a credential or calling Graph.
    $null = @(ConvertTo-GraphMailRecipients -Addresses @($SenderEmail))
    $payloadJson = New-M365HtmlMailPayload -ToRecipients $ToRecipients -CcRecipients $CcRecipients -BccRecipients $BccRecipients -Subject $Subject -HtmlBody $HtmlBody -AttachHtmlReport $AttachHtmlReport -AttachmentFileName $AttachmentFileName -SaveToSentItems $SaveToSentItems
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payloadJson)
    # Conservatively cap a single Graph request; keep oversized reports as an HTML export.
    if ($payloadBytes.Length -ge 4000000) {
        throw 'The email JSON is too large for a single Graph sendMail request. Disable the HTML attachment, narrow the report scope, or distribute the exported report separately.'
    }

    $accessToken = $null
    $headers = $null
    # Enable TLS 1.2 for Windows PowerShell 5.1 without removing existing enabled protocols.
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        $accessToken = Get-M365GraphAccessToken -TenantId $TenantId -ClientId $ClientId -AuthMode $AuthMode -CertificateThumbprint $CertificateThumbprint -CertificateStoreLocation $CertificateStoreLocation -ClientSecret $ClientSecret -TimeoutSec $TimeoutSec
        $headers = @{ Authorization = 'Bearer {0}' -f $accessToken }
        $endpoint = 'https://graph.microsoft.com/v1.0/users/{0}/sendMail' -f [Uri]::EscapeDataString($SenderEmail.Trim())
        try {
            # Bytes prevent Windows PowerShell from using a legacy text encoding for non-ASCII HTML.
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $endpoint -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $payloadBytes -TimeoutSec $TimeoutSec -ErrorAction Stop
        }
        catch {
            # Do not retry automatically: a timed-out send can already have been accepted.
            throw ('Graph did not confirm acceptance of this email. Check Mail.Send application permission, admin consent, the sender mailbox, and any Exchange application scope. If the request timed out, verify message trace before rerunning to avoid duplicate mail. {0}' -f $_.Exception.Message)
        }
        if ([int]$response.StatusCode -ne 202) {
            throw ('Unexpected Graph sendMail response: HTTP {0}.' -f $response.StatusCode)
        }
        [pscustomobject]@{
            Status         = 'Accepted'
            HttpStatusCode = [int]$response.StatusCode
            Sender         = $SenderEmail.Trim()
            ToRecipients   = @($ToRecipients)
            AcceptedAtUtc  = [DateTime]::UtcNow
            RequestId      = [string]$response.Headers['request-id']
            Detail         = 'Microsoft Graph accepted the request. This does not confirm delivery; use Exchange message trace if needed.'
        }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
        if ($null -ne $headers) { $headers.Clear() }
        $accessToken = $null
    }
}


function Invoke-BackupLicenseReport {
    [CmdletBinding()]
    param([hashtable]$Settings, [string]$Server, [string]$Database, [string]$SnapshotPath, [string]$Destination, [double]$Threshold)
    $ErrorActionPreference = 'Stop'
    if ($Threshold -lt 1 -or $Threshold -gt 100) { throw 'WarningThresholdPercent must be between 1 and 100.' }
    if ($Settings.CapacityDisplayDivisor -le 0) { throw 'CapacityDisplayDivisor must be greater than zero.' }
    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        $resolvedInput = (Resolve-Path -LiteralPath $SnapshotPath -ErrorAction Stop).ProviderPath
        $delimiter = if ([IO.Path]::GetExtension($resolvedInput) -eq '.csv') { ',' } else { "`t" }
        $rows = @(Import-Csv -LiteralPath $resolvedInput -Delimiter $delimiter)
        $sourceLabel = 'Imported SQL result: ' + [IO.Path]::GetFileName($resolvedInput)
    }
    else {
        Write-Host "Reading Veeam ONE Backup Inventory from $Server / $Database..." -ForegroundColor Cyan
        $rows = @(Invoke-BackupInventorySql -Server $Server -Database $Database -Settings $Settings)
        $sourceLabel = "$Server / $Database"
    }
    $servers = @(Get-BackupLicenseServers -Rows $rows -Settings $Settings -Threshold $Threshold)
    if ($servers.Count -eq 0) { Write-Warning 'No license records returned. The HTML will show an empty inventory, not a healthy status.' }
    $html = New-BackupLicenseHtml -Servers $servers -Settings $Settings -Threshold $Threshold -SourceLabel $sourceLabel
    if ([string]::IsNullOrWhiteSpace($Destination)) {
        $outputDirectory = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
            # Pasted code and ISE selections have no script directory.
            $outputDirectory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
        }
        $Destination = Join-Path -Path $outputDirectory -ChildPath 'BackupLicenseInventory.html'
    }
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath) -and $fullPath -eq $resolvedInput) { throw 'OutputPath must differ from InputPath.' }
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($fullPath, $html, $encoding)
    Write-Host "HTML report saved: $fullPath" -ForegroundColor Green
    $servers | Select-Object Name, Bucket, Status | Format-Table -AutoSize | Out-Host
    if ($Settings.OpenReportAfterExport) { Start-Process -FilePath $fullPath }
    if ($Settings.EnableEmail) {
        $overCount = @($servers | Where-Object { $_.Bucket -eq 'Overused' }).Count
        $nearCount = @($servers | Where-Object { $_.Bucket -eq 'NearLimit' }).Count
        $subject = "$($Settings.EmailSubjectPrefix) | $overCount over / $nearCount near | $((Get-Date).ToString('yyyy-MM-dd'))"
        $mailParameters = @{
            TenantId                 = $Settings.TenantId
            ClientId                 = $Settings.ClientId
            AuthMode                 = $Settings.AuthMode
            CertificateThumbprint    = $Settings.CertificateThumbprint
            CertificateStoreLocation = $Settings.CertificateStoreLocation
            ClientSecret             = $Settings.ClientSecret
            SenderEmail              = $Settings.SenderEmail
            ToRecipients             = $Settings.ToRecipients
            CcRecipients             = $Settings.CcRecipients
            Subject                  = $subject
            HtmlBody                 = $html
            AttachHtmlReport         = $Settings.AttachHtmlReport
            AttachmentFileName       = [IO.Path]::GetFileName($fullPath)
            SaveToSentItems          = $Settings.SaveToSentItems
        }
        try {
            $mailResult = Send-M365HtmlReport @mailParameters
            Write-Host "Microsoft Graph accepted the HTML email from $($mailResult.Sender). Acceptance does not confirm delivery." -ForegroundColor Green
        }
        catch {
            throw "The HTML report was saved to '$fullPath', but email was not confirmed: $($_.Exception.Message)"
        }
    }
    [PSCustomObject]@{
        HtmlPath = $fullPath; ServerCount = $servers.Count
        OverusedCount = @($servers | Where-Object { $_.Bucket -eq 'Overused' }).Count
        NearLimitCount = @($servers | Where-Object { $_.Bucket -eq 'NearLimit' }).Count
        RestCount = @($servers | Where-Object { $_.Bucket -eq 'Rest' }).Count
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-BackupLicenseReport -Settings $Config -Server $SQLServer -Database $SQLDBName -SnapshotPath $InputPath -Destination $OutputPath -Threshold $WarningThresholdPercent
}

License Report for Thermo.txt
Displaying License Report for Thermo.txt.