# HTML Report for Veeam Backup for AWS

![Report screenshot](https://jorgedelacruz.uk/wp-content/uploads/2025/09/veeam-html-aws-9-001.jpg)

This script queries the Veeam Backup for AWS REST API for recent job sessions and builds a clean HTML report (then emails it).  
It’s a community project, provided **as-is**.

---

## What’s new (compared to the original script)

- **SLA Policies support**
  - Handles modern/extended session types:
    - `PolicyBackup`, `PolicySnapshot`, `PolicyRemoteSnapshot`
    - `PolicyRdsSnapshot`
    - `PolicyEfsBackup`, `PolicyEfsBackupCopy`
    - `VpcBackup`

- **Stronger warning/error surfacing**
  - If a session has warnings/errors but **no per-workload “Processing …” lines**, we print a **single summary row** with:
    - worst status, representative message, time, and duration.
  - Explicit handling for:
    - **“The resource is already protected by another policy: <name>”** → shown as a row with the workload name and job type marked **“(skipped)”**.
    - **“There are no resources to process”** → shown as a clear one-liner.

- **Extended Session Types filter (client-side)**
  - New variable `filterExtendedTypes` accepts a **comma-separated list** (turned into a regex) to limit which sessions render.
    - Examples:
      - `filterExtendedTypes="PolicyBackup,PolicySnapshot"`
      - `filterExtendedTypes="VpcBackup"`
      - `filterExtendedTypes=""` (show all)
  - Console prints a quick breakdown per type for sanity checking.

- **Better parsing & HTML fixes**
  - EC2 backups: extract workload name and **transferred size** from  
    `… processing <name> - 100%, <size> transferred.` lines.
  - Snapshots/EFS/replica snapshots: consistent, clean workload names from “Processing …”.
  - VPC backups: simplified/robust “Performing …” parsing.
  - Consistent color coding for `Success` / `Warning` / `Failed|Error`.
  - Fixed HTML quoting so `$fontsize*` variables actually render (no stray literal `$fontsize2`).
  - Header shows the **active extendedSessionType filter**.

- **API/stability improvements**
  - Uses `statistics/summary` (not `system/version`) for counts.
  - Safer bearer-token check and clearer log messages.
  - Ensures report folder exists; cleaner console output.

---

## Getting started

**Full guide:**  
<https://jorgedelacruz.uk/2021/06/11/veeam-detailed-html-daily-report-for-veeam-backup-for-aws-is-now-available-community-project/>

**Quick steps:**

1. Download `veeam_aws_email_report.sh` and update the **Configurations** section (server, port, API version, credentials, email).
2. Optionally set a filter, for example:
   ```bash
   filterExtendedTypes="PolicyBackup,PolicySnapshot"
   ```
3. Make the script executable with the command chmod +x veeam_aws_email_report.sh
4. Run the veeam_aws_email_report.sh and check under the folder you defined, that you have your HTML Report
5. Schedule the script execution, for example every day at 00:05 using crontab
6. You will need mailutils on your server in order to send Emails - And most likely have a proper SmartHost to rely your email
7. Enjoy :)

**Extra**
You will need an extra package to be able to send secure emails, that will always land without problems:

``sudo apt-get install -y s-nail``

This will allow us to use a better, and modern, way of sending emails. Now with the package downloaded, we need to edit the system settings for email:

``vi ~/.mailrc``

Inside the file, which might be empty first time you open it, introduce the next:
   ```bash
   set smtp-use-starttls
   set ssl-verify=ignore
   set smtp=smtp://YOURSMTPSERVER:587
   set smtp-auth=login
   set smtp-auth-user="YOURUSER@YOURDOMAIN.COM"
   set smtp-auth-password="YOURPASSWORD"
   set from="YOURFROMEMAIL@YOURDOMAIN.COM"
   ```
----------

## Output behavior (quick reference)

- Per-workload rows for EC2 backups, snapshots, EFS, replicas, VPC (when log lines include "Processing ..." / "Performing ...").
- One-liner fallback when there are warnings/errors but no per-workload details.
- Special cases:
  - Already protected elsewhere → <workload> with **(skipped)** job type.
  - No resources to process → single descriptive row.
- Colors: green = Success, amber = Warning, red = Failed/Error, gray = other.

## Known issues

- Most problems are mail relay related—use a valid smarthost and confirm credentials/ports.
- Keep `apiVersion` aligned with your appliance; REST versions can change between releases.

## Tip: sanity check your filter

The script prints a per-type count, e.g.:

[INFO]  PolicyBackup: 8  
[INFO]  PolicySnapshot: 6

If it’s empty, clear or adjust `filterExtendedTypes` (set to `""` to show everything).

