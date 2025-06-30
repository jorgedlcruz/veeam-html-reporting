 <#
.SYNOPSIS
    Generates a workload-level report of Veeam Backup for Azure protection history, including all sessions per selected VMs.

.DESCRIPTION
    This PowerShell script connects to the Veeam Backup for Azure public and private APIs to retrieve protection session details
    for a filtered list of virtual machines. It collects key metrics such as policy name, session type, result, and duration,
    providing deep visibility into workload-level job activity over a given date range.

    The script handles authentication (including short-term refresh tokens), filters VMs by name, queries all assigned policies
    and their sessions, and generates a clean, ready-to-share HTML and CSV report.

    Useful for audit, compliance, or operations teams that need quick access to backup job history without manually querying the console.

.OUTPUTS
    HTML and CSV reports showing policy session activity for specified VMs.
    Files are named using the current date and saved to the script's execution path.

.EXAMPLE
    .\Veeam_Backup_Azure_WorkloadProtectionHistory.ps1
    Generates a report for defined VM names between the configured start and end dates.

.NOTES
    NAME: Veeam_Backup_Azure_WorkloadProtectionHistory.ps1
    VERSION: 1.0
    AUTHOR: Jorge de la Cruz
    TWITTER: @jorgedlcruz
    GITHUB: https://github.com/jorgedlcruz

.LINK
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

# PARAMETERS
$veeamAzureServer = "https://YOURVBAZURE"
$veeamUsername = "YOURUSERNAME"
$veeamPassword = 'YOURPASS'
$apiVersion = "v8"
$vmNames = @('VMNAME1','VMNAME2','VMNAME3')
$startDate = Get-Date "2025-06-01"
$endDate = Get-Date "2025-12-31"

# AUTHENTICATION - External token
Function Get-VeeamAzureToken {
    $uri = "$veeamAzureServer/api/oauth2/token"
    $body = "username=$veeamUsername&password=$veeamPassword&grant_type=Password"
    $headers = @{
        "Accept" = "application/json"
        "Content-Type" = "application/x-www-form-urlencoded"
    }
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
        return $response.access_token
    } catch {
        Write-Host "Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# AUTHENTICATION - Internal token
Function Get-NewApiToken {
    $uri = "$veeamAzureServer/api/oauth2/token"
    $body = "username=$veeamUsername&password=$veeamPassword&rememberMe=false&use_short_term_refresh=true&grant_type=password"
    $headers = @{
        "Content-Type" = "application/x-www-form-urlencoded"
        "Accept" = "application/json"
    }
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
        return $response.access_token
    } catch {
        Write-Host "Internal auth failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# GET VM list
$filteredVMs = @()
foreach ($vmName in $vmNames) {
    $uri = "$veeamAzureServer/api/$apiVersion/virtualMachines?SearchPattern=$vmName"
    $headers = @{
        "Authorization" = "Bearer $token"
        "Accept" = "application/json"
    }
    try {
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        if ($result.results.Count -gt 0) {
            $filteredVMs += $result.results
        } else {
            Write-Host "⚠️ No VM found for $vmName" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "❌ Error retrieving VM $vmName" -ForegroundColor Red
    }
}


# GET Policies by VM
Function Get-PoliciesByVMId {
    param([string]$vmId, [string]$token)
    $uri = "$veeamAzureServer/api/$apiVersion/policies/virtualMachines?VirtualMachineId=$vmId"
    $headers = @{
        "Authorization" = "Bearer $token"
        "Accept" = "application/json"
    }
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    return $response.results
}

# GET Policy Sessions
Function Get-PolicySessionsForVM {
    param([string]$policyId, [string]$vmId, [string]$token)
    $uri = "$veeamAzureServer/api/$apiVersion/reports/policySessions?PolicyId=$policyId&InstanceId=$vmId&Offset=0&Limit=5000&Sort=TimeDesc"
    $headers = @{
        "Authorization" = "Bearer $token"
        "Accept" = "application/json"
    }
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    return $response.results
}

# MAIN
$token = Get-VeeamAzureToken
$newToken = Get-NewApiToken
$policySessionObjects = @()
$vms = $filteredVMs

foreach ($vm in $vms) {
    $vmId = $vm.id
    $vmName = $vm.name
    $policies = Get-PoliciesByVMId -vmId $vmId -token $token
    foreach ($policy in $policies) {
        $policyId = $policy.id
        $policyName = $policy.name
        $sessions = Get-PolicySessionsForVM -policyId $policyId -vmId $vmId -token $newToken
        Write-Host "→ Retrieved $($sessions.Count) sessions for $($vmName) under $($policyName)"
        foreach ($session in $sessions) {
            $stop = Get-Date $session.executionStopTime
            if ($stop -ge $startDate -and $stop -le $endDate) {
                $sessionObj = [PSCustomObject]@{
                    'VM Name'       = $vmName
                    'Policy Name'   = $policyName
                    'Session Type'  = $session.localizedSessionType
                    'Result'        = $session.status
                    'Session ID'    = $session.sessionId
                    'Start Time'    = $session.executionStartTime
                    'Stop Time'     = $session.executionStopTime
                    'Duration (s)'  = [math]::Round(([timespan]::Parse($session.executionDuration)).TotalSeconds)
                }
                $policySessionObjects += $sessionObj
            }
        }
    }
}

# OUTPUT
if ($policySessionObjects.Count -gt 0) {
$htmlHeader = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Schedule-Based Policies Session Report</title>
    <style>
        body { font-family: 'Open-Sans', sans-serif; padding: 10px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { border: 1px solid #ddd; text-align: left; padding: 8px; }
        th { background-color: #f2f2f2; }
        .success { background-color: #28a745; color: white; font-weight: bold; }
        .failed { background-color: #dc3545; color: white; font-weight: bold; }
        .warning { background-color: #ffc107; color: black; font-weight: bold; }
    </style>
</head>
<body>
    <h1>Schedule-Based Policies Session Report</h1>
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

$rowsHtml = $policySessionObjects | ForEach-Object {
    $resultStyle = switch ($_.Result) {
        "Success" { 'class="success"' }
        "Failed"  { 'class="failed"' }
        "Warning" { 'class="warning"' }
        Default   { '' }
    }
    "<tr><td>$($_.'VM Name')</td><td>$($_.'Policy Name')</td><td>$($_.'Session Type')</td><td $resultStyle>$($_.Result)</td><td>$($_.'Session ID')</td><td>$($_.'Start Time')</td><td>$($_.'Stop Time')</td><td>$($_.'Duration (s)')</td></tr>"
}

# Write files
$currentDate = Get-Date -Format "yyyy-MM-dd"
$htmlPath = Join-Path $PSScriptRoot "$currentDate-PolicySessionReport.html"
$csvPath = Join-Path $PSScriptRoot "$currentDate-PolicySessionReport.csv"

($htmlHeader + ($rowsHtml -join "`n") + $htmlFooter) | Out-File -FilePath $htmlPath -Encoding UTF8
$policySessionObjects | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "`nHTML report saved to: $htmlPath" -ForegroundColor Cyan
Write-Host "CSV report saved to: $csvPath" -ForegroundColor Cyan
} else {
    Write-Host "`nNo policy session information found in the selected date range." -ForegroundColor Yellow
}