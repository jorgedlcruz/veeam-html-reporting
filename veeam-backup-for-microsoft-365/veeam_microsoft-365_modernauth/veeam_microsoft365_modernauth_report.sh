#!/bin/bash
##      .SYNOPSIS
##      HTML Report to consume easily via EMAIL, or from the Report Directory
## 
##      .DESCRIPTION
##      This Script will query the Veeam Backup for Microsoft 365 API and produce a list of Organizations, including if they have Modern Auth enabled or not. Then it saves it into a comfortable HTML, and it is sent over EMAIL
##      The Script it is provided as it is, and bear in mind you can not open support Tickets regarding this project. It is a Community Project
##	
##      .Notes
##      NAME:  veeam_microsoft365_modernauth_report.sh
##      ORIGINAL NAME: veeam_microsoft365_modernauth_report.sh
##      LASTEDIT: 14/04/2022
##      VERSION: 1.0
##      KEYWORDS: Veeam, HTML, Report, Microsoft 365
   
##      .Link
##      https://jorgedelacruz.es/
##      https://jorgedelacruz.uk/

# Configurations
##
# Endpoint URL for login action
veeamUsername="YOURVEEAMBACKUPUSER"
veeamPassword="YOURVEEAMBACKUPPASS"
veeamRestServer="YOURVEEAMBACKUPFORMICROSOFT365IP"
veeamRestPort="4443" #Default Port

## System Variables
reportPath="/home/oper/vb365_daily_reports"
email_add="CHANGETHISWITHYOUREMAIL"
reportDate=$(date "+%A%B%d%Y")

## Login and Token
veeamBearer=$(curl -X POST --header "Content-Type: application/x-www-form-urlencoded" --header "Accept: application/json" -d "grant_type=password&username=$veeamUsername&password=$veeamPassword&refresh_token=%27%27" "https://$veeamRestServer:$veeamRestPort/v5/token" -k --silent | jq -r '.access_token')

##
# Veeam Backup for Microsoft 365 Organization Overview. This part will check the Organizations
##
veeamVB365Url="https://$veeamRestServer:$veeamRestPort/v5/Organizations"
veeamOrganizationUrl=$(curl -X GET --header "Accept:application/json" --header "Authorization:Bearer $veeamBearer" "$veeamVB365Url" 2>&1 -k --silent)

#Generating HTML file
html="$reportPath/Microsoft365-ModernAuth-Report-$reportDate.html"
echo '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">' >> $html
echo "<html>" >> $html
echo "<body>" >> $html
echo '<table style="border-collapse: collapse; transform-origin: left top 0px;" min-scale="0.6182495344506518" width="100%" cellspacing="0" cellpadding="0" border="0">' >> $html
echo "<thead>" >> $html
echo "<tr>" >> $html
echo "<th style='border:1px solid #3B3B3B;background-color: #10A54A;color: white;font-weight: bold;font-size: 16px;height: 30px;vertical-align: bottom;padding: 0 0 10px 5px;font-family: Tahoma;text-align: left;'>Organization Name</th>" >> $html
echo "<th style='border:1px solid #3B3B3B;background-color: #10A54A;color: White;font-weight: bold;font-size: 16px;height: 30px;vertical-align: bottom;padding: 0 0 10px 5px;font-family: Tahoma;text-align: left;'>Region</th>" >> $html
echo "<th style='border:1px solid #3B3B3B;background-color: #10A54A;color: White;font-weight: bold;font-size: 16px;height: 30px;vertical-align: bottom;padding: 0 0 10px 5px;font-family: Tahoma;text-align: left;'>Service Account</th>" >> $html
echo "<th style='width: 15%;border:1px solid #3B3B3B;background-color: #10A54A;color: White;font-weight: bold;font-size: 16px;height: 30px;vertical-align: bottom;padding: 0 0 10px 5px;font-family: Tahoma;text-align: left;'>Modern Auth EX</th>" >> $html
echo "<th style='width: 15%;border:1px solid #3B3B3B;background-color: #10A54A;color: White;font-weight: bold;font-size: 16px;height: 30px;vertical-align: bottom;padding: 0 0 10px 5px;font-family: Tahoma;text-align: left;'>Modern Auth SP</th>" >> $html
echo "<th style='border:1px solid #3B3B3B;background-color: #10A54A;color: White;font-weight: bold;font-size: 16px;height: 30px;vertical-align: bottom;padding: 0 0 10px 5px;font-family: Tahoma;text-align: left;'>Last Backup</th>" >> $html
echo "</tr>" >> $html
echo "</thead>" >> $html
echo "<tbody>" >> $html

declare -i arrayOrganizations=0
for id in $(echo "$veeamOrganizationUrl" | jq -r '.[].id'); do
    OrganizationName=$(echo "$veeamOrganizationUrl" | jq --raw-output ".[$arrayOrganizations].officeName")
    OrganizationRegion=$(echo "$veeamOrganizationUrl" | jq --raw-output ".[$arrayOrganizations].region")
    OrganizationServiceAccount=$(echo "$veeamOrganizationUrl" | jq --raw-output ".[$arrayOrganizations].exchangeOnlineSettings.account")
       if [ "$OrganizationServiceAccount" == "" ]; then OrganizationServiceAccount=$(echo "$veeamOrganizationUrl" | jq --raw-output ".[$arrayOrganizations].sharePointOnlineSettings.account"); fi 
    OrganizationMAEX=$(echo "$veeamOrganizationUrl" | jq --raw-output ".[$arrayOrganizations].exchangeOnlineSettings.useApplicationOnlyAuth")
        case $OrganizationMAEX in
        true)
            fontex="#37872D"
        ;;
        false)
            fontex="#C4162A"
        ;;
        esac
    OrganizationMASP=$(echo "$veeamOrganizationUrl" | jq --raw-output ".[$arrayOrganizations].sharePointOnlineSettings.useApplicationOnlyAuth")
        case $OrganizationMASP in
        true)
            fontsp="#37872D"
        ;;
        false)
            fontsp="#C4162A"
        ;;
        esac
    OrganizationLastBackup=$(echo "$veeamOrganizationUrl" | jq --raw-output ".[$arrayOrganizations].lastBackuptime")
    echo "<tr>" >> $html
    echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid #A7A9AC; font-family:Tahoma; font-size:14px' nowrap="">$OrganizationName</td>" >> $html
    echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid #A7A9AC; font-family:Tahoma; font-size:14px' nowrap="">$OrganizationRegion</td>" >> $html
    echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid #A7A9AC; font-family:Tahoma; font-size:14px' nowrap="">$OrganizationServiceAccount</td>" >> $html
    echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid #A7A9AC; font-family:Tahoma; font-size:14px;color:$fontex' nowrap="">$OrganizationMAEX</td>" >> $html
    echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid #A7A9AC; font-family:Tahoma; font-size:14px;color:$fontsp' nowrap="">$OrganizationMASP</td>" >> $html
    echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid #A7A9AC; font-family:Tahoma; font-size:14px' nowrap="">$OrganizationLastBackup</td>" >> $html
    echo "</tr>" >> $html

        arrayOrganizations=$arrayOrganizations+1
    done
    
echo "</tbody>" >> $html
echo "</table>" >> $html
echo "<br/>" >> $html
echo "<br/>" >> $html
echo "</body>" >> $html
echo "</html>" >> $html
#Sending Email to the user
cat $html | s-nail -M "text/html" -s "$veeamRestServer - Veeam Backup for Microsoft 365: Organization Modern Auth Report" $email_add




