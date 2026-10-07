HTML Report for Veeam ONE Backup License Inventory
===================

![alt tag](https://jorgedelacruz.uk/wp-content/uploads/2026/10/vone-backupserver-licensing-001.png)

This PowerShell Script queries the Veeam ONE SQL database (or reads an offline exported dataset) to generate a comprehensive HTML report on backup license consumption across all managed Veeam Backup & Replication servers. It independently tracks Instance, Socket, and Capacity license pools and groups servers by license alert severity.

The Script is provided as it is, and bear in mind you can not open support Tickets regarding this project. It is a Community Project.

We use the Veeam ONE stored procedure `reportpack.rsrp_Backup_BackupInventory` to retrieve complete license inventory and server metadata.

----------

### Getting started

You can run the script with simple steps:
* Download the `VONE_Backupserver_Licensing_Report.ps1` file.
* Configure the global parameters or parameters in the `$Config` hashtable inside the script:
  * `-SQLServer` - Your Veeam ONE SQL Server instance (default: `'VEEAMONE\VEEAMSQL2017'`)
  * `-SQLDBName` - Your Veeam ONE database name (default: `'VeeamONE'`)
  * `-WarningThresholdPercent` - Near-limit warning threshold percentage (default: `90`)
  * `-InputPath` - (Optional) Path to a tab-delimited (`.tsv`) or comma-delimited (`.csv`) offline SQL export to bypass direct database connection
  * `-OutputPath` - (Optional) HTML destination file path (defaults to `BackupLicenseInventory.html`)
* Ensure the executing account has read access to the Veeam ONE SQL database and permission to execute stored procedures.
* Run the PowerShell script:
  ```powershell
  .\VONE_Backupserver_Licensing_Report.ps1 -SQLServer 'SQL01\VEEAM' -SQLDBName 'VeeamONE'
  ```
* Open the generated `BackupLicenseInventory.html` report or review the summary table output in your console.
* Schedule execution via Windows Task Scheduler for automated monitoring and email reporting! :)

**Prerequisites**
* Windows PowerShell 5.1 or PowerShell 7 on Windows
* SQL Server connectivity to the Veeam ONE database (or an offline CSV/TSV export file)
* Appropriate SQL permissions to execute stored procedures in the Veeam ONE database
* No external PowerShell modules required (uses native SQL Client and REST calls for Microsoft Graph)

----------

### Script Features

**Multi-Metric License Pool Analysis**
* **Instances**: Tracks used vs. licensed instances, percentage utilized, and remaining balance.
* **Sockets**: Monitors active socket license counts.
* **Capacity**: Evaluates source capacity usage against total licensed capacity with configurable display units.

**Severity-Based Server Categorization**
* **Over Allowance (Red)**: Servers exceeding licensed allowances or consuming licenses against a zero allowance.
* **Near Limit (Orange)**: Servers reaching or exceeding the near-limit threshold (configurable, default 90%).
* **Rest of Backup Servers (Green)**: Servers operating safely below thresholds or with unverified usage.

**High-Level KPI Summary Cards**
* Total count of monitored backup servers.
* Quick count of servers exceeding allowance.
* Count of servers near usage limits.
* Count of remaining healthy/other backup servers.

**Flexible Data Source Options**
* Direct SQL connection to Veeam ONE database.
* Offline input via exported TSV/CSV files for isolated or security-restricted environments.

----------

### Email Integration (Optional)

Automated email delivery is natively supported via Microsoft Graph API using OAuth 2.0 application credentials.

1. **Configure M365 App Registration:**
   * Create an Azure/Entra ID App Registration with `Mail.Send` application permissions and admin consent.
2. **Update the `$Config` Hashtable in `VONE_Backupserver_Licensing_Report.ps1`:**
   ```powershell
   $Config = @{
       EnableEmail               = $true
       AuthMode                  = 'ClientSecret' # 'ClientSecret' or 'Certificate'
       TenantId                  = 'YOUR-TENANT-ID'
       ClientId                  = 'YOUR-CLIENT-ID'
       ClientSecret              = 'YOUR-CLIENT-SECRET' # Or CertificateThumbprint if using AuthMode = 'Certificate'
       SenderEmail               = 'reports@yourdomain.com'
       ToRecipients              = @('admin@yourdomain.com')
       EmailSubjectPrefix        = '[Veeam ONE] Backup license inventory'
       AttachHtmlReport          = $false # Set to $true to attach HTML file
       SaveToSentItems           = $true
   }
   ```
3. When `$Config.EnableEmail` is `$true`, the script embeds the HTML report into an email sent via Microsoft Graph.

----------

### Customization Options

**Threshold & Capacity Configuration**
* `-WarningThresholdPercent`: Change the near-limit alert percentage (1-100%).
* `CapacityDisplayDivisor` & `CapacityUnit`: Adjust capacity unit conversions (e.g. source units, TB, GB).

**SQL Authentication & Timeout**
* Supports Windows Integrated Authentication (default) or SQL Authentication via environment variable (`VONE_SQL_PASSWORD`).
* Adjustable connection (`SqlConnectionTimeout`) and query timeout (`SqlCommandTimeoutSeconds`).

----------

### Troubleshooting

**Common Issues**
* **"Set SQLServer to your SQL Server instance..."**: Update the `-SQLServer` parameter or `$Config` hashtable with your actual SQL Server hostname/instance.
* **"No license rows for section_id 0"**: Verify database connectivity and ensure the `reportpack.rsrp_Backup_BackupInventory` stored procedure returns valid schema rows.
* **"Microsoft 365 authentication failed"**: Check Tenant ID, Client ID, Secret/Certificate validity, and ensure `Mail.Send` application permission is granted.

----------

### Additional Information
* The script processes license metrics natively without requiring external modules (such as MSAL or SQL modules).
* Dot-sourcing the script (`. .\VONE_Backupserver_Licensing_Report.ps1`) loads functions into the session without executing the main report.
* Share your feedback, enhancements, or bug reports via GitHub issues or community channels!