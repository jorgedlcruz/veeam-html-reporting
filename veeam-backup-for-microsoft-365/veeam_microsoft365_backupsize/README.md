# Veeam Backup for Microsoft 365 - Hybrid Storage Backup Sizing (PowerShell + HTML Analytics)


A **PowerShell-based sizing tool** for **Veeam Backup for Microsoft 365** that calculates actual backup sizes from hybrid cloud storage (S3/Wasabi + Azure Blob).  
Generates a **CSV report** and an **interactive HTML dashboard** with charts and data grids.

> ✅ Supports multiple repositories (S3 + Azure Blob)  
> ✅ Auto-discovers cache databases from PostgreSQL  
> ✅ Maps GUIDs to human-readable names (Users, Teams, Sites, Organizations)  
> ✅ Interactive HTML report with Highcharts and AG Grid  
> ✅ Optional name masking for privacy-sensitive environments

![Dashboard preview](https://jorgedelacruz.uk/wp-content/uploads/2026/02/vb365-backup-size-report.png)

---

## How it works

```
+-------------------------+      PostgreSQL (VeeamBackup365 + Cache DBs)
| Get_VB365_Hybrid_Size   | ---> SELECT id, name FROM organizations/mailboxes/teams/webs
|        .ps1             |
+------------+------------+
             |
             v
+-------------------------+      Cloud Storage (S3 / Azure Blob)
|  List & Size Objects    | ---> List blobs, sum sizes per object
+------------+------------+
             |
             | writes
             v
+-----------------------------------+
| VB365_Hybrid_Report.csv           |  <- Raw data export
| VB365_Hybrid_Analytics.html       |  <- Interactive dashboard
+-----------------------------------+
```

The script queries **PostgreSQL** for GUID-to-name mappings, then **lists cloud storage** directly via S3 API (SigV4) and Azure Blob REST API to calculate accurate backup sizes per object.

---

## Features

| Feature | Description |
|---------|-------------|
| **Multi-Repo Support** | Configure multiple S3 and Azure repositories |
| **Auto Cache Discovery** | Finds cache database names from `object_storage_repositories` |
| **GUID Mapping** | Resolves cryptic IDs to real user/team/site/org names |
| **Name Masking** | Optional privacy mode: `Jorge de la Cruz` → `Jor*****` |
| **CSV Export** | Machine-readable output for further analysis |
| **HTML Dashboard** | Charts (Top 10, Type Dist, Repo Usage, Org Breakdown) + AG Grid |

---

## Repo layout

```
/
├─ Get_VB365_Hybrid_Size.ps1      # Main script
├─ VB365_Hybrid_Report.csv        # Generated CSV output
├─ VB365_Hybrid_Analytics.html    # Generated interactive dashboard
├─ README.md                      # This file
└─ screenshot.png                 # Dashboard preview (optional)
```

---

## Requirements

- **PowerShell** 5.1+ or PowerShell 7
- **Npgsql.dll** (included with Veeam Backup for Microsoft 365 at `C:\Program Files\Veeam\Backup365\Npgsql.dll`)
- Network access to:
  - PostgreSQL on VB365 server (default port `5432`)
  - S3/Wasabi endpoint (e.g., `s3.eu-west-1.wasabisys.com`)
  - Azure Blob Storage (e.g., `<account>.blob.core.windows.net`)

---

## Quick start

### 1. Configure repositories

Edit the `$Repositories` array at the top of the script:

```powershell
$Repositories = @(
    # S3 / Wasabi
    @{
        Name      = "REPO-S3-WASABI"
        Type      = "S3"
        Region    = "eu-west-1"
        Bucket    = "veeam-wasabi-vb365"
        Folder    = "1YEAR-SNAPSHOT"
        Endpoint  = "https://s3.eu-west-1.wasabisys.com"
        AccessKey = "YOUR_ACCESS_KEY"
        SecretKey = "YOUR_SECRET_KEY"
    },
    
    # Azure Blob
    @{
        Name        = "VEEAM-AZURE-BLOB"
        Type        = "Azure"
        AccountName = "YOURSTORAGEACCOUNTNAME"
        Container   = "YOURCONTAINER"
        Folder      = "YOURFOLDER"
        AccountKey  = "YOUR_BASE64_ACCOUNT_KEY"
    }
)
```

### 2. Configure PostgreSQL

```powershell
$DbHost = "127.0.0.1"    # VB365 server IP
$DbPort = 5432
$DbUser = "postgres"
# Password: set via $env:PGPASSWORD or prompted at runtime
```

### 3. Configure export options

```powershell
[bool]$ExportHtml = $true     # Set to $false to skip HTML generation
[bool]$MaskNames  = $false    # Set to $true for privacy mode
```

### 4. Run the script

```powershell
.\Get_VB365_Hybrid_Size.ps1
```

You'll be prompted for the PostgreSQL password if `$env:PGPASSWORD` is not set.

### 5. View the outputs

- **CSV**: `VB365_Hybrid_Report.csv`
- **HTML**: `VB365_Hybrid_Analytics.html` (open in any browser)

---

## The dashboard (VB365_Hybrid_Analytics.html)

- **KPI Cards**: Total Objects, Total Size, Avg Object Size, Repositories
- **Charts**:
  - Top 10 Largest Objects (bar chart)
  - Storage Distribution by Type (pie chart)
  - Repository Usage (donut chart)
  - Organization Breakdown (column chart)
- **Data Grid**: Full object list with sorting, filtering, and pagination (AG Grid)

---

## CSV output columns

| Column | Description |
|--------|-------------|
| `RepoName` | Repository name from config |
| `RepoType` | `S3` or `Azure` |
| `OrgId` | Organization folder GUID |
| `OrgName` | Resolved organization name |
| `Type` | `Mailbox`, `Team`, or `Site` |
| `Name` | Resolved object name |
| `Id` | Object GUID |
| `Bytes` | Size in bytes |
| `GiB` | Size in GiB (2 decimals) |

---

## Name masking

When `$MaskNames = $true`, names are masked for privacy:

| Original | Masked |
|----------|--------|
| `Jorge de la Cruz` | `Jor*****` |
| `jorgedelacruz.onmicrosoft.com` | `jor*****` |
| `Baloncesto Azudense` | `Bal*****` |

Masking applies to console output, CSV, and HTML.

---

## Troubleshooting

**"Npgsql not found"**  
→ Ensure `C:\Program Files\Veeam\Backup365\Npgsql.dll` exists or update `$NpgsqlPath`.

**"Connection refused" to PostgreSQL**  
→ Check firewall rules and that PostgreSQL is accepting TCP connections.

**Organization names show as GUIDs**  
→ The script queries `backup.organizations` from the cache database. Ensure the cache DB is accessible.

**Empty HTML report / grid**  
→ Check browser console for errors. Ensure you're using a modern browser (Chrome, Firefox, Edge).

---

## Security notes

- **Credentials**: S3/Azure keys are stored in the script. For production, consider using environment variables or a secrets manager.
- **PostgreSQL password**: Use `$env:PGPASSWORD` to avoid interactive prompts in scheduled tasks.
- **Name masking**: Enable `$MaskNames` if sharing reports externally.

---

## Scheduling

Run on a schedule using Windows Task Scheduler:

**Action:**
```
Program: powershell.exe
Arguments: -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Get_VB365_Hybrid_Size.ps1"
Start in: C:\Scripts
```

**Environment variable** (for password):
Set `PGPASSWORD` in the task's environment or use a wrapper script.

---

## Customization

- **Add more repos**: Extend `$Repositories` array
- **Change rounding**: Search for `[math]::Round` and adjust decimals
- **Modify HTML**: Edit the `New-HtmlReport` function (embedded HTML template)
- **Adjust masking**: Modify `Get-MaskedName` function

---

## License & Support

This is a **community** project. Provided **as-is** with no warranties and **no vendor support**.  
Please open issues/PRs for bugs and improvements.

---

## Credits

- Built with ❤️ using **PowerShell**, **Highcharts**, and **AG Grid**
- Author: **Jorge de la Cruz** ([@jorgedelacruz](https://twitter.com/jorgedelacruz))
- GitHub: [github.com/jorgedlcruz](https://github.com/jorgedlcruz)
- Blog: [jorgedelacruz.uk](https://jorgedelacruz.uk)
