# Veeam Backup for Azure - Workload Protection History Report

![alt tag](https://jorgedelacruz.uk/wp-content/uploads/2025/06/veeam-workload-protection-history-azure-001.png)

This script requires you to define the VM names and the date range to audit. It connects to the Veeam Backup for Azure API (both public and internal), authenticates, and queries the protection history of each VM, returning the job sessions, types, and statuses within the selected timeframe.

It generates two output files: an HTML report and a CSV export — both well-suited for compliance, audit review, and daily operational checks.

The Script is provided as it is, and bear in mind you can not open support Tickets regarding this project.

---

## Getting started

You can follow the steps on the next Blog Post:  
[https://jorgedelacruz.uk/2025/07/01/veeam-veeam-backup-for-azure-workload-protection-history-report/](https://jorgedelacruz.uk/2025/07/01/veeam-veeam-backup-for-azure-workload-protection-history-report/)

Or try with these simple steps:

- Download the PowerShell file
- Edit the parameters: IP/FQDN of your VB-Azure server, user credentials, VM names, and date range
- Run the script, then locate both HTML and CSV files in the output path
- Done ✅

---

## Additional Information

- More fields and filtering options may be added over time — suggestions are welcome!

## Known issues

- No known issues at this time
