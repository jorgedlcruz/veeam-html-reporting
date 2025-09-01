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
##      LASTEDIT: 01/09/2025
##      VERSION: 9.0
##      KEYWORDS: Veeam, HTML, Report, AWS

##      .Link
##      https://jorgedelacruz.es/
##      https://jorgedelacruz.uk/

# Configurations
veeamUsername="YOURVEEAMBACKUPUSER"
veeamPassword="YOURVEEAMBACKUPPASS"
veeamBackupAWSServer="https://YOURVEEAMBACKUPFORAWSIP"
veeamBackupAWSPort="11005" #Default Port
apiVersion="1.7-rev0"

# Optional: filter sessions by extendedSessionType (regex). Empty = show all.
# Examples:
#   filterExtendedTypes="PolicyBackup,PolicySnapshot"
#   filterExtendedTypes="VpcBackup"
#   filterExtendedTypes=""     # no filtering
filterExtendedTypes="PolicyBackup,PolicySnapshot"

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

echo "[INFO] Using API version: $apiVersion"
echo "[INFO] Report window: $reportDateFrom to $reportDateTo"
mkdir -p "$reportPath"

## Login and Token
echo "[INFO] Step 1: Requesting bearer token..."
veeamBearer=$(curl -X POST \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --header "Accept: application/json" \
  --header "x-api-version: $apiVersion" \
  -d "username=$veeamUsername&password=$veeamPassword&grant_type=password" \
  "$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/token" -k --silent | jq -r '.access_token')

if [ -z "$veeamBearer" ] || [ "$veeamBearer" = "null" ]; then
  echo "[ERROR] Did not receive access_token. Check credentials, server, port, or x-api-version."
  exit 1
fi
echo "[OK] Token received (length: ${#veeamBearer})."

##
# Veeam Backup for AWS Overview. This part will check VBA Overview
##
echo "[INFO] Step 2: Getting system version..."
veeamVBAURL="$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/system/version"
veeamVBAOverviewUrl=$(curl -X GET "$veeamVBAURL" \
  -H "Authorization: Bearer $veeamBearer" \
  -H "x-api-version: $apiVersion" \
  -H "accept: application/json" 2>&1 -k --silent)
version=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".version" | awk '{$1=$1};1')
echo "[OK] Appliance version: $version"

# FIX: the previous script called system/version twice and then tried to read summary fields.
# The next call must be statistics/summary to get instances/policies/repositories counts.
echo "[INFO] Step 3: Getting statistics summary..."
veeamVBAURL="$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/statistics/summary"
veeamVBAOverviewUrl=$(curl -X GET "$veeamVBAURL" \
  -H "Authorization: Bearer $veeamBearer" \
  -H "x-api-version: $apiVersion" \
  -H "accept: application/json" 2>&1 -k --silent)
VMsCount=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".instancesCount")
VMsProtected=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".protectedInstancesCount")
PoliciesCount=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".policiesCount")
RepositoriesCount=$(echo "$veeamVBAOverviewUrl" | jq --raw-output ".repositoriesCount")
echo "[OK] Summary: instances=$VMsCount protected=$VMsProtected policies=$PoliciesCount repositories=$RepositoriesCount"

##
# Veeam Backup for AWS EC2 Sessions. This part will check VBA Sessions for EC2 Backup Jobs
##
echo "[INFO] Step 4: Listing sessions in window..."
veeamVBAURL="$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/sessions?Types=Policy&FromUtc=$reportDateFrom&ToUtc=$reportDateTo"
veeamVBASessionsBackupUrl=$(curl -X GET "$veeamVBAURL" \
  -H "Authorization: Bearer $veeamBearer" \
  -H "x-api-version: $apiVersion" \
  -H "accept: application/json" 2>&1 -k --silent)

rx=$(echo "$filterExtendedTypes" | tr -d ' ' | sed 's/,/|/g')

if [ -n "$rx" ]; then
  echo "[INFO] Applying extendedSessionType filter: $filterExtendedTypes"
  sessionsFiltered=$(echo "$veeamVBASessionsBackupUrl" | \
    jq --arg rx "^($rx)$" '[.results[] | select(.extendedSessionType | test($rx))]')
else
  echo "[INFO] No extendedSessionType filter (showing all)."
  sessionsFiltered=$(echo "$veeamVBASessionsBackupUrl" | jq '[.results[]]')
fi

sessionsTotal=$(echo "$sessionsFiltered" | jq 'length')
echo "[OK] Found $sessionsTotal session(s) after filter."

# Optional: quick breakdown by type (nice for clarity in console)
echo "$sessionsFiltered" | jq -r '
  group_by(.extendedSessionType)
  | map({type: .[0].extendedSessionType, count: length})[]
  | "[INFO]  " + .type + ": " + (.count|tostring)
'

#Generating HTML file
echo "[INFO] Step 5: Building HTML: $html"
echo '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">' > "$html"
echo "<html>" >> "$html"
echo "<body>" >> "$html"
echo "<h3>Filter: extendedSessionType = ${filterExtendedTypes:-ALL}</h3>" >> "$html"


declare -i processed=0

for ((i=0; i<sessionsTotal; i++)); do
    SessionID=$(echo "$sessionsFiltered" | jq -r ".[$i].id")
    processed=$((processed+1))
    echo "[INFO] Processing session $processed/$sessionsTotal (id=$SessionID)"

    SessionPolicyName=$(echo "$sessionsFiltered" | jq -r ".[$i].name")
    SessionStatus=$(echo "$sessionsFiltered" | jq -r ".[$i].result")
    SessionExtendedType=$(echo "$sessionsFiltered" | jq -r ".[$i].extendedSessionType")

    case $SessionStatus in
      Success) bcolor="#54B948" ;;
      Warning) bcolor="#F2C973" ;;
      Failed|Error) bcolor="#E8595A" ;;
      *) bcolor="#626365" ;;
    esac

    case $SessionExtendedType in
      PolicyBackup)       SessionType="EC2 Policy Backup" ;;
      PolicySnapshot)     SessionType="EC2 Policy Snapshot" ;;
      VpcBackup)          SessionType="VPC Backup" ;;
      PolicyRdsSnapshot)  SessionType="RDS Policy Snapshot" ;;
      *)                  SessionType="$SessionExtendedType" ;;
    esac

    SessionDurationM=$(echo "$sessionsFiltered" | jq -r ".[$i].executionDuration")
    SessionLogDurationS=$((SessionDurationM/1000))
    SessionDurationB=$(( (SessionLogDurationS - SessionLogDurationS/86400*86400)/3600 ))h:$(( (SessionLogDurationS - SessionLogDurationS/86400*86400)%3600/60 ))m:$(( (SessionLogDurationS - SessionLogDurationS/86400*86400)%60 ))s
    SessionStartTime=$(echo "$sessionsFiltered" | jq -r ".[$i].executionStartTime")
    SessionStartTimeB=$(date -d "$SessionStartTime" '+%r')
    SessionStopTime=$(echo "$sessionsFiltered" | jq -r ".[$i].executionStopTime")
    SessionStopTimeB=$(date -d "$SessionStopTime" '+%r')

    echo "[INFO] Fetching session log for $SessionID"
    veeamVBAURL="$veeamBackupAWSServer:$veeamBackupAWSPort/api/v1/sessions/$SessionID/log"
    veeamVBASessionsLogBackupUrl=$(curl -X GET "$veeamVBAURL" \
      -H "Authorization: Bearer $veeamBearer" \
      -H "x-api-version: $apiVersion" \
      -H "accept: application/json" 2>&1 -k --silent)

    # Session header HTML
    echo '<table style="border-collapse: collapse; transform-origin: left top 0px;" min-scale="0.6182495344506518" width="100%" cellspacing="0" cellpadding="0" border="0">' >> "$html"
    echo "<tbody>" >> "$html"
    echo "<tr>" >> "$html"
    echo "<td style='border:none; padding:0px; font-family:Tahoma; font-size:$fontsize2'>" >> "$html"
    echo '<table style="border-collapse:collapse" width="100%" cellspacing="0" cellpadding="0" border="0">' >> "$html"
    echo "<tbody>" >> "$html"
    echo '<tr style="height:70px">' >> "$html"
    echo "<td colspan=\"4\" style='width:80%; border:none; background-color:$bcolor; color:White; font-weight:bold; font-size:$fontsize1; height:70px; vertical-align:bottom; padding:0 0 17px 15px; font-family:Tahoma'>$SessionType: $SessionPolicyName" >> "$html"
    echo "<div class='x_jobDescription' style='margin-top:5px; font-size:$fontsize2'></div>" >> "$html"
    echo "</td>" >> "$html"
    echo "<td colspan=\"2\" style='border:none; padding:0px; background-color:$bcolor; color:White; font-weight:bold; font-size:$fontsize1; height:70px; vertical-align:bottom; padding:0 0 17px 15px'>$SessionStatus" >> "$html"
    echo "</td>" >> "$html"
    echo "</tr>" >> "$html"
    echo "<tr>" >> "$html"
    echo "<td colspan=\"6\" style='border:none; padding:0px; font-family:Tahoma; font-size:$fontsize2'>" >> "$html"
    echo '<table class="x_inner" style="margin:0px; border-collapse:collapse" width="100%" cellspacing="0" cellpadding="0" border="0">' >> "$html"

    declare -i arraysessionslogbackup=0
    printed_rows=0
    worst_status="Success"
    summary_msg=""
    summary_time=""

    for row in $(echo "$veeamVBASessionsLogBackupUrl" | jq -r '.log[].logTime'); do
        SessionLogMessage=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].message")
        SessionLogStatus=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].status")
        case $SessionLogStatus in
            Success) bcolor="#54B948" ;;
            Warning) bcolor="#F2C973" ;;
            Failed|Error) bcolor="#E8595A" ;;
            *) bcolor="#626365" ;;
        esac

        # Track worst status + a representative message/time
        if [[ "$SessionLogStatus" = "Error" || "$SessionLogStatus" = "Failed" ]]; then
            worst_status="Error"
            [[ -z "$summary_msg"  ]] && summary_msg="$SessionLogMessage"
            [[ -z "$summary_time" ]] && summary_time=$(echo "$veeamVBASessionsLogBackupUrl" | jq -r ".log[$arraysessionslogbackup].logTime")
        elif [[ "$worst_status" != "Error" && "$SessionLogStatus" = "Warning" ]]; then
            worst_status="Warning"
            [[ -z "$summary_msg"  ]] && summary_msg="$SessionLogMessage"
            [[ -z "$summary_time" ]] && summary_time=$(echo "$veeamVBASessionsLogBackupUrl" | jq -r ".log[$arraysessionslogbackup].logTime")
        fi

        # Common times
        SessionLogStartTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].executionStartTime")
        SessionLogStoptTime=$(echo "$veeamVBASessionsLogBackupUrl" | jq --raw-output ".log[$arraysessionslogbackup].logTime")
        SessionLogDurationS=$(( $(date -d "$SessionLogStoptTime" "+%s") - $(date -d "$SessionLogStartTime" "+%s") ))
        SessionLogDurationB=$(( (SessionLogDurationS - SessionLogDurationS/86400*86400)/3600 ))h:$(( (SessionLogDurationS - SessionLogDurationS/86400*86400)%3600/60 ))m:$(( (SessionLogDurationS - SessionLogDurationS/86400*86400)%60 ))s
        SessionLogStartB=$(date -d "$SessionLogStartTime" '+%r')

        # Defaults
        SessionLogWorkloadName=""
        SessionLogWorkloadTransferred="N/A"
        SessionLogWorkloadType=""
        if [[ "$SessionLogMessage" == *"already protected by another policy:"* || \
            "$SessionLogMessage" == *"Already protected by another policy:"* || \
            "$SessionLogMessage" == "The resource is already protected by another policy:"* ]]; then

            # extract workload name after the colon
            SessionLogWorkloadName="${SessionLogMessage#*: }"
            # trim trailing spaces/periods if any
            SessionLogWorkloadName="${SessionLogWorkloadName%%[[:space:].]*}"

            # label as skipped based on session type
            case $SessionExtendedType in
                PolicyBackup)         SessionLogWorkloadType="EC2 Backup (skipped)";;
                PolicySnapshot)       SessionLogWorkloadType="EC2 Snapshot (skipped)";;
                PolicyRemoteSnapshot) SessionLogWorkloadType="EC2 Replica Snapshot (skipped)";;
                PolicyEfsBackup)      SessionLogWorkloadType="EFS Backup (skipped)";;
                PolicyEfsBackupCopy)  SessionLogWorkloadType="EFS Backup Copy (skipped)";;
                VpcBackup)            SessionLogWorkloadType="VPC Backup (skipped)";;
                *)                    SessionLogWorkloadType="Already protected (skipped)";;
            esac

            SessionLogWorkloadTransferred="N/A"
        fi

        case $SessionExtendedType in
            PolicyBackup)
                if [[ "$SessionLogMessage" == *": "*[Pp]"rocessing "* ]]; then
                    tmp="${SessionLogMessage#*: [Pp]rocessing }"
                    if [[ "$tmp" == *" - "* ]]; then
                        SessionLogWorkloadName="${tmp%% -*}"
                    else
                        SessionLogWorkloadName="${tmp%.}"
                    fi
                    if [[ "$SessionLogMessage" == *", "* ]]; then
                        t="${SessionLogMessage#*, }"
                        SessionLogWorkloadTransferred="${t% transferred*}"
                    fi
                    SessionLogWorkloadType="EC2 Backup"
                fi
            ;;
            PolicySnapshot|PolicyRemoteSnapshot)
                if [[ "$SessionLogMessage" == *": "*[Pp]"rocessing "* ]]; then
                    tmp="${SessionLogMessage#*: [Pp]rocessing }"
                    SessionLogWorkloadName="${tmp%.}"
                    SessionLogWorkloadType=$([[ "$SessionExtendedType" = "PolicySnapshot" ]] && echo "EC2 Snapshot" || echo "EC2 Replica Snapshot")
                fi
            ;;
            PolicyEfsBackup|PolicyEfsBackupCopy)
                if [[ "$SessionLogMessage" == *": "*[Pp]"rocessing "* ]]; then
                    tmp="${SessionLogMessage#*: [Pp]rocessing }"
                    SessionLogWorkloadName="${tmp%.}"
                    if [[ "$SessionExtendedType" = "PolicyEfsBackup" ]]; then
                        SessionLogWorkloadType="EFS Backup"
                    else
                        SessionLogWorkloadType="EFS Backup Copy"
                    fi
                fi
            ;;
            VpcBackup)
                if [[ "$SessionLogMessage" == [Pp]"erforming"* ]]; then
                    SessionLogWorkloadName="${SessionLogMessage#*[Pp]erforming }"
                    SessionLogWorkloadName="${SessionLogWorkloadName%.}"
                    SessionLogWorkloadType="VPC Backup"
                fi
            ;;
        esac

        if [[ -n "$SessionLogWorkloadName" ]]; then
            echo '<tr style="height:17px">' >> "$html"
            echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>$SessionLogWorkloadName</td>" >> "$html"
            echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>$SessionLogWorkloadType</td>" >> "$html"
            echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap><span style=\"color:$bcolor\">$SessionLogStatus</span></td>" >> "$html"
            echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>$SessionLogStartB</td>" >> "$html"
            echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>$SessionLogWorkloadTransferred</td>" >> "$html"
            echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>$SessionLogDurationB</td>" >> "$html"
            echo "</tr>" >> "$html"
            printed_rows=$((printed_rows+1))
        fi

        arraysessionslogbackup=$arraysessionslogbackup+1
    done

    # Fallback one-liner when no per-workload rows were printed (e.g., warnings without Processing lines)
    if [[ $printed_rows -eq 0 ]]; then
        case $worst_status in
            Success) rowColor="#54B948" ;;
            Warning) rowColor="#F2C973" ;;
            Failed|Error) rowColor="#E8595A" ;;
            *) rowColor="#626365" ;;
        esac
        [[ -z "$summary_msg" ]] && summary_msg="No detailed items in log"
        if [[ -n "$summary_time" ]]; then
            summary_time_b=$(date -d "$summary_time" '+%r')
        else
            summary_time_b="$SessionStartTimeB"
        fi

        echo '<tr style="height:17px">' >> "$html"
        echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>$summary_msg</td>" >> "$html"
        echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>$SessionType</td>" >> "$html"
        echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap><span style=\"color:$rowColor\">$worst_status</span></td>" >> "$html"
        echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>$summary_time_b</td>" >> "$html"
        echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>N/A</td>" >> "$html"
        echo "<td style='padding:2px 3px; vertical-align:top; border:1px solid $color1; font-family:Tahoma; font-size:$fontsize1' nowrap>$SessionDurationB</td>" >> "$html"
        echo "</tr>" >> "$html"
    fi


    echo "</tbody>" >> "$html"
    echo "</table>" >> "$html"
    echo "</td>" >> "$html"
    echo "</tr>" >> "$html"
    echo "<tr>" >> "$html"
    echo "<td>&nbsp;</td>" >> "$html"
    echo "</tr>" >> "$html"
    echo "</tbody>" >> "$html"
    echo "</table>" >> "$html"
    echo "<br/>" >> "$html"
    echo "<br/>" >> "$html"

done

echo "<div style='font-size:$fontsize2; color:$color3; padding:2px 3px 2px 3px; vertical-align:top; font-family:Tahoma'>Veeam Backup for AWS - Hostname: $veeamBackupAWSServer Version: $version</div>" >> "$html"
    echo "</body></html>" >> "$html"
echo "[OK] HTML written to: $html"
echo "[INFO] Sending email to: $email_add"
cat "$html" | s-nail -M "text/html" -s "$veeamBackupAWSServer - Daily Veeam Backup for AWS Report" "$email_add"
echo "[DONE] All steps complete."