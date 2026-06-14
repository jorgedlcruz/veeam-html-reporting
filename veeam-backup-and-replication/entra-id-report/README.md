HTML Report for Veeam Backup & Replication Entra ID Protection
===================

![alt tag](https://jorgedelacruz.uk/wp-content/uploads/2026/06/entra-id-reporting.png)

This PowerShell script queries the Veeam Backup & Replication PostgreSQL database to generate a complete **Microsoft Entra ID Protection Report**.

The report includes Entra ID backup sessions, object-type counts per session, protected object inventory, CSV exports, and a self-contained HTML dashboard with charts and searchable AG Grid tables.

The script is provided as-is and is part of a **community initiative**. It is not officially supported by Veeam Support, and you should not open support cases for it.

This script is designed for those who want better visibility into Microsoft Entra ID protection directly from Veeam Backup & Replication, especially when operating VBR v12.3, v12.4, or v13 environments.

----------

### Why this report?

Microsoft Entra ID is one of the most critical identity layers in modern organizations. Protecting it is great, but being able to clearly report on what is protected, when it was protected, what failed, and which object types were stored in the repository is even better.

This report gives you a clear view of:

* Total Entra ID backup sessions
* Successful, warning, and failed sessions
* Protected object count
* Session result distribution
* Session results over time
* Daily object-type breakdown
* Main backup duration trend
* All job sessions with execution details
* Object counts per session
* All protected Entra ID objects
* CSV exports for further analysis

You can also search across the tables. For example, you can search by tenant, user, application, service principal, group, object type, or session result.

----------

### Getting started

You can read the full blog post here:

[https://jorgedelacruz.uk/2026/06/14/veeam-microsoft-entra-id-protection-report-with-html-dashboard-csv-export-and-email-delivery/](https://jorgedelacruz.uk/2026/06/14/veeam-microsoft-entra-id-protection-report-with-html-dashboard-csv-export-and-email-delivery/)

Or follow these quick steps.

### 1. Download the script

Download the `Get-EntraIDProtectionReport.ps1` file and review the configuration section:

```powershell
[bool]$ExportCsv  = $true
[bool]$ExportHtml = $true

[string]$ExportPath = "C:\temp\EntraID_Protection_Report.csv"
[string]$HtmlPath   = "C:\temp\EntraID_Protection_Dashboard.html"
```

### 2. Configure email delivery

The script can send the generated report using Microsoft Graph API.

Update the following values:

```powershell
[bool]$SendEmail     = $true
$RecipientEmail      = "YOUREMAIL@YOURDOMAIN.com"
$TenantId            = "YOURTENANT.onmicrosoft.com"
$ClientId            = "YOURCLIENTID"
$ClientSecretPlain   = "YOURCLIENTSECRETFORMAILAPP"
```

You will need an Azure App Registration with the required Microsoft Graph permission to send email.

### 3. Configure PostgreSQL access

Update the PostgreSQL connection settings if required:

```powershell
$PsqlInstallPath = "C:\Program Files\PostgreSQL"
$DbUser = "postgres"
$DbName = "VeeamBackup"
$DbHost = "localhost"
$DbPort = "5432"
```

The script searches recursively for `psql.exe` under the PostgreSQL installation path.

### 4. Select the report period

By default, the script includes the last 30 days of history:

```powershell
[int]$LastDays = 30
```

Change this value if you want a shorter or longer reporting window.

### 5. Download the required JavaScript libraries

The HTML dashboard is built as an offline, self-contained report. For this, the script embeds Highcharts and AG Grid directly into the generated HTML file.

Create the following folder:

```powershell
C:\temp\libs
```

Then download the required libraries:

```powershell
Invoke-WebRequest -Uri 'https://cdn.jsdelivr.net/npm/highcharts@11.4.1/highcharts.js' -OutFile 'C:\temp\libs\highcharts.js'

Invoke-WebRequest -Uri 'https://cdn.jsdelivr.net/npm/ag-grid-community@31.3.2/dist/ag-grid-community.min.js' -OutFile 'C:\temp\libs\ag-grid.js'
```

### 6. Install MSAL.PS

The script uses `MSAL.PS` to authenticate against Microsoft Graph API.

Run this once as Administrator:

```powershell
Install-Module -Name MSAL.PS -Force -AllowClobber
```

### 7. Run the script

Run the script from the Veeam Backup & Replication server, or from a machine with access to the Veeam PostgreSQL database and `psql.exe`:

```powershell
.\Get-EntraIDProtectionReport.ps1
```

----------

### Output files

The script generates the following files:

```text
C:\temp\EntraID_Protection_Report.csv
C:\temp\EntraID_Protection_Report_ObjectCounts.csv
C:\temp\EntraID_Protection_Report_ProtectedObjects.csv
C:\temp\EntraID_Protection_Dashboard.html
C:\temp\EntraID_Protection_Dashboard.zip
```

The ZIP file is used for email delivery because the generated offline HTML dashboard can be large due to the embedded JavaScript libraries.

----------

### What is included in the dashboard?

The HTML dashboard includes:

* KPI cards for sessions, success, warnings, failures, and protected objects
* Session results over time
* Session result distribution
* Daily object-type breakdown
* Backup duration trend
* All job sessions table
* Object counts per session table
* All protected objects table

The AG Grid tables allow sorting, filtering, searching, pagination, and hidden columns.

----------

### Supported object types

The report can show Entra ID object types such as:

* Users
* Groups
* Applications
* Service Principals
* Administrative Units
* Conditional Access Policies
* Role Definitions
* Role Assignments
* OAuth2 Permission Grants

----------

### Requirements

* Veeam Backup & Replication v12.3, v12.4, or v13
* PowerShell 5.1+
* PostgreSQL client, `psql.exe`
* Access to the VeeamBackup PostgreSQL database
* Access to the `veeamrepository_*` databases
* Highcharts JavaScript file
* AG Grid JavaScript file
* MSAL.PS PowerShell module, if email delivery is enabled
* Microsoft Graph App Registration, if email delivery is enabled

----------

### Notes

This script reads from the Veeam Backup & Replication PostgreSQL database and the related `veeamrepository_*` databases.

It does not modify backup jobs, repositories, restore points, or protected data.

Still, please review the script before running it, and test it in a lab before using it in production.

----------

### Disclaimer

This script is not an official Veeam product.

It is a community script shared as-is. Use it at your own risk.

Do not open support cases with Veeam Support for this script.

----------

### Author

Jorge de la Cruz  
Blog: [https://jorgedelacruz.uk](https://jorgedelacruz.uk)  
GitHub: [https://github.com/jorgedlcruz](https://github.com/jorgedlcruz)  
X: [@jorgedelacruz](https://x.com/jorgedelacruz)
