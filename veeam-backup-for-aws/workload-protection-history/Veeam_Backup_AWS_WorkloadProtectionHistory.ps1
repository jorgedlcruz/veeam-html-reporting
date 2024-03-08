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
    VERSION: 1.1
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
$apiVersion = "1.4-rev0" # Make sure you use the API version according to your appliance https://helpcenter.veeam.com/docs/vbaws/rest/versioning.html?ver=70
$apiUrl = "$veeamBackupAWSServer`:$veeamBackupAWSPort/api/v1"
$vmNames = @('MYVMANEM1','MYVMNAME2')
$startDate = '2024-01-01T00:00:01'
$endDate = '2024-02-21T23:59:59'

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
        [string]$vmId
    )
    Write-Host "Retrieving policies for VM ID: $vmId..."
    $headers = @{
        'Authorization' = "Bearer $token"
        'x-api-version' = $apiVersion
    }
    $policies = @()  # Initialize an empty array to store policy objects
    try {
        $response = Invoke-RestMethod -Uri "$apiUrl/virtualMachines/policies?VirtualMachineId=$vmId" -Headers $headers
        if ($response.totalCount -gt 0) {
            foreach ($policy in $response.results) {
                $policyObj = [PSCustomObject]@{
                    'ID' = $policy.id
                    'Name' = $policy.name
                }
                $policies += $policyObj
            }
        } else {
            Write-Host "No policies found for VM ID: $vmId"
        }
    } catch {
        Write-Host "Error retrieving policies for VM ID: $vmId - $($_.Exception.Message)"
    }
    return $policies
}


# Function to get policies sessions by Policy Id and VM ID
Function Get-PolicyInstanceSessions {
    Param (
        [string]$policyId,
        [string]$vmId
    )
    Write-Host "Retrieving policy instance sessions for Policy ID: $policyId and VM ID: $vmId..."

    $headers = @{
        "Authorization" = "Bearer $newToken"
        "Content-Type" = "application/json"
    }
    
    $body = @{
        "skip" = 0
        "count" = 200
        "orderAsc" = $false
        "orderColumn" = 'startTimeUtc'
        "policyId" = $policyId
        "instanceId" = $vmId
        "filters" = @{
            "timePeriod" = ''
            "statuses" = @()
            "sessionTypes" = @()
        }
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$veeamBackupAWSServer/api/v1/reports/policyInstanceSessions" -Method "POST" -Headers $headers -ContentType "application/json" -Body $body
        $filteredSessions = @()
        foreach ($session in $response.data) {
            $sessionStopTimeStr = $session.stopTime -split '\.' | Select-Object -First 1
            $sessionStopTime = [datetime]::ParseExact($sessionStopTimeStr, 'yyyy-MM-ddTHH:mm:ss', $null)
            if ($sessionStopTime -ge $startDate -and $sessionStopTime -le $endDate) {
                $filteredSessions += $session
            }
        }
        Write-Host "Filtered policy instance sessions retrieved successfully."
        return $filteredSessions
    } catch {
        Write-Host "Error retrieving policy instance sessions: $($_.Exception.Message)"
        return @()
    }
}


# Initialize an empty array for all unique policy session objects
$policySessionObjects = @()

# Main script execution part
foreach ($vmName in $vmNames) {
    Write-Host "Processing VM: $vmName"
    $vmIds = Get-VMIds -vmName $vmName
    foreach ($vmId in $vmIds) {
        Write-Host "Retrieving policies for VM ID: $vmId..."
        $policies = Get-PoliciesByVMId -vmId $vmId
        foreach ($policy in $policies) {
            $policyId = $policy.ID
            $policyName = $policy.Name
            Write-Host "Retrieving sessions for Policy: '$policyName' (ID: $policyId) and VM ID: $vmId..."
            $sessions = Get-PolicyInstanceSessions -policyId $policyId -vmId $vmId
            foreach ($session in $sessions) {
                $sessionObj = [PSCustomObject]@{
                    'VM Name'       = $vmName
                    'Policy ID'     = $policyId
                    'Policy Name'   = $policyName
                    'Session Type'  = $session.sessionType
                    'Result'        = $session.result
                    'Session ID'    = $session.sessionId
                    'Start Time'    = $session.startTime
                    'Stop Time'     = $session.stopTime
                    'Duration (s)'  = $session.duration
                }
                $policySessionObjects += $sessionObj
            }
        }
    }
}


if ($policySessionObjects.Count -gt 0) {

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

# Construct the HTML for each row based on the policy session objects
$rowsHtml = $policySessionObjects | ForEach-Object {
    $rowData = $_
    $resultStyle = switch ($rowData.'Result') {
        'Success' { 'class="success"' }
        'Failed'  { 'class="failed"' }
        'Warning' { 'class="warning"' }
        Default   { '' } # Default, no additional class
    }
    $rowHtml = "<tr>"
    $rowHtml += "<td>$($rowData.'VM Name')</td>"
    $rowHtml += "<td>$($rowData.'Policy Name')</td>"
    $rowHtml += "<td>$($rowData.'Session Type')</td>"
    $rowHtml += "<td $resultStyle>$($rowData.'Result')</td>" # Apply conditional formatting here
    $rowHtml += "<td>$($rowData.'Session ID')</td>"
    $rowHtml += "<td>$($rowData.'Start Time')</td>"
    $rowHtml += "<td>$($rowData.'Stop Time')</td>"
    $rowHtml += "<td>$($rowData.'Duration (s)')</td>"
    $rowHtml += "</tr>"
    $rowHtml
}



# Building the Output
$currentDate = Get-Date -Format "yyyy-MM-dd"

# Define file names with the current date
$htmlFileName = "$currentDate-PolicySessionReport.html"
$csvFileName = "$currentDate-PolicySessionReport.csv"

# Define file paths relative to the current script's directory
$htmlFilePath = Join-Path -Path $PSScriptRoot -ChildPath $htmlFileName
$csvFilePath = Join-Path -Path $PSScriptRoot -ChildPath $csvFileName

# Combine all parts of the HTML
$htmlContent = $htmlHeader + $rowsHtml + $htmlFooter

# Output to HTML file
$htmlContent | Out-File -FilePath $htmlFilePath
Write-Host "HTML report saved to $htmlFilePath"

# Export to CSV file
$policySessionObjects | Export-Csv -Path $csvFilePath -NoTypeInformation
Write-Host "CSV report saved to $csvFilePath"

} else {
    Write-Host "No policy session information was found for any VMs."
}

