HTML Report for Veeam Backup for AWS
===================

![alt tag](https://www.jorgedelacruz.es/wp-content/uploads/2021/06/veeam-html-aws-001.jpg)

This Script will query the Veeam Backup for AWS  API and save the job sessions stats for the last 24 hours. Then it saves it into a comfortable HTML, and it is sent over EMAIL
The Script it is provided as it is, and bear in mind you can not open support Tickets regarding this project. It is a Community Project, and it does use some internal API Calls as well as a workaround

We use Veeam Backup for Microsoft AWS v3.0 RESTfulAPI to reduce the workload and increase the speed of script execution. 

----------

### Getting started
You can follow the steps on the next Blog Post - [https://jorgedelacruz.uk/2021/06/11/veeam-detailed-html-daily-report-for-veeam-backup-for-aws-is-now-available-community-project/](https://jorgedelacruz.uk/2021/06/11/veeam-detailed-html-daily-report-for-veeam-backup-for-aws-is-now-available-community-project/)

Or try with this simple steps:
* Download the veeam_aws_email_report.sh file and change the parameters under Configuration, like username/password, etc. with your real data
* Make the script executable with the command chmod +x veeam_aws_email_report.sh
* Run the veeam_aws_email_report.sh and check under the folder you defined, that you have your HTML Report
* Schedule the script execution, for example every day at 00:05 using crontab
* You will need mailutils on your server in order to send Emails - And most likely have a proper SmartHost to rely your email
* Enjoy :)

**Extra**
You will need an extra package to be able to send secure emails, that will always land without problems:

``sudo apt-get install -y s-nail``

This will allow us to use a better, and modern, way of sending emails. Now with the package downloaded, we need to edit the system settings for email:

``vi ~/.mailrc``

Inside the file, which might be empty first time you open it, introduce the next:

``set smtp-use-starttls
set ssl-verify=ignore
set smtp=smtp://YOURSMTPSERVER:587
set smtp-auth=login
set smtp-auth-user="YOURUSER@YOURDOMAIN.COM"
set smtp-auth-password="YOURPASSWORD"
set from="YOURFROMEMAIL@YOURDOMAIN.COM"``

----------

### Additional Information
* Having in mind to add much more information into the report, share your ideas, please.

### Known issues 
Emails issues are the most common ones, just make sure you are using a valid SmartHost to rely your emails.