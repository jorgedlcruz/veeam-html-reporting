 <#
.SYNOPSIS
    Generates a Veeam Backup & Replication License Usage Report.

.DESCRIPTION
    This PowerShell script uses the Veeam Backup PowerShell module to generate a License Usage Report,
    saves it as HTML, and sends it via Microsoft Graph API both as inline content and as an attached file.

.OUTPUTS
    HTML License Usage report saved to disk and emailed.

.NOTES
    NAME: VBR_License_Report.ps1
    VERSION: 1.0
    AUTHOR: Jorge de la Cruz
    TWITTER: @jorgedlcruz
    GITHUB: https://github.com/jorgedlcruz
#>

# Global Parameters
$timestamp = Get-Date -Format "yyyyMMdd_HH_mm_ss"
$reportFileName = "VBR_License_Report_$timestamp"
$outputPath = "$PSScriptRoot\$reportFileName"
$RecipientEmail = "YOUR@EMAIL.COM"

$TenantId = "YOURMS365TENANT.onmicrosoft.com"
$ClientId = "YOURCLIENTID"
$ClientSecret = ConvertTo-SecureString "YOURAPPSECRET" -AsPlainText -Force

# Generate License Usage Report
Write-Host "Generating VBR License Usage Report..." -ForegroundColor Cyan
Get-Module -Name Veeam.Backup.PowerShell
Generate-VBRLicenseUsageReport -Path $outputPath -Type Html
Write-Host "Report saved to: $outputPath" -ForegroundColor Green

# Read HTML content
$finalReportPath = "$outputPath.html"
$htmlBody = [System.IO.File]::ReadAllText($finalReportPath)


# Send Report via Microsoft Graph API
Import-Module MSAL.PS

$appRegistration = @{
    TenantId     = $TenantId
    ClientId     = $ClientId
    ClientSecret = $ClientSecret
}

$msalToken = Get-MsalToken @appRegistration -ForceRefresh

$requestBody = @{
    "message" = @{
        "subject" = "[Report] Veeam VBR License Usage Report"
        "body" = @{
            "contentType" = "HTML"
            "content"     = $htmlBody
        }
        "toRecipients" = @(
            @{
                "emailAddress" = @{ "address" = $RecipientEmail }
            }
        )
        "attachments" = @(
            @{
                "@odata.type"  = "#microsoft.graph.fileAttachment"
                "name"         = "$reportFileName.html"
                "contentType"  = "text/html"
                "contentBytes" = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($finalReportPath))
            }
        )

    }
    "saveToSentItems" = $true
}

$bodyJson = $requestBody | ConvertTo-Json -Depth 10 -Compress
Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$RecipientEmail/sendMail" `
    -Headers @{ Authorization = $msalToken.CreateAuthorizationHeader() } `
    -Method POST `
    -ContentType "application/json" `
    -Body $bodyJson



Write-Host "✅ Email sent to $RecipientEmail with the License Report." -ForegroundColor Green