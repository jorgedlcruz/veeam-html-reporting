<#
.SYNOPSIS
    Generates a report on Veeam Backup Job History highlighting workloads with consecutive failures.

.DESCRIPTION
    This PowerShell script connects to the Veeam ONE SQL database, retrieves job execution history,
    and identifies jobs with a defined number of consecutive failures within a configurable time window (in days).
    It outputs a color-coded console summary and builds a detailed HTML report including job-level and
    workload-level information, sorted and filtered as needed.

.PARAMETER reportIntervalDays
    Number of past days to consider when analyzing job history.

.PARAMETER requiredFailureCount
    Number of consecutive failures that must be detected to include the job in the report.

.OUTPUTS
    An HTML report showing jobs and their workloads that match the failure criteria. The report is saved
    in the script's directory and automatically sent via Microsoft Graph API email with an attachment.

.EXAMPLE
    .\VONE_Failed_Jobs_Last_X_Sessions.ps1
    Retrieves job history for the last 3 days and reports any jobs with 3 consecutive failures,
    then emails the HTML report to a predefined recipient.

.NOTES
    NAME: VONE_Failed_Jobs_Last_X_Sessions.ps1
    VERSION: 1.1
    AUTHOR: Jorge de la Cruz
    TWITTER: @jorgedelacruz
    GITHUB: https://github.com/jorgedelacruz

.LINK
    https://jorgedelacruz.uk/
#>

# Global Parameters (Edit here)
$SQLServer = "YOURSQL\INSTANCE"
$SQLDBName = "VeeamONE"
$reportIntervalDays = 3
$requiredFailureCount = 3
$RecipientEmail = "YOUREMAIL@ADDRESS.COM"
$TenantId = "YOURTENANT.onmicrosoft.com"
$ClientId = "YOURCLIENTIDAZURE"
$ClientSecret = ConvertTo-SecureString "YOURAPPREGISTRATIONSECRET" -AsPlainText -Force

$ConnectionString = "Server=$SQLServer;Database=$SQLDBName;Integrated Security=True;"

function Invoke-StoredProcedure {
    param (
        [string]$ProcedureName,
        [hashtable]$Parameters,
        [hashtable]$ParameterTypes = @{}
    )
    
    Write-Host "Executing: $ProcedureName" -ForegroundColor Yellow
    Write-Host "Parameters:" -ForegroundColor Yellow
    foreach ($key in $Parameters.Keys) {
        $paramValue = if ($Parameters[$key] -eq $null) { "NULL" } else { "'$($Parameters[$key])'" }
        $paramType = if ($ParameterTypes[$key]) { "[$($ParameterTypes[$key])]" } else { "[NVarChar]" }
        Write-Host "  @$key = $paramValue $paramType" -ForegroundColor Gray
    }
    
    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $command = $connection.CreateCommand()
    $command.CommandText = $ProcedureName
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    $command.CommandTimeout = 86400

    foreach ($key in $Parameters.Keys) {
        $type = $ParameterTypes[$key]
        if (-not $type) {
            $type = [System.Data.SqlDbType]::NVarChar
        }
        
        if ($type -eq [System.Data.SqlDbType]::NVarChar) {
            $param = $command.Parameters.Add("@$key", $type, 4000)
        } else {
            $param = $command.Parameters.Add("@$key", $type)
        }
        
        if ($Parameters[$key] -eq $null) {
            $param.Value = [DBNull]::Value
        } else {
            $param.Value = $Parameters[$key]
        }
    }

    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
    $table = New-Object System.Data.DataTable
    try {
        $connection.Open()
        Write-Host "Connection opened successfully" -ForegroundColor Green
        $rowsAffected = $adapter.Fill($table)
        Write-Host "Rows returned: $rowsAffected" -ForegroundColor Green
    } catch {
        Write-Error "Failed to execute stored procedure: $_"
        Write-Host "Connection State: $($connection.State)" -ForegroundColor Red
    } finally {
        $connection.Close()
    }

    return $table
}

Write-Host "Testing SQL connection..." -ForegroundColor Cyan
try {
    $testConnection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $testConnection.Open()
    Write-Host "✓ SQL Connection successful" -ForegroundColor Green
    $testConnection.Close()
} catch {
    Write-Error "❌ SQL Connection failed: $_"
    return
}

Write-Host "`nFetching job history..." -ForegroundColor Cyan
$jobHistory = Invoke-StoredProcedure -ProcedureName "reportpack.rsrp_Backup_JobHistoricalInformation" -Parameters @{
    Scope = "<root><id>1002</id></root>"
    JobIds = "-1"
    JobType = 1
    Period = $null
    DateFrom = $null
    DateTo = $null
    TimeZone = 60
    JobStatusesList = "-1"
    Interval = $reportIntervalDays
    IntervalPeriod = "day"
} -ParameterTypes @{
    JobType = [System.Data.SqlDbType]::Int
    TimeZone = [System.Data.SqlDbType]::Int
    Interval = [System.Data.SqlDbType]::Int
    IntervalPeriod = [System.Data.SqlDbType]::NVarChar
}

Write-Host "`nJob history fetch complete. Total rows returned: $($jobHistory.Count)" -ForegroundColor Green

# Debug: Show column names
Write-Host "`nColumn names in result set:" -ForegroundColor Yellow
$jobHistory.Columns | ForEach-Object { Write-Host "  - $($_.ColumnName) [$($_.DataType)]" -ForegroundColor Gray }

# Debug: Show first few rows with all columns
Write-Host "`nFirst 5 rows (all columns):" -ForegroundColor Yellow
$jobHistory | Select-Object -First 5 | Format-Table -AutoSize

if ($jobHistory.Count -eq 0) {
    Write-Host "❌ Stored procedure returned no rows. Please verify parameters and SQL connectivity." -ForegroundColor Red
    return
}

Write-Host "`nFiltering valid records..." -ForegroundColor Cyan
$cutoffDate = (Get-Date).AddDays(-$reportIntervalDays)
Write-Host "Cutoff date: $cutoffDate" -ForegroundColor Gray

$originalCount = $jobHistory.Count
$jobHistory = $jobHistory | Where-Object {
    $hasJobUid = $_.job_uid -and $_.job_uid -ne [DBNull]::Value -and $_.job_uid.ToString().Trim() -ne ""
    $hasJobName = $_.job_name -and $_.job_name -ne [DBNull]::Value -and $_.job_name.ToString().Trim() -ne ""
    $hasValidStatus = $_.job_status -and $_.job_status -ne [DBNull]::Value
    $hasValidDate = $_.job_start_time -and $_.job_start_time -ne [DBNull]::Value
    
    $validDateRange = $false
    if ($hasValidDate) {
        try {
            $startTime = [DateTime]$_.job_start_time
            $validDateRange = $startTime -ge $cutoffDate
        } catch {
            $validDateRange = $false
        }
    }
    
    $isValid = $hasJobUid -and $hasJobName -and $hasValidStatus -and $validDateRange
    
    # Debug output for invalid records
    if (-not $isValid) {
        Write-Host "  Filtered out: UID=$($_.job_uid), Name=$($_.job_name), Status=$($_.job_status), Date=$($_.job_start_time)" -ForegroundColor DarkGray
    }
    
    return $isValid
}

Write-Host "Records after filtering: $($jobHistory.Count) (was $originalCount)" -ForegroundColor Green

if ($jobHistory.Count -eq 0) {
    Write-Host "❌ No valid records after filtering. Check date range and data quality." -ForegroundColor Red
    return
}

# Show sample of filtered data
Write-Host "`nSample of filtered data:" -ForegroundColor Yellow
$jobHistory | Select-Object job_uid, job_name, job_start_time, job_status | Select-Object -First 10 | Format-Table -AutoSize

Write-Host "`nAnalyzing job failures..." -ForegroundColor Cyan
$jobFailGroups = @()

foreach ($group in $jobHistory | Group-Object job_uid) {
    $sorted = $group.Group | Sort-Object job_start_time -Descending
    $latestN = $sorted | Select-Object -First $requiredFailureCount

    if ($latestN.Count -lt $requiredFailureCount) { 
        Write-Host "Skipping job $($group.Name): Only $($latestN.Count) sessions found (need $requiredFailureCount)" -ForegroundColor DarkGray
        continue 
    }

    Write-Host "`nChecking JobId: $($group.Name) | JobName: $($latestN[0].job_name)" -ForegroundColor Cyan
    $failureCount = 0
    foreach ($entry in $latestN) {
        $statusValue = if ($entry.job_status -and $entry.job_status -ne [DBNull]::Value) { 
            $entry.job_status.ToString() 
        } else { 
            'Unknown' 
        }
        
        $statusColor = switch ($statusValue.ToLower()) {
            'failed'   { 'Red'; $failureCount++ }
            'warning'  { 'Yellow' }
            'success'  { 'Green' }
            'running'  { 'Gray' }
            default    { 'White' }
        }
        Write-Host " - [$($entry.job_start_time)] Status: $statusValue" -ForegroundColor $statusColor
    }

    if ($failureCount -eq $requiredFailureCount) {
        Write-Host " >>> MATCH: Job has $requiredFailureCount consecutive failures." -ForegroundColor DarkRed
        $jobFailGroups += [PSCustomObject]@{
            job_uid = $group.Name
            Group   = $latestN
        }
    } else {
        Write-Host " --- SKIPPED: Only $failureCount failures out of $requiredFailureCount sessions." -ForegroundColor Cyan
    }
}

Write-Host "`nDetected $($jobFailGroups.Count) jobs with $requiredFailureCount consecutive failures." -ForegroundColor $(if ($jobFailGroups.Count -eq 0) { 'Green' } else { 'Red' })

if ($jobFailGroups.Count -eq 0) {
    Write-Host "✓ Congratulations, no job has been failing $requiredFailureCount consecutive times over $reportIntervalDays days." -ForegroundColor Green
    return
}

Write-Host "`nGenerating HTML report..." -ForegroundColor Cyan

# HTML report
$html = @"
<html><head><style>
body { font-family: Arial; margin: 20px; }
table { border-collapse: collapse; width: 100%; margin-bottom: 40px; }
th, td { border: 1px solid #ccc; padding: 8px; text-align: left; }
th { background-color: #f2f2f2; font-weight: bold; }
h1 { color: #d32f2f; }
h2, h3 { margin-top: 40px; color: #1976d2; }
.failed { background-color: #ffebee; }
.warning { background-color: #fff3e0; }
.success { background-color: #e8f5e8; }
</style></head><body>
<h1>Failed Backup Jobs Report</h1>
<p><strong>Criteria:</strong> $requiredFailureCount consecutive failures in the last $reportIntervalDays days</p>
<p><strong>Report Generated:</strong> $(Get-Date)</p>
<p><strong>Jobs Found:</strong> $($jobFailGroups.Count)</p>

<h2>Job Summary</h2>
<table>
<tr><th>Job Name</th><th>Backup Server</th><th>Status</th><th>Total VMs</th><th>Successful VMs</th><th>Failed VMs</th><th>Backup Type</th><th>Start Time</th><th>Duration</th><th>Processing Rate (MB/s)</th><th>Data Size (GB)</th><th>Transferred (GB)</th><th>Total Backup Size (GB)</th></tr>
"@

foreach ($group in $jobFailGroups) {
    foreach ($job in $group.Group) {
        $statusClass = switch ($job.job_status.ToLower()) {
            'failed'   { 'failed' }
            'warning'  { 'warning' }
            'success'  { 'success' }
            default    { '' }
        }

        # Calculate VM counts
        $totalVMs = if ($job.total_vm_backuped -and $job.total_vm_backuped -ne [DBNull]::Value) { $job.total_vm_backuped } else { 0 }
        $successfulVMs = if ($job.successed_vm_backup -and $job.successed_vm_backup -ne [DBNull]::Value) { $job.successed_vm_backup } else { 0 }
        $failedVMs = $totalVMs - $successfulVMs

        $sourceSizeGB     = if ($job.bakup_source_size -and $job.bakup_source_size -ne [DBNull]::Value) { "{0:N2}" -f ($job.bakup_source_size / 1GB) } else { "" }
        $transferSizeGB   = if ($job.bakup_transfered_size -and $job.bakup_transfered_size -ne [DBNull]::Value) { "{0:N2}" -f ($job.bakup_transfered_size / 1GB) } else { "" }
        $fullSizeGB       = if ($job.bakup_full_size -and $job.bakup_full_size -ne [DBNull]::Value) { "{0:N2}" -f ($job.bakup_full_size / 1GB) } else { "" }
        $processingRate   = if ($job.bakup_processing_rate -and $job.bakup_processing_rate -ne [DBNull]::Value) { $job.bakup_processing_rate } else { "" }
        $duration         = if ($job.job_session_duration -and $job.job_session_duration -ne [DBNull]::Value) { (New-TimeSpan -Seconds $job.job_session_duration).ToString() } else { "" }

        $html += "<tr class='$statusClass'><td>$($job.job_name)</td><td>$($job.bs_name)</td><td>$($job.job_status)</td><td>$totalVMs</td><td>$successfulVMs</td><td>$failedVMs</td><td>$($job.restore_point_type)</td><td>$($job.job_start_time)</td><td>$duration</td><td>$processingRate</td><td>$sourceSizeGB</td><td>$transferSizeGB</td><td>$fullSizeGB</td></tr>"
    }
}

$html += "</table>"

# Workload Details Table
foreach ($group in $jobFailGroups) {
    Write-Host "Fetching workload failure details for job: $($group.Group[0].job_name)..." -ForegroundColor DarkCyan
    
    try {
        $details = Invoke-StoredProcedure -ProcedureName "reportpack.rsrp_Backup_JobHistoricalInformationDetails" -Parameters @{ 
            JobId = [Guid]::Parse($group.job_uid)
            SessionId = $null
            Period = $null
            DateFrom = $null
            DateTo = $null
            TimeZone = 60
            Interval = $reportIntervalDays
            IntervalPeriod = "day" 
        } -ParameterTypes @{ 
            JobId = [System.Data.SqlDbType]::UniqueIdentifier
            TimeZone = [System.Data.SqlDbType]::Int
            Interval = [System.Data.SqlDbType]::Int
            IntervalPeriod = [System.Data.SqlDbType]::NVarChar
        }

        $failedDetails = $details | Where-Object { $_.job_status -eq 'Failed' }

        $html += "<h3>$($group.Group[0].job_name) - Workload Details ($($failedDetails.Count) failed workloads)</h3>"
        $html += "<table><tr><th>Workload Name</th><th>Status</th><th>Backup Type</th><th>Start Time</th><th>Duration</th><th>Transport Mode</th><th>Processing Rate (MB/s)</th><th>Processed (GB)</th><th>Read (GB)</th><th>Transferred (GB)</th><th>Source Load (%)</th><th>Proxy Load (%)</th><th>Network Load (%)</th><th>Target Load (%)</th></tr>"

        if ($failedDetails.Count -eq 0) {
            $html += "<tr><td colspan='14' style='text-align: center; font-style: italic;'>No failed workload details found</td></tr>"
        } else {
            $failedDetails = $failedDetails | Sort-Object backup_vm_start_time -Descending
            foreach ($row in $failedDetails) {
                $processedGB   = if ($row.processed_used_size -and $row.processed_used_size -ne [DBNull]::Value) { "{0:N2}" -f ($row.processed_used_size / 1GB) } else { "" }
                $readGB        = if ($row.read_size -and $row.read_size -ne [DBNull]::Value) { "{0:N2}" -f ($row.read_size / 1GB) } else { "" }
                $transferredGB = if ($row.transferred -and $row.transferred -ne [DBNull]::Value) { "{0:N2}" -f ($row.transferred / 1GB) } else { "" }
                $rate          = if ($row.processing_rate -and $row.processing_rate -ne [DBNull]::Value) { $row.processing_rate } else { "" }
                $duration      = if ($row.backup_vm_duration -and $row.backup_vm_duration -ne [DBNull]::Value) { (New-TimeSpan -Seconds $row.backup_vm_duration).ToString() } else { "" }

                $html += "<tr class='failed'><td>$($row.vm_name)</td><td>$($row.job_status)</td><td>$($row.backup_type)</td><td>$($row.backup_vm_start_time)</td><td>$duration</td><td>$($row.src_transport_mode)</td><td>$rate</td><td>$processedGB</td><td>$readGB</td><td>$transferredGB</td><td>$($row.source_load)</td><td>$($row.proxy_load)</td><td>$($row.network_load)</td><td>$($row.target_load)</td></tr>"
            }
        }
        $html += "</table>"
    } catch {
        Write-Warning "Failed to get workload details for job $($group.Group[0].job_name): $_"
        $html += "<h3>$($group.Group[0].job_name) - Workload Details</h3>"
        $html += "<p style='color: red;'>Error retrieving workload details: $_</p>"
    }
}

$html += "</body></html>"

# Save the HTML file
$outputPath = "$PSScriptRoot\BackupJobHistoricalFailures.html"
$html | Out-File -FilePath $outputPath -Encoding utf8
Write-Host "✓ HTML report generated: $outputPath" -ForegroundColor Green

# Email sending code (optional - comment out if not needed)
Write-Host "`nSending email..." -ForegroundColor Cyan
try {
    Import-Module MSAL.PS -ErrorAction Stop

    $appRegistration = @{
        TenantId     = $TenantId
        ClientId     = $ClientId
        ClientSecret = $ClientSecret
    }

    $msalToken = Get-msaltoken @appRegistration -ForceRefresh

    $requestBody = @{
        "message" = [PSCustomObject]@{
            "subject"      = "[Report] Veeam ONE Job Failures ($requiredFailureCount Consecutive Failures in $reportIntervalDays Days)"
            "body"         = [PSCustomObject]@{
                "contentType" = "Text"
                "content"     = "Dear Customer, `nFind attached the Veeam ONE Job Failure Report showing $($jobFailGroups.Count) jobs with $requiredFailureCount consecutive failures. `n`n Best Regards, `n Your Veeam ONE Sentinel"
            }
            "toRecipients" = @(
                [PSCustomObject]@{
                    "emailAddress" = [PSCustomObject]@{ "address" = $RecipientEmail }
                }
            )
            "attachments"  = @(
                @{
                    "@odata.type"  = "#microsoft.graph.fileAttachment"
                    "name"         = "BackupJobHistoricalFailures.html"
                    "contentType"  = "text/html"
                    "contentBytes" = "$( [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outputPath)) )"
                }
            )
        }
        "saveToSentItems" = "true"
    }

    $request = @{
        "Headers"     = @{ Authorization = $msalToken.CreateAuthorizationHeader() }
        "Method"      = "Post"
        "Uri"         = "https://graph.microsoft.com/v1.0/users/$RecipientEmail/sendMail"
        "Body"        = $requestBody | ConvertTo-Json -Depth 5
        "ContentType" = "application/json"
    }

    Invoke-RestMethod @request
    Write-Host "✓ Email has been sent successfully." -ForegroundColor Green
} catch {
    Write-Warning "Failed to send email: $_"
}


Write-Host "`n=== Script completed ===" -ForegroundColor Green