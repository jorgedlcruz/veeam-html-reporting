# Veeam Backup for Azure – Job History Report

![alt tag](https://jorgedelacruz.uk/wp-content/uploads/2025/07/vb-azure-job-history-html-001.png)

This PowerShell script connects to the **Veeam Backup for Azure API**, authenticates securely, and retrieves **session-level job history** across all workloads. It supports filtering by **session types** (e.g., `PolicyBackup`, `PolicySnapshot`, `PolicyArchive`) and **date range**.

The script generates a clean, structured **HTML report** containing key metrics:
- Policy name
- Session type
- Status (Success/Warning/Failed)
- Protected instances count
- Start/Stop times (formatted)
- Duration

The report is automatically emailed via **Microsoft Graph API** and saved locally.

> **Note:** This is a community project, provided as-is. **Support tickets cannot be opened** for this solution.

---

## Getting Started

Full blog post and usage guide available at:  
[https://jorgedelacruz.uk/2025/07/16/veeam-veeam-backup-for-azure-job-history-report/](https://jorgedelacruz.uk/2025/07/16/veeam-veeam-backup-for-azure-job-history-report/)

Quick steps:

- 📥 Download the PowerShell script
- 🛠️ Edit the top parameters:
  - Veeam Backup for Azure server (`$VeeamServer`)
  - Credentials (`$VeeamUsername` / `$VeeamPassword`)
  - Session Types filter (e.g., `"PolicyBackup,PolicySnapshot,PolicyArchive"`)
  - Reporting Date Range (`$ReportDateFrom` / `$ReportDateTo`)
  - Microsoft Graph email parameters (`$RecipientEmail`, `$TenantId`, `$ClientId`, `$ClientSecret`)
- ▶️ Run the script
- 📧 Report will be **emailed automatically** and also **saved locally** as HTML

---

## Output

- 📊 **HTML Report** – clean, formatted, ready for compliance or operational review
- 📩 **Email Delivery** – report sent automatically using Microsoft Graph API

---

## Features

- Secure API connection using OAuth2
- Session-type and date-range filtering
- Configurable time/date formatting
- HTML report generation
- Automated email delivery
- Modular, extensible PowerShell design

---

## Known Issues

- Intermittent 404 errors when requesting session types that return no results — does **not affect report generation**

---

## License

Community script — distributed as-is without official support.
