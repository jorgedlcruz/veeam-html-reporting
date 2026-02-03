#!/bin/bash
##      .SYNOPSIS
##      HTML Report to consume easily via EMAIL, or from the Report Directory
## 
##      .DESCRIPTION
##      This Script will query the Veeam Backup for Microsoft 365 API and save the job sessions stats for the last 24 hours. Then it saves it into a comfortable HTML, and it is sent over EMAIL
##      The Script it is provided as it is, and bear in mind you can not open support Tickets regarding this project. It is a Community Project
##	
##      .Notes
##      NAME:  veeam_microsoft365_email_report.sh
##      ORIGINAL NAME: veeam_aws_email_report.sh
##      LASTEDIT: 03/08/2021
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
sessionsJob="48" #Based on the VBO schedule, 48 means running the job every 30 minutes for the last 24 hours
reportDate=$(date "+%A, %B %d, %Y %r")
reportDatePath=$(date "+%A%B%d%Y")
reportDateTo=$(date "+%Y-%m-%d")
reportDateFrom=$(date -d "$reportDateTo" '+%s')
reportPath="/home/oper/vbo_daily_reports"
email_add="CHANGETHISWITHYOUREMAIL"
color1="#a7a9ac"
color2="#f3f4f4"
color3="#626365"
color4="#e3e3e3"
fontsize1="20px"
fontsize2="20px"
fontsize3="22px"

## Login and Token

veeamBearer=$(curl -X POST --header "Content-Type: application/x-www-form-urlencoded" --header "Accept: application/json" -d "grant_type=password&username=$veeamUsername&password=$veeamPassword&refresh_token=%27%27" "https://$veeamRestServer:$veeamRestPort/v5/token" -k --silent | jq -r '.access_token')


##
# Veeam Backup for Microsoft 365 Jobs Overview. This part will check VBO Jobs Overview
##
veeamVBOUrl="https://$veeamRestServer:$veeamRestPort/v5/Jobs"
veeamJobsUrl=$(curl -X GET --header "Accept:application/json" --header "Authorization:Bearer $veeamBearer" "$veeamVBOUrl" 2>&1 -k --silent)

declare -i arrayJobs=0
for id in $(echo "$veeamJobsUrl" | jq -r '.[].id'); do
    SessionPolicyName=$(echo "$veeamJobsUrl" | jq --raw-output ".[$arrayJobs].name" | awk '{gsub(/ /,"\\ ");print}')
    idJob=$(echo "$veeamJobsUrl" | jq --raw-output ".[$arrayJobs].id")
    
    # Backup Job Sessions
    veeamVBOUrl="https://$veeamRestServer:$veeamRestPort/v5/Jobs/$idJob/JobSessions?limit=$sessionsJob"
    veeamJobSessionsUrl=$(curl -X GET --header "Accept:application/json" --header "Authorization:Bearer $veeamBearer" "$veeamVBOUrl" 2>&1 -k --silent)
    declare -i arrayJobsSessions=0
    for id in $(echo "$veeamJobSessionsUrl" | jq -r '.results[].id'); do
      creationTime=$(echo "$veeamJobSessionsUrl" | jq --raw-output ".results[$arrayJobsSessions].creationTime")
      creationTimeUnix=$(date -d "$creationTime" +"%s")
      creationTimeP=$(date -d $creationTime "+%A, %B %d, %Y %r")
      creationTimeB=$(date -d $creationTime '+%r')
      endTime=$(echo "$veeamJobSessionsUrl" | jq --raw-output ".results[$arrayJobsSessions].endTime")
      endTimeUnix=$(date -d "$endTime" +"%s")
      endTimeB=$(date -d $endTime '+%r')
      totalDuration=$(($endTimeUnix - $creationTimeUnix))
      totalDurationB=$(echo $(($(($totalDuration - $totalDuration/86400*86400))/3600))h:$(($(($totalDuration - $totalDuration/86400*86400))%3600/60))m:$(($(($totalDuration - $totalDuration/86400*86400))%60))s)
      SessionStatus=$(echo "$veeamJobSessionsUrl" | jq --raw-output ".results[$arrayJobsSessions].status")
      case $SessionStatus in
        Success)
            bcolor="#37872D"
        ;;
        Warning)
            bcolor="#FA6400"
        ;;
        Failed)
            bcolor="#C4162A"
        ;;
        esac
      processingRate=$(echo "$veeamJobSessionsUrl" | jq --raw-output ".results[$arrayJobsSessions].statistics.processingRateBytesPS")
      processingRateP=$(echo "scale=2; $processingRate/1024" | bc)
      readRate=$(echo "$veeamJobSessionsUrl" | jq --raw-output ".results[$arrayJobsSessions].statistics.readRateBytesPS")
      readRateP=$(echo "scale=2; $readRate/1024" | bc)
      writeRate=$(echo "$veeamJobSessionsUrl" | jq --raw-output ".results[$arrayJobsSessions].statistics.writeRateBytesPS")
      writeRateP=$(echo "scale=2; $writeRate/1024" | bc)
      transferredData=$(echo "$veeamJobSessionsUrl" | jq --raw-output ".results[$arrayJobsSessions].statistics.transferredDataBytes")
      transferredDataP=$(echo "scale=2; $transferredData/1024" | bc)
      processedObjects=$(echo "$veeamJobSessionsUrl" | jq --raw-output ".results[$arrayJobsSessions].statistics.processedObjects")
      bottleneck=$(echo "$veeamJobSessionsUrl" | jq --raw-output ".results[$arrayJobsSessions].statistics.bottleneck")
    
    if [[ $creationTimeUnix < $reportDateFrom ]]; then
        break
    else      
#Generating HTML file
html="$reportPath/Microsoft365-Job-Report-$SessionPolicyName-$reportDatePath.html"
echo '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">' >> $html
echo "<html>" >> $html
echo "<body>" >> $html
echo '<table style="border-collapse: collapse; transform-origin: left top 0px;" min-scale="0.6182495344506518" width="100%" cellspacing="0" cellpadding="0" border="0">' >> $html
echo "<tbody>" >> $html
echo "<tr>" >> $html
echo '<td style="border:none; padding:0px; font-family:Tahoma; font-size:$fontsize2">' >> $html
echo '<table style="border-collapse:collapse" width="100%" cellspacing="0" cellpadding="0" border="0">' >> $html
echo "<tbody>" >> $html
echo '<tr style="height:70px">' >> $html
echo "<td colspan="4" style='width:80%; border:none; background-color:$bcolor; color:White; font-weight:bold; font-size:$fontsize1; height:70px; vertical-align:bottom; padding:0 0 17px 15px; font-family:Tahoma'>Backup job: $SessionPolicyName" >> $html
echo '<div class="x_jobDescription" style="margin-top:5px; font-size:$fontsize2">Veeam Backup for Microsoft Office 365</div>' >> $html
echo "</td>" >> $html
echo "<td colspan="2" style='border:none; padding:0px; font-family:Tahoma; font-size:$fontsize2; background-color:$bcolor; color:White; font-weight:bold; font-size:$fontsize1; height:70px; vertical-align:bottom; padding:0 0 17px 15px; font-family:Tahoma'>$SessionStatus" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo "<tr>" >> $html
echo '<td colspan="6" style="border:none; padding:0px; font-family:Tahoma; font-size:$fontsize2"' >> $html
echo '<table class="x_inner" style="margin:0px; border-collapse:collapse" width="100%" cellspacing="0" cellpadding="0" border="0">' >> $html
echo "<tbody>" >> $html
echo '<tr style="height:17px">' >> $html
echo "<td colspan='6' class='_sessionDetails' style='border-style:solid; border-color:$color1; border-width:1px 1px 0 1px; height:35px; background-color:$color2; font-size:$fontsize3; vertical-align:middle; padding:5px 0 0 15px; color:$color3; font-family:Tahoma'>" >> $html
echo "<span>$creationTimeP</span>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo '<tr style="height:17px">' >> $html
echo "<td colspan="4" style='width:85px; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Start time</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="2" style='width:85px; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$creationTimeB</td>" >> $html
echo "<td >" >> $html
echo "<span </span>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo "<tr style='height:17px'>" >> $html
echo "<td colspan="4" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>End time</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="2 "style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$endTimeB</td>" >> $html
echo "</tr>" >> $html
echo "<tr style='height:17px'>" >> $html
echo "<td colspan="4" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Duration</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="2" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$totalDurationB</td>" >> $html
echo "</tr>" >> $html

echo "<tr style='height:17px'>" >> $html
echo "<td colspan="1" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Processing Rate</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="1" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$processingRateP KB/s</td>" >> $html
echo "<td colspan="2" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Read Rate</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="2" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$readRateP KB/s</td>" >> $html
echo "</tr>" >> $html
echo "<tr style='height:17px'>" >> $html
echo "<td colspan="1" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Write Rate</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="1" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$writeRateP KB/s</td>" >> $html
echo "<td colspan="2" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Transferred Data</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="2" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$transferredDataP KB</td>" >> $html
echo "</tr>" >> $html
echo "<tr style='height:17px'>" >> $html
echo "<td colspan="1" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Processed Objects</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="1" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$processedObjects</td>" >> $html
echo "<td colspan="2" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Bottleneck</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="2" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$bottleneck</td>" >> $html
echo "</tr>" >> $html
echo "<tr style='height:17px'>" >> $html
echo "<td colspan='6' style='height:35px; background-color:$color2; font-size:$fontsize1; vertical-align:middle; padding:5px 0 0 15px; color:$color3; font-family:Tahoma; border:1px solid $color1' nowrap="">" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo "</tbody>" >> $html
echo "</table>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo "<tr>" >> $html
echo "<td>&nbsp;</td>" >> $html
echo "</tr>" >> $html

        arrayJobsSessions=$arrayJobsSessions+1
    fi
    done
    

echo "<tr>" >> $html
echo "<td style='font-size:$fontsize2; color:$color3; padding:2px 3px 2px 3px; vertical-align:top; font-family:Tahoma'>Veeam Backup for Microsoft 365 - Hostname: $veeamRestServer</td>" >> $html
echo "</tr>" >> $html
echo "</tbody>" >> $html
echo "</table>" >> $html
echo "<br/>" >> $html
echo "<br/>" >> $html
echo "</body>" >> $html
echo "</html>" >> $html
#Sending Email to the user
cat $html | s-nail -M "text/html" -s "$veeamRestServer - Backup Job: $SessionPolicyName - Daily Veeam Backup for Microsoft 365 Report" $email_add
    arrayJobs=$arrayJobs+1
done



