 <#
.SYNOPSIS
    Generates a detailed HTML report of Veeam Backup for Azure job sessions and delivers it via Microsoft Graph email.

.DESCRIPTION
    This PowerShell script connects to the Veeam Backup for Azure API to collect session history, filtered by date range and session types.
    It gathers key information such as policy name, session type, status, number of protected instances, and job timing details.
    The output is a formatted HTML report summarizing all relevant sessions, suitable for operational and compliance reporting.

    The report is automatically emailed using Microsoft Graph API via App-Only authentication with the provided Azure AD App Registration.

.PARAMETER ReportDateFrom
    Start of the reporting window, in UTC format.

.PARAMETER ReportDateTo
    End of the reporting window, in UTC format.

.PARAMETER SessionTypes
    Comma-separated list of session types to include (e.g., "PolicyBackup,PolicySnapshot,PolicyArchive").

.PARAMETER DateTimeFormat
    Date and time formatting string to control how timestamps are displayed in the report.

.OUTPUTS
    HTML report saved locally and emailed as an attachment.

.EXAMPLE
    .\Veeam_Backup_Azure_JobHistory.ps1
    Generates a filtered session report for the last X days and sends it via email.

.NOTES
    NAME: Veeam_Backup_Azure_JobHistory.ps1
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
$VeeamServer = "https://YOURVEEAMSERVER"
$VeeamUsername = "YOURVBAZUREUSER"
$VeeamPassword = 'YOURVBAZUREPASS'
$ApiVersion = "v8"
$RecipientEmail = "YOUR@EMAIL.COM"
$TenantId = "YOUR365ORG.onmicrosoft.com"
$ClientId = "YOURCLIENTID"
$ClientSecret = ConvertTo-SecureString "YOURSECRET" -AsPlainText -Force
$ReportDateFrom = (Get-Date).AddDays(-100).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$ReportDateTo = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$DateTimeFormat = "dd/MM/yyyy HH:mm" # Date/Time Format (e.g., "dd/MM/yyyy HH:mm" or "MM/dd/yyyy hh:mm tt")
$SessionTypes = "PolicyBackup,PolicySnapshot,PolicyArchive" # Session types (comma-separated, e.g., "PolicyBackup,PolicySnapshot,PolicyArchive")


# FUNCTIONS
function Get-VeeamAzureToken {
    $uri = "$VeeamServer/api/oauth2/token"
    $body = "username=$VeeamUsername&password=$VeeamPassword&rememberMe=false&use_short_term_refresh=true&grant_type=password"
    $headers = @{
        "Accept" = "application/json"
        "Content-Type" = "application/x-www-form-urlencoded"
    }
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
        Write-Host "[DEBUG] Token acquired successfully." -ForegroundColor Green
        return $response.access_token
    } catch {
        Write-Host "[ERROR] Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
        throw "Unable to acquire Veeam Azure API token."
    }
}

function Get-VeeamAzureServerInfo {
    param([string]$Token)
    $uri = "$VeeamServer/api/$ApiVersion/system/serverInfo"
    $headers = @{"Authorization"="Bearer $Token"; "Accept"="application/json"}
    return Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
}

function Get-VeeamAzureSessions {
    param([string]$Token, [string]$FromDate, [string]$ToDate, [string]$Types)

    $typeParams = $Types -split ',' | ForEach-Object { "&Types=$_" } | Out-String
    $typeParams = $typeParams -replace "\s+", ""
    $uri = "$VeeamServer/api/$ApiVersion/jobSessions?FromUtc=$FromDate&ToUtc=$ToDate$typeParams"

    Write-Host "[DEBUG] Requesting Sessions URL: $uri" -ForegroundColor Cyan

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Accept"        = "application/json"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        Write-Host "[DEBUG] Session API Response Count: $($response.results.Count)" -ForegroundColor Green
        return $response.results
    } catch {
        Write-Warning "[ERROR] Failed to get sessions: $($_.Exception.Message)"
        throw "Aborting: Could not retrieve session data."
    }
}

function Build-HTMLReport {
    param([array]$Sessions, [object]$ServerInfo)

    $html = @"
    <html><head><style>
    body { font-family: Arial; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ccc; padding: 6px; }
    th { background-color: #f2f2f2; }
    .Success { background-color: #28a745; color: white; }
    .Warning { background-color: #ffc107; }
    .Failed { background-color: #dc3545; color: white; }
    </style></head><body>
    <h2>Veeam Backup for Azure Report</h2>
    <p>Hostname: $($ServerInfo.serverName) | Region: $($ServerInfo.azureRegion)</p>
    <table>
    <tr><th>Policy Name</th><th>Session Type</th><th>Status</th><th>Protected Instances</th><th>Start Time</th><th>Stop Time</th><th>Duration</th></tr>
"@

    foreach ($session in $Sessions) {
        $statusClass = $session.status
        $startTime = (Get-Date $session.executionStartTime).ToLocalTime().ToString($DateTimeFormat)
        $stopTime = (Get-Date $session.executionStopTime).ToLocalTime().ToString($DateTimeFormat)
        $duration = [TimeSpan]::Parse($session.executionDuration).ToString("hh\:mm\:ss")

        $html += "<tr>"
        $html += "<td>$($session.backupJobInfo.policyName)</td>"
        $html += "<td>$($session.localizedType)</td>"
        $html += "<td class='$statusClass'>$($session.status)</td>"
        $html += "<td>$($session.backupJobInfo.protectedInstancesCount)</td>"
        $html += "<td>$startTime</td>"
        $html += "<td>$stopTime</td>"
        $html += "<td>$duration</td>"
        $html += "</tr>"
    }

    $html += "</table></body></html>"
    return $html
}

function Send-EmailViaGraph {
    param(
        [string]$HtmlReport,
        [string]$AttachmentName,
        [string]$RecipientEmail,
        [string]$TenantId,
        [string]$ClientId,
        [securestring]$ClientSecret
    )

    Import-Module MSAL.PS
    $msalToken = Get-MsalToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    $requestBody = @{
        "message" = [PSCustomObject]@{
            "subject"      = "[Report] Veeam Backup for Azure Daily Report"
            "body"         = [PSCustomObject]@{
                "contentType" = "HTML"
                "content"     = "Please find attached the daily Veeam Backup for Azure report."
            }
            "toRecipients" = @(
                [PSCustomObject]@{
                    "emailAddress" = [PSCustomObject]@{ "address" = $RecipientEmail }
                }
            )
            "attachments"  = @(
                @{
                    "@odata.type"  = "#microsoft.graph.fileAttachment"
                    "name"         = $AttachmentName
                    "contentType"  = "text/html"
                    "contentBytes" = "$( [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($HtmlReport)) )"
                }
            )
        }
        "saveToSentItems" = $true
    }

    $request = @{
        "Headers"     = @{ Authorization = $msalToken.CreateAuthorizationHeader() }
        "Method"      = "Post"
        "Uri"         = "https://graph.microsoft.com/v1.0/users/$RecipientEmail/sendMail"
        "Body"        = $requestBody | ConvertTo-Json -Depth 5
        "ContentType" = "application/json"
    }

    Invoke-RestMethod @request
}

# REGION: MAIN
$Token = Get-VeeamAzureToken
$ServerInfo = Get-VeeamAzureServerInfo -Token $Token
$Sessions = Get-VeeamAzureSessions -Token $Token -FromDate $ReportDateFrom -ToDate $ReportDateTo -Types $SessionTypes

if ($Sessions.Count -eq 0) {
    Write-Host "No sessions found for reporting period." -ForegroundColor Yellow
    exit
}

$HtmlReport = Build-HTMLReport -Sessions $Sessions -ServerInfo $ServerInfo
$ReportFile = "$PSScriptRoot\VBA-Daily-Report.html"
$HtmlReport | Out-File -FilePath $ReportFile -Encoding UTF8

Send-EmailViaGraph -HtmlReport $HtmlReport `
                   -AttachmentName "VBA-Daily-Report.html" `
                   -RecipientEmail $RecipientEmail `
                   -TenantId $TenantId `
                   -ClientId $ClientId `
                   -ClientSecret $ClientSecret

Write-Host "[INFO] Report emailed and saved to $ReportFile" -ForegroundColor Green
