<#
.SYNOPSIS
    Generates a report on Veeam Backup for AWS Workload Protection history, including restore points for specified VMs.

.DESCRIPTION
    This PowerShell script automates the process of fetching restore points for specific virtual machines 
    from Veeam's Cloud Workload Protection. It streamlines tasks that would typically take much time 
    due to manual data retrieval and formatting. The script handles authentication, data fetching, and 
    output formatting, ensuring security with proper authentication and MFA support. It simplifies the 
    user's tasks by eliminating the need for extensive copy-pasting and manual data manipulation,
    providing ready results in seconds.

.OUTPUTS
    HTML and CSV files containing the restore points history. Files are named based on the execution 
    date and are saved in the script's running directory.

.EXAMPLE
    .\Veeam_Backup_AWS_WorkloadProtectionHistory.ps1
    Executes the script and generates the Veeam Backup for AWS Workload Protection history report in both HTML and CSV formats.

.NOTES
    NAME: Veeam_Backup_AWS_WorkloadProtectionHistory.ps1
    VERSION: 9.0
    AUTHOR: Jorge de la Cruz
    TWITTER: @jorgedlcruz
    GITHUB: https://github.com/jorgedlcruz

.LINK
    Script documentation and additional details available at:
    https://jorgedelacruz.uk/
#>


# Ignore SSL certificate validation errors (Not recommended for production)
Add-Type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# Variables for API connection
$veeamUsername = "YOURUSER"
$veeamPassword = "YOURPASS"
$veeamBackupAWSServer = "https://YOURVBIP"
$veeamBackupAWSPort = "11005"
$apiVersion = "1.7-rev0" # keep aligned with appliance. More information here https://helpcenter.veeam.com/references/vbaws/9/rest/1.7-rev0/tag/SectionOverview#section/Versioning
$apiUrl = "$veeamBackupAWSServer`:$veeamBackupAWSPort/api/v1"

# Scope & time window
$vmNames = @('VM-NAME-1','VM-NAME-2')
$vmOrderMap = @{}
for ($i = 0; $i -lt $vmNames.Count; $i++) { $vmOrderMap[$vmNames[$i]] = $i }
$startDate   = '2025-07-31T00:00:01'
$endDate     = '2025-09-01T23:59:59'
$periodStart = (Get-Date $startDate).ToString('yyyy-MM-dd')
$periodEnd   = (Get-Date $endDate).ToString('yyyy-MM-dd')

# Function to get API token - Public API
Function Get-ApiToken {
    Write-Host "Requesting API token..."
    $body = @{
        username = $veeamUsername
        password = $veeamPassword
        grant_type = 'password'
    }
    $headers = @{
        "Content-Type" = "application/x-www-form-urlencoded"
        "Accept" = "application/json"
        "x-api-version" = $apiVersion
    }
    $uri = "$apiUrl/token"
    
    # Using Invoke-RestMethod for API call
    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -Headers $headers -ContentType 'application/x-www-form-urlencoded'
    Write-Host "API token received."
    return $response.access_token
}
$token = Get-ApiToken

# Function to get API token - Private API
Function Get-NewApiToken {
    Write-Host "Requesting new API token..."

    # Define the request URI and body
    $uri = "$veeamBackupAWSServer/api/oauth2/token"
    $body = "username=$veeamUsername&password=$veeamPassword&rememberMe=false&use_short_term_refresh=true&grant_type=password"

    # Define headers for the request
    $headers = @{
        "Content-Type" = "application/x-www-form-urlencoded"
        "Accept" = "application/json"
    }

    # Make the request and extract the token
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
        Write-Host "New API token received."
        return $response.access_token
    } catch {
        Write-Host "Error obtaining new API token: $($_.Exception.Message)"
    }
}
$newToken = Get-NewApiToken

# Function to get VM IDs by name
Function Get-VMIds {
    Param (
        [string]$vmName
    )
    Write-Host "Retrieving VM IDs for $vmName..."
    $headers = @{
        'Authorization' = "Bearer $token"
        'x-api-version' = $apiVersion
    }
    $response = Invoke-RestMethod -Uri "$apiUrl/virtualMachines?SearchPattern=$vmName" -Headers $headers
    $vmIds = $response.results.id
    Write-Host "VM IDs for $vmName retrieved: $($vmIds -join ', ')"
    return $vmIds
}

# Function to get policies by VM ID
Function Get-PoliciesByVMId {
    Param (
        [string]$vmId,
        [string]$vmName = $null  # optional, for logging only
    )
    Write-Host "Retrieving policies for VM ID: $vmId..."
    $headers = @{
        'Authorization' = "Bearer $token"
        'x-api-version' = $apiVersion
        'Accept'        = 'application/json'
    }
    $policies = @()
    try {
        $response = Invoke-RestMethod -Uri "$apiUrl/virtualMachines/policies?VirtualMachineId=$vmId" -Headers $headers -ErrorAction Stop
        $tc = [int]($response.totalCount)
        if ($tc -gt 0) {
            foreach ($policy in $response.results) {
                $policies += [PSCustomObject]@{
                    'ID'   = $policy.id
                    'Name' = $policy.name
                }
            }
        } else {
            if ([string]::IsNullOrWhiteSpace($vmName)) {
                Write-Host "VM (ID: $vmId) returns 0 classic policies → likely SLA."
            } else {
                Write-Host "VM '$vmName' (ID: $vmId) returns 0 classic policies → likely SLA."
            }
        }
    } catch {
        Write-Host "Error retrieving policies for VM ID: $vmId - $($_.Exception.Message)"
    }
    return $policies
}

# Function to get classic policies by VM ID
Function Find-ClassicPolicyIdByNameAndVm {
    Param(
        [Parameter(Mandatory)] [string]$PolicyName,
        [Parameter(Mandatory)] [string]$VmId
    )
    $headers = @{
        'Authorization' = "Bearer $token"
        'x-api-version' = $apiVersion
        'Accept'        = 'application/json'
    }
    $q = [System.Uri]::EscapeDataString($PolicyName)
    try {
        $resp = Invoke-RestMethod -Uri "$apiUrl/virtualMachines/policies?SearchPattern=$q" -Headers $headers -ErrorAction Stop
        foreach ($p in $resp.results) {
            if ($p.selectedItems -and $p.selectedItems.virtualMachineIds -and ($p.selectedItems.virtualMachineIds -contains $VmId)) {
                return [PSCustomObject]@{ Id = $p.id; Name = $p.name }
            }
        }
    } catch {
        Write-Host "Classic fallback lookup failed for '$PolicyName' -> $($_.Exception.Message)"
    }
    return $null
}

# Cache to avoid repeated calls
$global:SlaInstancesCache = $null
$global:SlaPoliciesCache  = @{
    'Daily'   = $null
    'Weekly'  = $null
    'Monthly' = $null
}

# Function to get all VMs
Function Get-InstancesReport {
    $headers = @{
        "Authorization" = "Bearer $newToken"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
        "x-api-version" = "1.0-rev10"
    }
    $body = @{ skip = 0; count = 500; orderAsc = $true; orderColumn = "instanceName"; typeFilter = @() } | ConvertTo-Json
    Invoke-RestMethod -Uri "$veeamBackupAWSServer/api/v1/reports/instances" -Method POST -Headers $headers -Body $body
}

# Function to get all SLA Policies
Function Get-ProtectionPolicies {
    Param([ValidateSet('Daily','Weekly','Monthly')] [string]$ScheduleType)
    if ($global:SlaPoliciesCache[$ScheduleType]) { return $global:SlaPoliciesCache[$ScheduleType] }

    $headers = @{
        "Authorization" = "Bearer $newToken"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
        "x-api-version" = "1.0-rev10"
    }
    $body = @{
        skip = 0; count = 500; orderAsc = $true; orderColumn = 'Priority'
        filters = @{}
        slaReportingSettings = @{ scheduleType = $ScheduleType }
    } | ConvertTo-Json -Depth 6

    $resp = Invoke-RestMethod -Uri "$veeamBackupAWSServer/api/v1/reports/protectionPolicies" -Method POST -Headers $headers -Body $body
    $global:SlaPoliciesCache[$ScheduleType] = $resp.data
    return $global:SlaPoliciesCache[$ScheduleType]
}

# Function to get SLA Policy Destination
Function Get-SlaBackupTypesFromDestination {
    Param([string]$PolicyDestination)
    $types = @()
    if ($PolicyDestination -match 'Snapshot') { $types += 'Ec2Snapshot' }
    if ($PolicyDestination -match 'Regular')  { $types += 'Ec2Backup'   }
    if ($types.Count -eq 0) { $types = @('Ec2Snapshot') }
    $types | Select-Object -Unique
}

# Function to get SLA Policy per VM ID
Function Resolve-SlaPolicyForInstanceId {
    Param([string]$VmId, [string]$VmName = $null)

    if (-not $global:SlaInstancesCache) {
        try   { $global:SlaInstancesCache = Get-InstancesReport }
        catch { Write-Host "SLA: failed to fetch /reports/instances -> $($_.Exception.Message)"; return $null }
    }

    $row = $global:SlaInstancesCache.data | Where-Object { $_.instanceId -eq $VmId } | Select-Object -First 1
    if (-not $row) {
        Write-Host "SLA: could not locate instanceId $VmId in /reports/instances."
        return $null
    }

    $policyId   = $row.policyId
    $policyName = $row.policyName
    $dest       = $row.policyDestination

    if ($policyId) {
        return [PSCustomObject]@{ Id = $policyId; Name = $policyName; Destination = $dest; Source = 'SLA' }
    }

    if ($policyName) {
        # Try map by name across schedules
        foreach ($sch in @('Daily','Weekly','Monthly')) {
            $pols = Get-ProtectionPolicies -ScheduleType $sch
            $hit  = $pols | Where-Object { $_.name -eq $policyName } | Select-Object -First 1
            if ($hit) {
                return [PSCustomObject]@{ Id = $hit.id; Name = $hit.name; Destination = $dest; Source = 'SLA' }
            }
        }
        # Could be a classic policy that the instances report still shows by name
        Write-Host "SLA: could not resolve SLA policyId for policyName '$policyName' (instance $VmId). Will attempt classic fallback by name."
        return [PSCustomObject]@{ Id = $null; Name = $policyName; Destination = $dest; Source = 'Unknown' }
    }

    Write-Host "SLA: instance has no policyName in /reports/instances."
    return $null
}

# Function to get SLA sessions per VM ID
Function Get-SlaPolicyInstanceSessions {
    Param(
        [string]$PolicyId,
        [string]$ResourceId,    # instanceId
        [ValidateSet('Ec2Snapshot','Ec2Backup')] [string]$BackupType = 'Ec2Snapshot',
        [ValidateSet('Daily','Weekly','Monthly')] [string]$ScheduleType = 'Daily',
        [string]$PeriodStart,   # yyyy-MM-dd
        [string]$PeriodEnd      # yyyy-MM-dd
    )

    $headers = @{
        "Authorization" = "Bearer $newToken"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
        "x-api-version" = "1.0-rev10"
    }

    $body = @{
        policyId     = $PolicyId
        resourceId   = $ResourceId
        periodStart  = $PeriodStart
        periodEnd    = $PeriodEnd
        backupType   = $BackupType
        scheduleType = $ScheduleType
        skip         = 0
        count        = 200
        orderAsc     = $false
        orderColumn  = 'startTime'
    } | ConvertTo-Json -Depth 6

    Invoke-RestMethod -Uri "$veeamBackupAWSServer/api/v1/reports/protectionPolicyInstanceSessions" -Method POST -Headers $headers -Body $body
}

# Function to get classic policy sessions by Policy ID and VM ID 
Function Get-PolicyInstanceSessions {
    Param (
        [string]$policyId,
        [string]$vmId
    )

    Write-Host "Retrieving policy instance sessions for Policy ID: $policyId and VM ID: $vmId..."

    $headers = @{
        "Authorization" = "Bearer $newToken"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
        "x-api-version" = "1.0-rev10"
    }

    function Invoke-ClassicReport {
        param([string]$OrderColumnOrEmpty)

        $bodyObj = @{
            skip       = 0
            count      = 200
            orderAsc   = $false
            policyId   = $policyId
            instanceId = $vmId
            filters    = @{
                timePeriod   = ''
                statuses     = @()
                sessionTypes = @()
            }
        }

        if ($OrderColumnOrEmpty) {
            $bodyObj.orderColumn = $OrderColumnOrEmpty
        }

        $bodyJson = $bodyObj | ConvertTo-Json -Depth 6

        return Invoke-RestMethod `
            -Uri "$veeamBackupAWSServer/api/v1/reports/policyInstanceSessions" `
            -Method POST `
            -Headers $headers `
            -Body $bodyJson `
            -ContentType "application/json"
    }

    try {
        $response = Invoke-ClassicReport -OrderColumnOrEmpty 'StartTime'
    } catch {
        $status = $null; $detail = $null
        if ($_.Exception.Response) {
            $status = $_.Exception.Response.StatusCode.value__
            try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $detail = $sr.ReadToEnd() } catch {}
        }
        if ($status -eq 400) {
            Write-Host "Server rejected orderColumn=StartTime (400). Retrying with StartTimeUtc..."
            try {
                $response = Invoke-ClassicReport -OrderColumnOrEmpty 'StartTimeUtc'
            } catch {
                $status2 = $null; $detail2 = $null
                if ($_.Exception.Response) {
                    $status2 = $_.Exception.Response.StatusCode.value__
                    try { $sr2 = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $detail2 = $sr2.ReadToEnd() } catch {}
                }
                if ($status2 -eq 400) {
                    Write-Host "Server rejected orderColumn=StartTimeUtc (400). Retrying with NO orderColumn..."
                    try {
                        $response = Invoke-ClassicReport -OrderColumnOrEmpty $null
                    } catch {
                        $status3 = $null; $detail3 = $null
                        if ($_.Exception.Response) {
                            $status3 = $_.Exception.Response.StatusCode.value__
                            try { $sr3 = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $detail3 = $sr3.ReadToEnd() } catch {}
                        }
                        Write-Host "Error retrieving policy instance sessions (HTTP $status3): $detail3"
                        return @()
                    }
                } else {
                    Write-Host "Error retrieving policy instance sessions (HTTP $status2): $detail2"
                    return @()
                }
            }
        } else {
            Write-Host "Error retrieving policy instance sessions (HTTP $status): $detail"
            return @()
        }
    }

    $filteredSessions = @()
    foreach ($session in $response.data) {
        $sessionStopTimeStr = $session.stopTime -split '\.' | Select-Object -First 1
        $sessionStopTime    = [datetime]::ParseExact($sessionStopTimeStr, 'yyyy-MM-ddTHH:mm:ss', $null)
        if ($sessionStopTime -ge $startDate -and $sessionStopTime -le $endDate) {
            $filteredSessions += $session
        }
    }

    Write-Host "Filtered policy instance sessions retrieved successfully."
    return $filteredSessions
}

$classicObjs = @()
$slaObjs     = @()

foreach ($vmName in $vmNames) {
    Write-Host "Processing VM: $vmName"
    $vmIds = Get-VMIds -vmName $vmName
    foreach ($vmId in $vmIds) {

        $policies = Get-PoliciesByVMId -vmId $vmId -vmName $vmName
        if ($policies -and $policies.Count -gt 0) {
            foreach ($policy in $policies) {
                $policyId   = $policy.ID
                $policyName = $policy.Name
                Write-Host "Classic: sessions for '$policyName' ($policyId) VM $vmId"
                $sessions = Get-PolicyInstanceSessions -policyId $policyId -vmId $vmId
                foreach ($session in $sessions) {
                    $classicObjs += [PSCustomObject]@{
                        'VM Order'     = $vmOrderMap[$vmName]
                        'Start Sort'   = ([datetime]$session.startTime)
                        'VM Name'      = $vmName
                        'Policy ID'    = $policyId
                        'Policy Name'  = $policyName
                        'Session Type' = $session.sessionType
                        'Result'       = $session.result
                        'Session ID'   = $session.sessionId
                        'Start Time'   = $session.startTime
                        'Stop Time'    = $session.stopTime
                        'Duration (s)' = $session.duration
                        'Source'       = 'Classic'
                    }
                }
            }
            continue
        }

        $slaPolicy = Resolve-SlaPolicyForInstanceId -VmId $vmId -VmName $vmName
        if (-not $slaPolicy) { continue }

        if ($slaPolicy.Id) {
            $backupTypes = Get-SlaBackupTypesFromDestination -PolicyDestination $slaPolicy.Destination
            if (-not $backupTypes -or $backupTypes.Count -eq 0) { $backupTypes = @('Ec2Snapshot') }
            foreach ($bt in $backupTypes) {
                Write-Host "SLA: sessions for '$($slaPolicy.Name)' ($($slaPolicy.Id)) VM $vmId type=$bt $periodStart..$periodEnd"
                try {
                    $slaResp = Get-SlaPolicyInstanceSessions -PolicyId $slaPolicy.Id -ResourceId $vmId -BackupType $bt -ScheduleType 'Daily' -PeriodStart $periodStart -PeriodEnd $periodEnd
                    foreach ($s in $slaResp.sessions) {
                        $slaObjs += [PSCustomObject]@{
                            'VM Order'     = $vmOrderMap[$vmName]
                            'Start Sort'   = ([datetime]$s.startTimeLocal.time)
                            'VM Name'      = $vmName
                            'Policy ID'    = $slaPolicy.Id
                            'Policy Name'  = $slaPolicy.Name
                            'Session Type' = $s.sessionType
                            'Result'       = $s.result
                            'Session ID'   = $s.sessionId
                            'Start Time'   = $s.startTimeLocal.time
                            'Stop Time'    = $null
                            'Duration (s)' = $null
                            'Source'       = 'SLA'
                        }
                    }
                } catch {
                    Write-Host ("SLA error for policyId {0}, vmId {1}: {2}" -f $slaPolicy.Id, $vmId, $_.Exception.Message)
                }
            }
        } elseif ($slaPolicy.Name) {
            $classic = Find-ClassicPolicyIdByNameAndVm -PolicyName $slaPolicy.Name -VmId $vmId
            if ($classic -and $classic.Id) {
                Write-Host "Classic fallback: '$($classic.Name)' ($($classic.Id)) contains VM $vmId"
                $sessions = Get-PolicyInstanceSessions -policyId $classic.Id -vmId $vmId
                foreach ($session in $sessions) {
                    $classicObjs += [PSCustomObject]@{
                        'VM Order'     = $vmOrderMap[$vmName]
                        'Start Sort'   = ([datetime]$session.startTime)
                        'VM Name'      = $vmName
                        'Policy ID'    = $classic.Id
                        'Policy Name'  = $classic.Name
                        'Session Type' = $session.sessionType
                        'Result'       = $session.result
                        'Session ID'   = $session.sessionId
                        'Start Time'   = $session.startTime
                        'Stop Time'    = $session.stopTime
                        'Duration (s)' = $session.duration
                        'Source'       = 'Classic'
                    }
                }
            } else {
                Write-Host "Classic fallback: couldn’t find classic policy by name '$($slaPolicy.Name)' that contains VM $vmId."
            }
        }
    }
}

$policySessionObjects = $classicObjs + $slaObjs
$ordered = $policySessionObjects | Sort-Object `
    'VM Order', @{ Expression = { $_.'Start Sort' }; Descending = $true }

if ($ordered.Count -gt 0) {

    $rowsHtml = $ordered | ForEach-Object {
        $rowData = $_
        $resultStyle = switch ($rowData.'Result') {
            'Success' { 'class="success"' }
            'Failed'  { 'class="failed"' }
            'Warning' { 'class="warning"' }
            Default   { '' }
        }
        "<tr>" +
        "<td>$($rowData.'VM Name')</td>" +
        "<td>$($rowData.'Policy Name')</td>" +
        "<td>$($rowData.'Session Type')</td>" +
        "<td $resultStyle>$($rowData.'Result')</td>" +
        "<td>$($rowData.'Session ID')</td>" +
        "<td>$($rowData.'Start Time')</td>" +
        "<td>$($rowData.'Stop Time')</td>" +
        "<td>$($rowData.'Duration (s)')</td>" +
        "</tr>"
    }

    # ---- File paths ----
    $currentDate = Get-Date -Format "yyyy-MM-dd"
    $htmlFileName = "$currentDate-PolicySessionReport.html"
    $csvFileName  = "$currentDate-PolicySessionReport.csv"

    # Fallback for ISE/console where $PSScriptRoot may be empty
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $outDir = (Get-Location).Path
    } else {
        $outDir = $PSScriptRoot
    }

    $htmlFilePath = Join-Path -Path $outDir -ChildPath $htmlFileName
    $csvFilePath  = Join-Path -Path $outDir -ChildPath $csvFileName

    # ---- HTML ----
    $htmlHeader = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Policy Session Report</title>
    <style>
        body { font-family: 'Open-Sans', sans-serif; padding: 10px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; }
        th { background-color: #f2f2f2; }
        .success { background-color: #28a745; color: white; font-weight: bold; }
        .failed { background-color: #dc3545; color: white; font-weight: bold; }
        .warning { background-color: #ffc107; color: black; font-weight: bold; }
    </style>
</head>
<body>
    <h1>Policy Session Report</h1>
    <table>
        <tr>
            <th>VM Name</th>
            <th>Policy Name</th>
            <th>Session Type</th>
            <th>Result</th>
            <th>Session ID</th>
            <th>Start Time</th>
            <th>Stop Time</th>
            <th>Duration (s)</th>
        </tr>
"@

    $htmlFooter = @"
    </table>
</body>
</html>
"@

    $htmlContent = $htmlHeader + ($rowsHtml -join [Environment]::NewLine) + $htmlFooter
    $htmlContent | Out-File -FilePath $htmlFilePath -Encoding UTF8
    Write-Host "HTML report saved to $htmlFilePath"

    $ordered |
      Select-Object 'VM Name','Policy Name','Session Type','Result','Session ID','Start Time','Stop Time','Duration (s)' |
      Export-Csv -Path $csvFilePath -NoTypeInformation
    Write-Host "CSV report saved to $csvFilePath"

} else {
    Write-Host "No policy session information was found for any VMs."
}
