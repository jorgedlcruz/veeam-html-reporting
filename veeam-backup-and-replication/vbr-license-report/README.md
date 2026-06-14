HTML Report for Veeam Backup & Replication License Usage  
===================

![alt tag](https://jorgedelacruz.uk/wp-content/uploads/2025/06/veeam-licensing-report-001.jpg)

This PowerShell Script uses the Veeam Backup & Replication PowerShell module to generate a **License Usage Report**, save it as an HTML file, and send it via **Microsoft Graph API**. The report is delivered both inline (in the email body) and as an `.html` attachment.

The Script is provided as-is and is part of a **community initiative**. It is not officially supported by Veeam Support, and you should not open support cases for it.

This script leverages Veeam’s built-in `Generate-VBRLicenseUsageReport` cmdlet to export license consumption details from your Backup infrastructure in a clean and readable HTML format.

----------

### Getting started
You can read the full blog post here – [https://jorgedelacruz.uk/2025/06/30/veeam-veeam-backup-replication-licensing-report/](https://jorgedelacruz.uk/2025/06/30/veeam-veeam-backup-replication-licensing-report/)

Or follow these quick steps:
* Download the `VBR_License_Report.ps1` file and edit the parameters in the Global Parameters section:
  * `$RecipientEmail` – email recipient
  * `$TenantId`, `$ClientId`, `$ClientSecret` – from your Azure App Registration
* Ensure the machine has PowerShell 5.1+ and access to Microsoft Graph API
* Run the PowerShell script:
  ```powershell
  .\VBR_License_Report.ps1
