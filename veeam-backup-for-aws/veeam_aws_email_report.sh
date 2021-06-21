#!/bin/bash
##      .SYNOPSIS
##      HTML Report to consume easily via EMAIL, or from the Report Directory
## 
##      .DESCRIPTION
##      This Script will query the Veeam Backup for AWS API and save the job sessions stats for the last 24 hours. Then it saves it into a comfortable HTML, and it is sent over EMAIL
##      The Script it is provided as it is, and bear in mind you can not open support Tickets regarding this project. It is a Community Project
##	
##      .Notes
##      NAME:  veeam_aws_email_report.sh
##      ORIGINAL NAME: veeam_aws_email_report.sh
##      LASTEDIT: 11/06/2021
##      VERSION: 1.0
##      KEYWORDS: Veeam, HTML, Report, AWS
   
##      .Link
##      https://jorgedelacruz.es/
##      https://jorgedelacruz.uk/

# Configurations
##
# Endpoint URL for login action
veeamUsername="YOURVEEAMBACKUPUSER"
veeamPassword="YOURVEEAMBACKUPPASS"
veeamBackupAWSServer="https://YOURVEEAMBACKUPFORAWSIP"
veeamBackupAWSPort="11005" #Default Port


## System Variables
reportDate=$(date "+%A, %B %d, %Y %r")
reportDatePath=$(date "+%A%B%d%Y")
reportDateTo=$(date "+%Y-%m-%d")
reportDateFrom=$(date -d "$reportDateTo - 1 day" '+%Y-%m-%d')
reportPath="/home/oper/vba_aws_reports"
html="$reportPath/AWS-Job-Report-$reportDatePath.html"
email_add="CHANGETHISWITHYOUREMAIL"
color1="#a7a9ac"
color2="#f3f4f4"
color3="#626365"
color4="#e3e3e3"
fontsize1="20px"
fontsize2="20px"
fontsize3="22px"

## Login and Token

veeamBearer=$(curl -X POST --header "Content-Type: application/x-www-form-urlencoded" --header "Accept: application/json" --header "x-api-version: 1.1-rev0" -d "username=$veeamUsername&password=$veeamPassword&grant_type=password" "$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/token" -k --silent | jq -r '.access_token')


##
# Veeam Backup for AWS Overview. This part will check VBA Overview
##
veeamVBAURL="$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/system/version"
veeamVBAOverviewUrl=$(curl -X GET $veeamVBAURL -H "Authorization: Bearer $veeamBearer" -H -H "x-api-version: 1.1-rev0" "accept: application/json" 2>&1 -k --silent)

    version=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".version" |awk '{$1=$1};1')
    
veeamVBAURL="$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/statistics/summary"
veeamVBAOverviewUrl=$(curl -X GET $veeamVBAURL -H "Authorization: Bearer $veeamBearer" -H -H "x-api-version: 1.1-rev0" "accept: application/json" 2>&1 -k --silent)

    VMsCount=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".instancesCount")
    VMsProtected=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".protectedInstancesCount")
    PoliciesCount=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".policiesCount")
    RepositoriesCount=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".repositoriesCount")

##
# Veeam Backup for AWS EC2 Sessions. This part will check VBA Sessions for EC2 Backup Jobs
##
veeamVBAURL="$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/sessions?Types=Policy&FromUtc=$reportDateFrom&ToUtc=$reportDateTo"
veeamVBASessionsBackupUrl=$(curl -X GET $veeamVBAURL -H "Authorization: Bearer $veeamBearer" -H "x-api-version: 1.1-rev0" -H  "accept: application/json" 2>&1 -k --silent)

declare -i arraysessionsbackup=0
for id in $(echo "$veeamVBASessionsBackupUrl" | jq -r '.results[].id'); do
    SessionID=$(echo "$veeamVBASessionsBackupUrl" | jq --raw-output ".results[$arraysessionsbackup].id")
    SessionStatus=$(echo "$veeamVBASessionsBackupUrl" | jq --raw-output ".results[$arraysessionsbackup].result")
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
    SessionExtendedType=$(echo "$veeamVBASessionsBackupUrl" | jq --raw-output ".results[$arraysessionsbackup].extendedSessionType")
        case $SessionExtendedType in
            PolicyBackup)
                SessionType="EC2 Policy Backup"
            ;;
            PolicySnapshot)
                SessionType="EC2 Policy Snapshot"
            ;;  
            VpcBackup)
                SessionType="VPC Backup"        
            ;;
            PolicyRdsSnapshot)
                SessionType="RDS Policy Snapshot"

        esac    
    SessionDurationM=$(echo "$veeamVBASessionsBackupUrl" | jq --raw-output ".results[$arraysessionsbackup].executionDuration")
    SessionLogDurationS=$(echo $(($SessionDurationM/1000)))
    SessionDurationB=$(echo $(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))/3600))h:$(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))%3600/60))m:$(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))%60))s)
    SessionStartTime=$(echo "$veeamVBASessionsBackupUrl" | jq --raw-output ".results[$arraysessionsbackup].executionStartTime")
    SessionStartTimeB=$(date -d $SessionStartTime '+%r')
    SessionStopTime=$(echo "$veeamVBASessionsBackupUrl" | jq --raw-output ".results[$arraysessionsbackup].executionStopTime")
    SessionStopTimeB=$(date -d $SessionStopTime '+%r')
    SessionPolicyID=$(echo "$veeamVBASessionsBackupUrl" | jq --raw-output ".results[$arraysessionsbackup].id")
    
    ##
    # Workaround for Policy Name
    #
    veeamBearerInt=$(curl -X POST --header "Content-Type: application/x-www-form-urlencoded" --header "Accept: application/json" --header "x-api-version: 1.0-rev3" -d "username=$veeamUsername&password=$veeamPassword&grant_type=password" "$veeamBackupAWSServer/api/oauth2/token" -k --silent | jq -r '.access_token')
    veeamVBAURL="$veeamBackupAWSServer/api/v1/sessions/$SessionID"
    veeamVBASessionName=$(curl -X GET $veeamVBAURL -H "Authorization: Bearer $veeamBearerInt" -H "x-api-version: 1.0-rev3" -H  "accept: application/json" 2>&1 -k --silent)
    SessionPolicyName=$(echo "$veeamVBASessionName" | jq --raw-output ".name")
    
    ##
    # Veeam Backup for AWS Detailed Sessions. This part will check the Instances inside the Session
    ##
    veeamVBAURL="$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/sessions/$SessionID/log"
    veeamVBASessionsLogBackupUrl=$(curl -X GET $veeamVBAURL -H "Authorization: Bearer $veeamBearer" -H "x-api-version: 1.1-rev0" -H  "accept: application/json" 2>&1 -k --silent)


#Generating HTML file
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
echo "<td colspan="4" style='width:80%; border:none; background-color:$bcolor; color:White; font-weight:bold; font-size:$fontsize1; height:70px; vertical-align:bottom; padding:0 0 17px 15px; font-family:Tahoma'>$SessionType: $SessionPolicyName" >> $html
echo '<div class="x_jobDescription" style="margin-top:5px; font-size:$fontsize2"></div>' >> $html
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
echo "<span>$reportDate</span>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo '<tr style="height:17px">' >> $html
echo "<td colspan="4" style='width:85px; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Start time</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="2" style='width:85px; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$SessionStartTimeB</td>" >> $html
echo "<td >" >> $html
echo "<span </span>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo "<tr style='height:17px'>" >> $html
echo "<td colspan="4" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>End time</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="2 "style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$SessionStopTimeB</td>" >> $html
echo "</tr>" >> $html
echo "<tr style='height:17px'>" >> $html
echo "<td colspan="4" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">" >> $html
echo "<b>Duration</b>" >> $html
echo "</td>" >> $html
echo "<td colspan="2" style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize2' nowrap="">$SessionDurationB</td>" >> $html
echo "</tr>" >> $html
echo "<tr style='height:17px'>" >> $html
echo "<td colspan='6' style='height:35px; background-color:$color2; font-size:$fontsize1; vertical-align:middle; padding:5px 0 0 15px; color:$color3; font-family:Tahoma; border:1px solid $color1' nowrap="">" >> $html
echo "<b>Details</b>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo '<tr class="x_processObjectsHeader" style="height:23px">' >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>Name</b>" >> $html
echo "</td>" >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>Job Type</b>" >> $html
echo "</td>" >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>Status</b>" >> $html
echo "</td>" >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>Start time</b>" >> $html
echo "</td>" >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>Transferred</b>" >> $html
echo "</td>" >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>Duration</b>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html

    declare -i arraysessionslogbackup=0
    for row in $(echo "$veeamVBASessionsLogBackupUrl" | jq -r '.log[].logTime'); do
        SessionLogStatus=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].status")
        case $SessionLogStatus in
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
        
        case $SessionExtendedType in
            PolicyBackup)
                SessionLogMessage=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].message")
                case $SessionLogMessage in
                Processing*)
                    SessionLogWorkloadName=$(echo $SessionLogMessage |awk '{print $2}' | sed 's/.$//')
                    SessionLogWorkloadTransferred=$(echo $SessionLogMessage | awk -F %, '{print $2}')
                    SessionLogWorkloadType="EC2 Backup"
                    SessionLogStartTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].executionStartTime")
                    SessionLogStoptTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].logTime")
                    SessionLogDurationS=$(echo $(( $(date -d "$SessionLogStoptTime" "+%s") - $(date -d "$SessionLogStartTime" "+%s") )))
                    SessionLogDurationB=$(echo $(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))/3600))h:$(($(($SessionLogDurationS  -$SessionLogDurationS/86400*86400))%3600/60))m:$(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))%60))s)
                    SessionLogStart=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].executionStartTime")
                    SessionLogStartB=$(date -d $SessionLogStart '+%r')
                    
                        echo '<tr style="height:17px">' >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadName</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadType</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
                        echo "<span style="color:$bcolor">$SessionLogStatus</span>" >> $html
                        echo "</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogStartB</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadTransferred</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogDurationB</td>" >> $html
                        echo "</tr>" >> $html
                ;;
                esac
            ;;
            PolicySnapshot)
                SessionLogMessage=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].message")
                case $SessionLogMessage in
                Processing*)
                    SessionLogWorkloadName=$(echo $SessionLogMessage |awk '{print $2}' | sed 's/.$//')
                    SessionLogWorkloadTransferred="N/A"
                    SessionLogWorkloadType="EC2 Snapshot"
                    SessionLogStartTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].executionStartTime")
                    SessionLogStoptTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].logTime")
                    SessionLogDurationS=$(echo $(( $(date -d "$SessionLogStoptTime" "+%s") - $(date -d "$SessionLogStartTime" "+%s") )))
                    SessionLogDurationB=$(echo $(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))/3600))h:$(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))%3600/60))m:$(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))%60))s)
                    SessionLogStart=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].executionStartTime")
                    SessionLogStartB=$(date -d $SessionLogStart '+%r')

                        echo '<tr style="height:17px">' >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadName</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadType</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
                        echo "<span style="color:$bcolor">$SessionLogStatus</span>" >> $html
                        echo "</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogStartB</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadTransferred</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogDurationB</td>" >> $html
                        echo "</tr>" >> $html
                ;;
                esac
            ;;  
            VpcBackup)
                SessionLogMessage=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].message")
                case $SessionLogMessage in
                Performing*)                
                    SessionLogWorkloadName=$(echo $SessionLogMessage |awk '{print $5" "$6" "$7" - AWS Account "$12}')
                    SessionLogWorkloadTransferred="N/A"
                    SessionLogWorkloadType="VPC Backup"
                    SessionLogStartTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].executionStartTime")
                    SessionLogStoptTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].logTime")
                    SessionLogDurationS=$(echo $(( $(date -d "$SessionLogStoptTime" "+%s") - $(date -d "$SessionLogStartTime" "+%s") )))
                    SessionLogDurationB=$(echo $(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))/3600))h:$(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))%3600/60))m:$(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))%60))s)
                    SessionLogStart=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].executionStartTime")
                    SessionLogStartB=$(date -d $SessionLogStart '+%r')

                        echo '<tr style="height:17px">' >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadName</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadType</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
                        echo "<span style="color:$bcolor">$SessionLogStatus</span>" >> $html
                        echo "</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogStartB</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadTransferred</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogDurationB</td>" >> $html
                        echo "</tr>" >> $html
                ;;
                esac                    
            ;;
            PolicyRdsSnapshot)
                SessionLogMessage=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].message")
                case $SessionLogMessage in
                Processing*)
                    SessionLogWorkloadName=$(echo $SessionLogMessage |awk '{print $2}' | sed 's/.$//')
                    SessionLogWorkloadTransferred="N/A"
                    SessionLogWorkloadType="RDS Snapshot"
                    SessionLogStartTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].executionStartTime")
                    SessionLogStoptTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].logTime")
                    SessionLogDurationS=$(echo $(( $(date -d "$SessionLogStoptTime" "+%s") - $(date -d "$SessionLogStartTime" "+%s") )))
                    SessionLogDurationB=$(echo $(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))/3600))h:$(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))%3600/60))m:$(($(($SessionLogDurationS - $SessionLogDurationS/86400*86400))%60))s)
                    SessionLogStart=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].executionStartTime")
                    SessionLogStartB=$(date -d $SessionLogStart '+%r')
                        echo '<tr style="height:17px">' >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadName</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadType</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
                        echo "<span style="color:$bcolor">$SessionLogStatus</span>" >> $html
                        echo "</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogStartB</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogWorkloadTransferred</td>" >> $html
                        echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$SessionLogDurationB</td>" >> $html
                        echo "</tr>" >> $html
                ;;
                esac 
            ;;
        esac
        
            arraysessionslogbackup=$arraysessionslogbackup+1
    done

echo "</tbody>" >> $html
echo "</table>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo "<tr>" >> $html
echo "<td>&nbsp;</td>" >> $html
echo "</tr>" >> $html
echo "<tr>" >> $html
echo "<td style='font-size:$fontsize2; color:$color3; padding:2px 3px 2px 3px; vertical-align:top; font-family:Tahoma'>Veeam Backup for AWS - Hostname: $veeamBackupAWSServer Version: $version</td>" >> $html
echo "</tr>" >> $html
echo "</tbody>" >> $html
echo "</table>" >> $html
echo "<br/>" >> $html
echo "<br/>" >> $html

    arraysessionsbackup=$arraysessionsbackup+1
done

#Sending Email to the user
cat $html | s-nail -M "text/html" -s "$veeamBackupAWSServer - Daily Veeam Backup for AWS Report" $email_add

