#!/bin/bash
# ---
# v1.01 20/06/24 First version


##
# @file backup.sh
# @brief Script for local backup, offsite synchronization, and backup retention management.
#
# This script performs the following tasks:
# - Synchronizes the local backup with an offsite location.
# - Manages backup retention according to predefined policies.
#
# The script ensures that backups are regularly created and synchronized, 
# and old backups are deleted based on the retention rules to save space 
# and maintain backup efficiency.

SMB_SERVER="192.168.1.1"
SMB_SHARE="share"
SMB_CREDENTIALS_FILE="/run/secrets/.auth_smb_secret"
LOCAL_FILE0="/backups.log"
LOCAL_FILE1="/backup1_$(date +%Y%m%d).gpg"
LOCAL_FILE2="/backup2_$(date +%Y%m%d).gpg"
SMB_REMOTE_PATH0="/backups"
SMB_REMOTE_PATH1="/backups1"
SMB_REMOTE_PATH2="/backups2"
SMB_COMMAND0="put \"$LOCAL_FILE0\" \"$SMB_REMOTE_PATH0/$(basename $LOCAL_FILE0)\""
SMB_COMMAND1="put \"$LOCAL_FILE1\" \"$SMB_REMOTE_PATH1/$(basename $LOCAL_FILE1)\""
SMB_COMMAND2="put \"$LOCAL_FILE2\" \"$SMB_REMOTE_PATH2/$(basename $LOCAL_FILE2)\""
ERROR=0
ROTATE_ERROR=0

#mail configuration
EMAIL="notif@mail.com"
FROM="notif@mail.com"
TO="user@mail.com"

# VPN Configuration variables
VPN_CONFIG="config.ovpn"            # Path to OpenVPN configuration file
# VPN_INTERFACE="tun0"              # The VPN interface name (typically tun0)
ROUTE="192.168.1.0/24"              # The route you want to add
GATEWAY="10.8.0.1"                  # The gateway for the route
RETRY_INTERVAL=5                    # Time in seconds between retries
MAX_RETRIES=5                       # Max retries to check if VPN is up

# Retention variables

RETENTION_INCBACKUP_DAYS=14
RETENTION_FULLBACKUP_WEEKS=13   # 90 days equals approximately 13 weeks
RETENTION_FULLBACKUP_MONTHS=12
RETENTION_FULLBACKUP_YEARS=5

# Log file
LOG_FILE="/backups.log"

LOG_ERROR=""


# ***************************************************************************************************** #
# ***************************************************************************************************** #
# ***********  F  U  N  C  T  I  O  N  S  ************************************************************* #
# ***************************************************************************************************** #
# ***************************************************************************************************** #

## @brief Detects the active tun interface created by OpenVPN.
#  @return The name of the active tun interface, or an empty string if none is found.
detect_tun_interface() {
    local tun_interface
    tun_interface=$(ip -o link show | awk -F': ' '/tun[0-9]+/{print $2}' | tail -n 1)
    echo "$tun_interface"
}

## @brief Checks if the VPN connection is established.
#  @param $1 The tun interface to check.
#  @return 0 if the VPN is connected, 1 otherwise.
check_vpn_connection() {
    local tun_interface="$1"
    ip a show "$tun_interface" > /dev/null 2>&1
    return $?
}

## @brief Checks if the route already exists in the routing table.
#  @return 0 if the route exists, 1 otherwise.
route_exists() {
    ip route show "$ROUTE" | grep -q "$GATEWAY"
    return $?
}

## @brief Adds a route to the routing table.
#  This function adds a specific route to the routing table via the VPN interface
#  only if the route does not already exist.
#  @param $1 The tun interface to use for adding the route.
add_route() {
    local tun_interface=$1
    if [ -z "$tun_interface" ]; then
        log "Error: No tun interface detected. Cannot add route."
        return 1
    fi

    if route_exists; then
        log "Route already exists: $ROUTE via $GATEWAY"
    else
        log "Attempting to add route: ip route add $ROUTE via $GATEWAY dev $tun_interface"
        ip route add "$ROUTE" via "$GATEWAY" dev "$tun_interface"
        if [ $? -eq 0 ]; then
            log "Route added successfully: $ROUTE via $GATEWAY"
        else
            log "Error adding route: $ROUTE via $GATEWAY"
        fi
    fi
}

## @brief Initiates the VPN connection using OpenVPN.
#  The function attempts to establish a VPN connection using the specified configuration file.
#  It waits for the connection to be established, retrying up to the specified number of times.
#  @return The name of the tun interface if the VPN connection is established successfully, 
#          or an empty string otherwise.
    connect_vpn() {
    log "Starting OpenVPN connection..."
    openvpn --config "$VPN_CONFIG" --daemon && sleep 2

    # Wait for the VPN to connect and detect the tun interface
    for ((i=1; i<=MAX_RETRIES; i++)); do
        log "Checking VPN connection (Attempt $i of $MAX_RETRIES)..."
        sleep "$RETRY_INTERVAL"
        local detected_tun
        detected_tun=$(detect_tun_interface)
        if [ -n "$detected_tun" ] && check_vpn_connection "$detected_tun"; then
            log "VPN connection established successfully on $detected_tun."
            echo "$detected_tun"
            return 0
        else
            log "No tun interface detected. Current tun interface: $detected_tun"
        fi
    done

    log "Failed to establish VPN connection after $MAX_RETRIES attempts."
    return 1
}

## @brief Disconnects the VPN connection.
#  The function stops the OpenVPN process and checks to ensure that the VPN interface is no longer active.
#  @return 0 if the VPN is disconnected successfully, 1 otherwise.
disconnect_vpn() {
    log "Stopping OpenVPN..."
    pkill openvpn

    # Check if any tun interfaces are still up
    local active_tun
    active_tun=$(detect_tun_interface)
    if [ -z "$active_tun" ]; then
        log "VPN disconnected successfully."
        return 0
    else
        log "Failed to disconnect VPN. Active interface: $active_tun"
        return 1
    fi
}

## @brief Validates the extracted date from the filename.
#  @param $1 The date string to validate.
#  @return 0 if the date is valid, 1 otherwise.
validate_date() {
    date -d "$1" >/dev/null 2>&1
    return $?
}

##
# @function noretain_file
# @brief This function checks if a file meets the retention criteria.
# 
# The retention criteria are based on the following rules:
# RETENTION_FULLBACKUP_WEEKS=13   # 90 days equals approximately 13 weeks
# RETENTION_FULLBACKUP_MONTHS=12
# RETENTION_FULLBACKUP_YEARS=5
# 
# Function to check if a file meets the conditions for deletion (not retention)
#
#     Date Extraction:
#         The function extracts a date in the format YYYYMMDD from the filename.
#         If the date isn't in the correct format, it immediately returns false.
#
#     Age Check (Older than 90 Days):
#         The function checks if the file is older than 90 days (approximately 13 weeks).
#         If it's less than 90 days old, it returns false.
#
#     First Day of the Month Check (format YYYYMM01):
#         It checks if the file was created on the first day of any month within the last 12 months.
#         If it was, it returns false.
#
#     First Day of the Year Check (format YYYY0101):
#         The function checks if the file was created on January 1st within the last 5 years.
#         If it was, it returns false.
#
#     Return True:
#         If the file does not pass all retention checks, the function returns true, 
#         indicating that the file does not meet the retention criteria, and is marked for deletion.
#
# @param filename The name of the file to check. The filename should contain a date in the format YYYYMMDD.
# @return Returns "true" yf the file does not pass all retention checks, otherwise returns "false".
##
function noretain_file() {

    local filename=$1

    # Extract the date from the file name in the format YYYYYYMMDDD
    # local file_date=$(echo "$filename" | grep -oP '\d{8}')   # debian
    local file_date=$(echo "$filename" | grep -oP '\d{8}')

    # Verify that the date is in the correct format.
    if [[ ! "$file_date" =~ ^[0-9]{8}$ ]]; then
        echo "false"
        return
    fi

    # Convert date to a format `date` (YYYYY-MM-DD)
    local formatted_date=$(date -d "${file_date:0:4}-${file_date:4:2}-${file_date:6:2}" +%Y-%m-%d)

    # Validate the formatted date
    if ! validate_date "$formatted_date"; then
        log "Skipping file with invalid date: $filename"
        echo "false"
        return
    fi

    # Get current date
    local current_date=$(date +%Y-%m-%d)
    # Verify if the file has more than RETENTION_FULLBACKUP_WEEKS weeks
    local retention_days=$((RETENTION_FULLBACKUP_WEEKS * 7))
    if [[ $(date -d "$current_date" +%s) -lt $(date -d "$formatted_date +${retention_days} days" +%s) ]]; then
        echo "false"
        return
    fi

    # Check if the file is from the first day of a month in the last RETENTION_FULLBACKUP_MONTHS months
    local file_day=$(date -d "$formatted_date" +%d)
    local file_month=$(date -d "$formatted_date" +%Y%m)
    local retention_months_ago=$(date -d "$current_date -${RETENTION_FULLBACKUP_MONTHS} months" +%Y%m)

    if [[ "$file_day" == "01" && "$file_month" -ge "$retention_months_ago" ]]; then
        echo "false"
        return
    fi

    # Check if the file is the first day of the year in the last RETENTION_FULLBACKUP_YEARS years
    local file_year=$(date -d "$formatted_date" +%Y)
    local file_day_month=$(date -d "$formatted_date" +%m%d)
    local retention_years_ago=$(date -d "$current_date -${RETENTION_FULLBACKUP_YEARS} years" +%Y)

    if [[ "$file_day_month" == "0101" && "$file_year" -ge "$retention_years_ago" ]]; then
        echo "false"
        return
    fi

    # If the file does not pass all retention checks, the function returns true, 
    echo "true"
}


##
# @function send_notif_email
# @brief Sends a notification email.
#
# This function sends an email with a notification message to a specified recipient.
# The email content and recipient are defined by the function's arguments.
#
# @param subject    The subject of the email.
# @param body       The body of the email.
# @param log        The error log of the process.
# @return           Returns 0 on success, or a non-zero value on failure.
##
send_notif_email() {
    SUBJECT=$1
    BODY=$2
    LOG_CONTENT=$3
    log $LOG_CONTENT
    {
        echo -e "Subject: $SUBJECT"
        echo -e "\n$BODY"
        echo -e "\n--- Error Log ---\n"
        echo -e  $LOG_CONTENT
        echo -e "\n--- Log (last 10 lines) ---\n"
        tail -n 10 $LOG_FILE
    } | msmtp --from=$EMAIL -t $TO
    return $?

}


## @brief Logs messages to the specified log file.
#  @param $1 The message to log.
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" >> "$LOG_FILE"

    # echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

##
# @function del_SMB_file
# @brief Deletes a file from an SMB share.
#
# This function deletes a specified file from an SMB share using the `smbclient` command.
# It logs the outcome of the operation and updates an error count if the deletion fails.
#
# @param file The name of the file to be deleted from the SMB share.
# @param path The path of the file to be deleted from the SMB share.
# @return Returns 0 if the file was successfully deleted, or 1 if there was an error.
##
del_SMB_file() {
    local file=$1
    local path=$2

    # Attempt to delete the file from the SMB share
    smbclient "//$SMB_SERVER/$SMB_SHARE" -A "$SMB_CREDENTIALS_FILE" -D "$path" -c "del $file" # >> "$LOG_FILE" 2>&1

    # Check the result of the deletion command
    if [ $? -eq 0 ]; then
        log "Deleted backup file (by applying defined retention policies): $path/$file"
        return 0
    else
        log "Error deleting file: $path/$file"
        ((ERROR++))
        LOG_ERROR+="Error deleting file: $path/$file"
        return 1
    fi
}

##
# @function rotate_path_files
# @brief Rotates files in a specified directory based on the retention policy.
#
# @param directory_path The path of the directory containing the files to be rotated.
# @return void
##
rotate_path_files() {

find $1 -type f | while read -r filepath; do

  result=$(noretain_file "$filepath") 
  
  if [[ $result == "true" ]]; then
    # log "The file $filepath meets the deletion conditions."
    rm $filepath
    if [ $? -eq 0 ]; then
        log "Deleted file (by applying defined retention policies): $filepath"
    else
        log "Error deleting file: $filepath"
        ((ERROR++))
        ((ROTATE_ERROR++))
        LOG_ERROR+="Error deleting file: $filepath"
    fi
  fi
done
}


##
# @function rotate_SMB_files
# # @brief Checks all files in the specified SMB share and deletes those that do not comply with the retention policy.
#
# This function iterates over all files in the given directory, checking each file against the defined 
# # retention policy. Files that do not meet the retention criteria are deleted. The retention policy 
# is based on predefined rules such as age of the file, whether it is the first of the month or year, etc.
#
# @param directory_path The directory path where the files to be checked are located.
# @return void
##
rotate_SMB_files() {
    # Connecting to the Samba share and listing files
    FILES=$(smbclient "//${SMB_SERVER}/${SMB_SHARE}" -A "$SMB_CREDENTIALS_FILE" -D "$1" -c "ls" | awk '{print $1}')
    if [ $? -ne 0 ]; then
        # log "Error listing files in $1"
        ((ERROR++))
        ((ROTATE_ERROR++))
        LOG_ERROR+="Error listing files in $1\n"
        # return 1
    fi
    # NUM_FILES=$(echo "$FILES" | wc -l)
    # log $NUM_FILES "files found in $1"

    # Iterate on each file and delete those that do not comply with the retention policy.
    for FILE in $FILES; do
        result=$(noretain_file "$FILE")
        if [[ $result == "true" ]]; then
            # Delete file from SMB share
            del_SMB_file "$FILE" "$1"
            if [ $? -ne 0 ]; then
                log "Error deleting file: $S1/$FILE"
                ((ERROR++))
                ((ROTATE_ERROR++))
                LOG_ERROR+="Error deleting file: $S1/$FILE"
            #     return 1
            # else
            #     # log "Deleted file: $S1/$FILE"
            #     return 0
            fi
        fi
    done
}

# ***************************************************************************************************** #
# ***************************************************************************************************** #
# *******************   M  A  I  N   ****************************************************************** #
# ***************************************************************************************************** #
# ***************************************************************************************************** #


# Start the VPN connection and get the active tun interface
VPN_INTERFACE=$(connect_vpn)
if [ -z "$VPN_INTERFACE" ]; then
    log "Exiting script due to VPN connection failure."
    log "###############################################################################"
    # Send notification email
    send_notif_email "backup synchronization: Exiting script due to VPN connection failure."

    exit 1
fi

# Add the route using the detected tun interface
add_route "$VPN_INTERFACE"



#########################################################################################



log "Start backup synchronization & retention process."

# Check connection status
if [ $ERROR -eq 0 ]; then
 #   ip route add 192.168.221.0/24 via 10.8.0.217 dev tun0 && sleep 1
    # test connection

    # -o StrictHostKeyChecking=no
    # Download backups
  
    if [ $? -eq 0 ]; then
        log "Backup $(basename $LOCAL_FILE1) downloaded OK."
        # return 0
    else
        log "Error downloading file: $(basename $LOCAL_FILE1)."
        ((ERROR++))
        LOG_ERROR+="Error downloading file: $(basename $LOCAL_FILE1)\n"
        # return 1
    fi
  
    if [ $? -eq 0 ]; then
        log "Backup $(basename $LOCAL_FILE2) downloaded OK."
        # return 0
    else
        log "Error downloading file: $(basename $LOCAL_FILE2)."
        ((ERROR++))
        LOG_ERROR+="Error downloading file: $(basename $LOCAL_FILE2)\n"
        # return 1
    fi

fi

disconnect_vpn

#Downloaded files are uploaded to the NAS

smbclient "//$SMB_SERVER/$SMB_SHARE" -A "$SMB_CREDENTIALS_FILE" -c "$SMB_COMMAND1"

if [ $? -eq 0 ]; then
    log "Backup $(basename $LOCAL_FILE1) uploaded OK."
    rm $LOCAL_FILE1
fi
smbclient "//$SMB_SERVER/$SMB_SHARE" -A "$SMB_CREDENTIALS_FILE" -c "$SMB_COMMAND2"

if [ $? -eq 0 ]; then
    log "Backup $(basename $LOCAL_FILE2) uploaded OK."
    rm $LOCAL_FILE2
fi

# Rotate files in the SMB share
ROTATE_ERROR=0
rotate_SMB_files "$SMB_REMOTE_PATH1"
if [ $ROTATE_ERROR -ne 0 ]; then
    log "Error rotating files in $SMB_REMOTE_PATH1."
    LOG_ERROR+="Error rotating files in $SMB_REMOTE_PATH1\n"
fi

ROTATE_ERROR=0
rotate_SMB_files "$SMB_REMOTE_PATH2"
if [ $ROTATE_ERROR -ne 0 ]; then
    log "Error rotating files in $SMB_REMOTE_PATH2."
    LOG_ERROR+="Error rotating files in $SMB_REMOTE_PATH2\n"
fi

# Copy log_file
smbclient "//$SMB_SERVER/$SMB_SHARE" -A "$SMB_CREDENTIALS_FILE" -c "$SMB_COMMAND0"
if [ $ERROR -ne 0 ]; then
    log "backup synchronization and retention process completed - $ERROR error(s)."
    LOG_ERROR+="backup synchronization and retention process completed - $ERROR error(s).\n"
else
    log "backup synchronization and retention process completed without error."
    # LOG_ERROR+="backup synchronization and retention process completed without error."
    LOG_ERROR+="Process completed without error."
fi

# Send notification email
send_notif_email "backup synchronization and retention process completed - $ERROR error(s)." "Backup file rotation and deletion is complete. Check the log in $LOG_FILE for details." "$LOG_ERROR"

# Additional error handling can be added here
if [ $ERROR -ne 0 ]; then
    log "Error(s) occurred during the execution. Please check the log file for details."
    # Optionally, you can exit with an error status or send notifications
    # exit 1
fi


log "backup synchronization and retention process completed - $ERROR error(s)."
log "###############################################################################"
exit 0


# ***************************************************************************************************** #
