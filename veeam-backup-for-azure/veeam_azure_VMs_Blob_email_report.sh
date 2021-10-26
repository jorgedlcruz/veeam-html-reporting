#!/bin/bash
##      .SYNOPSIS
##      HTML Report to consume easily via EMAIL, or from the Report Directory
## 
##      .DESCRIPTION
##      This Script will query the Veeam Backup for Azure API and save the job sessions stats for the last 24 hours. Then it saves it into a comfortable HTML, and it is sent over EMAIL
##      The Script it is provided as it is, and bear in mind you can not open support Tickets regarding this project. It is a Community Project
##	
##      .Notes
##      NAME:  veeam_azure_VMs_Blob_email_report.sh
##      ORIGINAL NAME: veeam_azure_VMs_Blob_email_report.sh
##      LASTEDIT: 26/10/2021
##      VERSION: 3.0
##      KEYWORDS: Veeam, HTML, Report, Azure
   
##      .Link
##      https://jorgedelacruz.es/
##      https://jorgedelacruz.uk/

# Configurations
##
# Endpoint URL for login action
veeamUsername="YOURVEEAMBACKUPUSER"
veeamPassword="YOURVEEAMBACKUPPASS"
veeamBackupAzureServer="https://YOURVEEAMBACKUPIP"
veeamBackupAzurePort="443" #Default Port


## System Variables
reportDate=$(date "+%A, %B %d, %Y %r")
reportDatePath=$(date "+%A%B%d%Y")
reportDateTo=$(date "+%Y-%m-%d")
reportDateFrom=$(date -d "$reportDateTo - 1 day" '+%Y-%m-%d')
reportPath="/home/oper/vba_azure_reports"
html="$reportPath/Azure-VMs-Blob-Job-Report-$reportDatePath.html"
email_add="CHANGETHISWITHYOUREMAIL"
bcolor="#006DBC"
color1="#a7a9ac"
color2="#f3f4f4"
color3="#626365"
color4="#e3e3e3"
fontsize1="20px"
fontsize2="20px"
fontsize3="22px"

## Login and Token
veeamBearer=$(curl -X POST --header "Content-Type: application/x-www-form-urlencoded" --header "Accept: application/json" -d "Username=$veeamUsername&Password=$veeamPassword&refresh_token=&grant_type=Password&mfa_token=&mfa_code=" "$veeamBackupAzureServer:$veeamBackupAzurePort/api/oauth2/token" -k --silent | jq -r '.access_token')


##
# Veeam Backup for Azure Overview. This part will check VBA Overview
##
veeamVBAURL="$veeamBackupAzureServer:$veeamBackupAzurePort/api/v2/system/about"
veeamVBAOverviewUrl=$(curl -X GET $veeamVBAURL -H "Authorization: Bearer $veeamBearer" -H  "accept: application/json" 2>&1 -k --silent)

    version=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".serverVersion")
    workerversion=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".workerVersion")

veeamVBAURL="$veeamBackupAzureServer:$veeamBackupAzurePort/api/v2/system/serverInfo"
veeamVBAOverviewUrl=$(curl -X GET $veeamVBAURL -H "Authorization: Bearer $veeamBearer" -H  "accept: application/json" 2>&1 -k --silent)

    serverName=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".serverName")
    azureRegion=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".azureRegion")

##
# Veeam Backup for Azure Protected VMs. This part will check Protected VMs, and the consumed space
##
veeamVBAURL="$veeamBackupAzureServer:$veeamBackupAzurePort/api/v3/virtualMachines?ProtectionStatus=Protected&BackupDestination=AzureBlob"
veeamVBAProtectedVMsUrl=$(curl -X GET $veeamVBAURL -H "Authorization: Bearer $veeamBearer" -H  "accept: application/json" 2>&1 -k --silent)

declare -i arrayvms=0
for row in $(echo "$veeamVBAProtectedVMsUrl" | jq -r '.results[].id'); do
    ProtectedVMID=$(echo "$veeamVBAProtectedVMsUrl" | jq --raw-output ".results[$arrayvms].id")
    ProtectedVMName=$(echo "$veeamVBAProtectedVMsUrl" | jq --raw-output ".results[$arrayvms].name")    
    ProtectedVMosType=$(echo "$veeamVBAProtectedVMsUrl" | jq --raw-output ".results[$arrayvms].osType")    
    ProtectedVMregionName=$(echo "$veeamVBAProtectedVMsUrl" | jq --raw-output ".results[$arrayvms].regionName")    
    ProtectedVMprivateIP=$(echo "$veeamVBAProtectedVMsUrl" | jq --raw-output ".results[$arrayvms].privateIP")
    
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
echo "<td colspan="2" style='width:80%; border:none; background-color:$bcolor; color:White; font-weight:bold; font-size:$fontsize1; height:70px; vertical-align:bottom; padding:0 0 17px 15px; font-family:Tahoma'>$ProtectedVMName | OS: $ProtectedVMosType | Region: $ProtectedVMregionName" >> $html
echo '<div class="x_jobDescription" style="margin-top:5px; font-size:$fontsize2"></div>' >> $html
echo "</td>" >> $html
echo "<td colspan="2" style='border:none; padding:0px; font-family:Tahoma; font-size:$fontsize2; background-color:$bcolor; color:White; font-weight:bold; font-size:$fontsize1; height:70px; vertical-align:bottom; padding:0 0 17px 15px; font-family:Tahoma'>PrivateIP: $ProtectedVMprivateIP" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html


    # Protected VM Points
    veeamVBAURL="$veeamBackupAzureServer:$veeamBackupAzurePort/api/v3/restorePoints?VirtualMachineId=$ProtectedVMID"
    veeamVBAVMPointUrl=$(curl -X GET --header "Accept:application/json" --header "Authorization:Bearer $veeamBearer" "$veeamVBAURL" 2>&1 -k --silent)

echo "<tr style='height:17px'>" >> $html
echo "<td colspan='4' style='height:35px; background-color:$color2; font-size:$fontsize1; vertical-align:middle; padding:5px 0 0 15px; color:$color3; font-family:Tahoma; border:1px solid $color1' nowrap="">" >> $html
echo "<b>Details</b>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo '<tr class="x_processObjectsHeader" style="height:23px">' >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>Backup Type</b>" >> $html
echo "</td>" >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>GFS Type</b>" >> $html
echo "</td>" >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>Backup Size</b>" >> $html
echo "</td>" >> $html
echo "<td style='background-color:$color4; padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; border-top:none; font-family:Tahoma; font-size:$fontsize1' nowrap="">" >> $html
echo "<b>Date</b>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
    declare -i arrayvmspoints=0
    declare -i ProtectedVMBackupSizeTotal=0
    for id in $(echo "$veeamVBAVMPointUrl" | jq -r '.results[].id'); do
        ProtectedVMBackupDestination=$(echo "$veeamVBAVMPointUrl" | jq --raw-output ".results[$arrayvmspoints].backupDestination")
        if [ "$ProtectedVMBackupDestination" == "AzureBlob" ]; then
            ProtectedVMBackupType=$(echo "$veeamVBAVMPointUrl" | jq --raw-output ".results[$arrayvmspoints].type")
            ProtectedVMBackupDate=$(echo "$veeamVBAVMPointUrl" | jq --raw-output ".results[$arrayvmspoints].pointInTime")
            ProtectedVMBackupSizeBytes=$(echo "$veeamVBAVMPointUrl" | jq --raw-output ".results[$arrayvmspoints].backupSizeBytes")
            ProtectedVMBackupSizeGiB=$(echo $ProtectedVMBackupSizeBytes | awk '{split("Byt,KiB,MiB,GiB,TiB", unit, ","); (size=$1) ? level=sprintf("%.0d", (log(size)/log(1024))) : level=0; printf "%.2f %s\n", size/(1024**level), unit[level+1]}')
            ProtectedVMBackupGFS=$(echo "$veeamVBAVMPointUrl" | jq --raw-output ".results[$arrayvmspoints].gfsFlags")
            echo '<tr style="height:17px">' >> $html
			echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$ProtectedVMBackupType</td>" >> $html
            echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$ProtectedVMBackupGFS</td>" >> $html
			echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$ProtectedVMBackupSizeGiB</td>" >> $html
			echo "<td style='padding:2px 3px 2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap="">$ProtectedVMBackupDate</td>" >> $html
			echo "</tr>" >> $html
        fi
            arrayvmspoints=$arrayvmspoints+1
            ProtectedVMBackupSizeTotal=$(($ProtectedVMBackupSizeBytes + $ProtectedVMBackupSizeTotal))
            ProtectedVMBackupSizeTotalGiB=$(echo $ProtectedVMBackupSizeTotal | awk '{split("Byt,KiB,MiB,GiB,TiB", unit, ","); (size=$1) ? level=sprintf("%.0d", (log(size)/log(1024))) : level=0; printf "%.2f %s\n", size/(1024**level), unit[level+1]}')
    done
    echo "<td colspan='4' style='height:35px; background-color:$color2; font-size:$fontsize1; vertical-align:middle; padding:5px 0 0 15px; color:$color3; font-family:Tahoma; border:1px solid $color1' nowrap="">" >> $html
    echo "<b>Total Blob Consumed: $ProtectedVMBackupSizeTotalGiB </b>" >> $html
    echo "</td>" >> $html
    
echo "</tbody>" >> $html
echo "</table>" >> $html
echo "</td>" >> $html
echo "</tr>" >> $html
echo "</tbody>" >> $html
echo "</table>" >> $html
echo "<br/>" >> $html
echo "<br/>" >> $html
arrayvms=$arrayvms+1
done
echo "<p style='font-size:$fontsize2; color:$color3; padding:2px 3px 2px 3px; vertical-align:top; font-family:Tahoma'>Veeam Backup for Azure - Hostname: $serverName Version: $version - Azure Region: $azureRegion</p>" >> $html

#Sending Email to the user
cat $html | s-nail -M "text/html" -s "$veeamBackupAzureServer - Daily Veeam Backup for Azure Report" $email_add

