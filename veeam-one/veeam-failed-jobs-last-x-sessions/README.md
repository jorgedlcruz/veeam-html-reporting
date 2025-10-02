HTML Report for Veeam ONE Consecutive Job Failures
===================

![alt tag](https://jorgedelacruz.uk/wp-content/uploads/2025/06/vone-consecutivejobfail-000.jpg)

This PowerShell Script will query the Veeam ONE SQL database using stored procedures to identify backup jobs with consecutive failures. It analyzes job execution history within a configurable time window and generates a detailed HTML report highlighting jobs and workloads that match the failure criteria.

The Script is provided as it is, and bear in mind you can not open support Tickets regarding this project. It is a Community Project.

We use Veeam ONE stored procedures `reportpack.rsrp_Backup_JobHistoricalInformation` and `reportpack.rsrp_Backup_JobHistoricalInformationDetails` to efficiently retrieve comprehensive backup job data and workload-level failure details.

----------

### Getting started
You can follow the steps on the next Blog Post - [https://jorgedelacruz.uk/2025/06/11/veeam-report-on-consecutive-failures-using-veeam-one-html-automated-email-community/](https://jorgedelacruz.uk/2025/06/11/veeam-report-on-consecutive-failures-using-veeam-one-html-automated-email-community/)

Or try with these simple steps:
* Download the `VONE_Failed_Jobs_Last_X_Sessions.ps1` file and change the parameters under Global Parameters section with your real data:
  * `$SQLServer` - Your Veeam ONE SQL Server instance
  * `$SQLDBName` - Your Veeam ONE database name (typically "VeeamONE")
  * `$reportIntervalDays` - Number of days to analyze (default: 30)
  * `$requiredFailureCount` - Number of consecutive failures to trigger alert (default: 3)
* Ensure the account running the script has read access to the Veeam ONE SQL database
* Run the PowerShell script: `.\VONE_Failed_Jobs_Last_X_Sessions.ps1`
* Check the script directory for the generated `BackupJobHistoricalFailures.html` report
* Schedule the script execution using Windows Task Scheduler for automated monitoring
* Enjoy comprehensive backup failure monitoring! :)

**Prerequisites**
* Windows PowerShell 5.1 or later
* SQL Server connectivity to Veeam ONE database
* Appropriate SQL permissions to execute Veeam ONE stored procedures

----------

### Script Features

**Intelligent Failure Detection**
* Configurable consecutive failure threshold (default: 3 failures)
* Flexible time window analysis (default: last 30 days)
* Smart filtering of valid job sessions with proper error handling

**Comprehensive Reporting**
* **Job Summary Table**: Shows failed jobs with VM success/failure breakdown, processing stats, and backup details
* **Workload Details**: Lists specific VMs that failed within each problematic job
* **Visual Formatting**: Color-coded status indicators and responsive HTML design
* **Chronological Sorting**: Most recent failures displayed first for immediate attention

**Advanced Console Output**
* Real-time progress tracking with color-coded status messages
* Detailed parameter display for troubleshooting
* Row count verification against direct SQL execution
* Smart filtering explanations for data validation

**Robust Error Handling**
* SQL connection testing before execution
* Comprehensive null value and DBNull handling
* Graceful error recovery with detailed logging
* Parameter type validation for stored procedure calls

----------

### Email Integration (Optional)

To enable automated email delivery, you can add the email functionality back:

1. **Install Required Module:**
   ```powershell
   Install-Module -Name MSAL.PS -Force -AllowClobber
   ```

2. **Configure Azure App Registration:**
   * Create an Azure App Registration with Mail.Send permissions
   * Update the script variables:
     * `$TenantId` - Your Azure AD tenant ID
     * `$ClientId` - Your App Registration client ID  
     * `$ClientSecret` - Your App Registration client secret
     * `$RecipientEmail` - Target email address

3. **Uncomment Email Section:**
   * Remove the `<# ... #>` comment blocks around the email code
   * The script will automatically attach the HTML report and send via Microsoft Graph API

----------

### Customization Options

**Failure Criteria Tuning**
* Adjust `$requiredFailureCount` to change sensitivity (1-10 failures)
* Modify `$reportIntervalDays` to extend or reduce analysis window
* Filter specific job types by adjusting the stored procedure parameters

**Report Styling**
* Customize HTML CSS in the script for corporate branding
* Add additional metrics from the stored procedure result set
* Modify table columns to focus on specific backup aspects

**Database Connectivity**
* Support for both Windows Authentication and SQL Authentication
* Configurable connection timeout and command timeout values
* Multiple SQL Server instance support with connection string customization

----------

### Troubleshooting

**Common Issues**
* **"No valid records after filtering"**: Check date formats and ensure job sessions exist within the specified time window  
* **"SQL Connection failed"**: Verify SQL Server connectivity, authentication, and Veeam ONE database accessibility
* **"Stored procedure not found"**: Ensure Veeam ONE is properly installed and the account has appropriate SQL permissions

**Debug Mode**
The script includes comprehensive debug output showing:
* Exact parameters sent to stored procedures
* Row counts at each processing stage  
* Column names and data types returned
* Filtering decisions with explanations
* Connection status and error details

**Performance Optimization**
* For large environments, consider reducing `$reportIntervalDays` to improve execution speed
* Use SQL Server indexes on job execution tables for faster stored procedure response
* Run during off-peak hours to minimize impact on Veeam ONE performance

----------

### Additional Information
* The script uses advanced parameter type handling to ensure compatibility with Veeam ONE stored procedures
* VM-level failure tracking provides granular insight into backup job issues
* Future enhancements planned: additional backup metrics, trend analysis, and performance benchmarking
* Share your ideas and feature requests via GitHub issues or community forums

### Known Issues
* Large time windows (>365 days) may impact performance in environments with extensive job history
* Console output formatting may vary across different PowerShell versions
* SQL Server regional settings can affect date filtering - ensure consistent date formats