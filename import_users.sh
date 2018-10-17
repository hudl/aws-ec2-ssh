#!/bin/bash -e

function log() {
    /usr/bin/logger -i -p auth.info -t aws-ec2-ssh "$@"
}

# check if AWS CLI exists
if ! [ -x "$(which aws)" ]; then
    log "aws executable not found - exiting!"
    exit 1
fi

# source configuration if it exists
[ -f /etc/aws-ec2-ssh.conf ] && . /etc/aws-ec2-ssh.conf

# Should we actually do something?
: ${DONOTSYNC:=0}

if [ ${DONOTSYNC} -eq 1 ]
then
    log "Please configure aws-ec2-ssh by editing /etc/aws-ec2-ssh.conf"
    exit 1
fi

# Which IAM groups have access to this instance
# Comma seperated list of IAM groups. Leave empty for all available IAM users
: ${IAM_AUTHORIZED_GROUPS:=""}

# Special group to mark users as being synced by our script
: ${LOCAL_MARKER_GROUP:="iam-synced-users"}

# Give the users these local UNIX groups
: ${LOCAL_GROUPS:=""}

# Specify an IAM group for users who should be given sudo privileges, or leave
# empty to not change sudo access, or give it the value '##ALL##' to have all
# users be given sudo rights.
# DEPRECATED! Use SUDOERS_GROUPS
: ${SUDOERSGROUP:=""}

# Specify a comma seperated list of IAM groups for users who should be given sudo privileges.
# Leave empty to not change sudo access, or give the value '##ALL## to have all users
# be given sudo rights.
: ${SUDOERS_GROUPS:="${SUDOERSGROUP}"}

# Assume a role before contacting AWS IAM to get users and keys.
# This can be used if you define your users in one AWS account, while the EC2
# instance you use this script runs in another.
: ${ASSUMEROLE:=""}

# Possibility to provide a custom useradd program
: ${USERADD_PROGRAM:="/usr/sbin/useradd"}

# Possibility to provide custom useradd arguments
: ${USERADD_ARGS:="--user-group --create-home --shell /bin/bash"}

# Initizalize INSTANCE variable
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep region | awk -F\" '{print $4}')

# Get previously synced users
function get_local_users() {
    /usr/bin/getent group ${LOCAL_MARKER_GROUP} \
        | cut -d : -f4- \
        | sed "s/,/ /g"
}

# Create or update a local user based on info from the IAM group
function create_or_update_local_user() {
    local username
    local sudousers
    local localusergroups

    username="${1}"
    sudousers="${2}"
    localusergroups="${LOCAL_MARKER_GROUP}"

    # check that username contains only alphanumeric, period (.), underscore (_), and hyphen (-) for a safe eval
    if [[ ! "${username}" =~ ^[0-9a-zA-Z\._\-]{1,32}$ ]]
    then
        log "Local user name ${username} contains illegal characters"
        exit 1
    fi

    if [ ! -z "${LOCAL_GROUPS}" ]
    then
        localusergroups="${LOCAL_GROUPS},${LOCAL_MARKER_GROUP}"
    fi

    if ! id "${username}" >/dev/null 2>&1; then
        ${USERADD_PROGRAM} ${USERADD_ARGS} "${username}"
        /bin/chown -R "${username}:${username}" "$(eval echo ~$username)"
        log "Created new user ${username}"
    fi
    /usr/sbin/usermod -a -G "${localusergroups}" "${username}"
    # Should we add this user to sudo ?
    if [[ ! -z "${SUDOERS_GROUPS}" ]]
    then
        SaveUserFileName=$(echo "${username}" | tr "." " ")
        SaveUserSudoFilePath="/etc/sudoers.d/$SaveUserFileName"
        if [[ "${SUDOERS_GROUPS}" == "##ALL##" ]] || echo "${sudousers}" | grep "\s*${username}\s*" > /dev/null
        then
            echo "${username} ALL=(ALL) NOPASSWD:ALL" > "${SaveUserSudoFilePath}"
        else
            [[ ! -f "${SaveUserSudoFilePath}" ]] || rm "${SaveUserSudoFilePath}"
        fi
    fi
}

function delete_local_user() {
    # First, make sure no new sessions can be started
    /usr/sbin/usermod -L -s /sbin/nologin "${1}" || true
    # ask nicely and give them some time to shutdown
    /usr/bin/pkill -15 -u "${1}" || true
    sleep 5
    # Dont want to close nicely? DIE!
    /usr/bin/pkill -9 -u "${1}" || true
    sleep 1
    # Remove account now that all processes for the user are gone
    /usr/sbin/userdel -f -r "${1}"
    log "Deleted user ${1}"
}

function sync_accounts() {
    if [ -z "${LOCAL_MARKER_GROUP}" ]
    then
        log "Please specify a local group to mark imported users. eg iam-synced-users"
        exit 1
    fi

    # Check if local marker group exists, if not, create it
    /usr/bin/getent group "${LOCAL_MARKER_GROUP}" >/dev/null 2>&1 || /usr/sbin/groupadd "${LOCAL_MARKER_GROUP}"

    # declare and set some variables
    local iam_users
    local sudo_users
    local local_users
    local intersection
    local removed_users
    local user

    S3_BUCKET='hudl-config'
    S3_DIR='ssh'
    USER_FILE='user-permission.txt'
    LOCAL_DIR='/tmp'

    aws s3 sync --exclude '*' --include $USER_FILE s3://$S3_BUCKET/$S3_DIR $LOCAL_DIR > /dev/null 2>&1

    all_user_info=$(cat $LOCAL_DIR/$USER_FILE)

    for line in $all_user_info
    do
        group_name=`echo $line | awk -F '=' '{print $1}'`
        sudoers_groups=($(echo "$SUDOERS_GROUPS" | tr ',' '\n'))
        # We'll add users to our sudoers array if they're in a sudoer group
        if printf '%s\n' ${sudoers_groups[@]} | grep -q -P "^$group_name$"; then
            all_sudoers_users=`echo $line | awk -F '=' '{print $2}'`
            sudoers_users=($(echo "$all_sudoers_users" | tr ',' '\n'))
            for sudoers_user in "${sudoers_users[@]}"
            do
                sudoers_users_list=( "${sudoers_users_list[@]}" "$sudoers_user" )
            done
        fi
        # All users get added to our users array
        all_users=`echo $line | awk -F '=' '{print $2}'`
        users=($(echo "$all_users" | tr ',' '\n'))
        for user in "${users[@]}"
        do
            users_list=( "${users_list[@]}" "$user" )
        done
    done
    # We'll remove any duplicates and make it nice and sorted
    iam_users=`printf '%s\n' "${users_list[@]}"| sort -u | tr '\n' ' '`
    sudo_users=`printf '%s\n' "${sudoers_users_list[@]}"| sort -u | tr '\n' ' '`

    if [[ -z "${iam_users}" ]]
    then
      log "we just got back an empty iam_users user list which is likely caused by an IAM outage!"
      exit 1
    fi

    if [[ ! -z "${SUDOERS_GROUPS}" ]] && [[ ! "${SUDOERS_GROUPS}" == "##ALL##" ]] && [[ -z "${sudo_users}" ]]
    then
      log "we just got back an empty sudo_users user list which is likely caused by an IAM outage!"
      exit 1
    fi

    local_users=$(get_local_users | sort | uniq)

    intersection=$(echo ${local_users} ${iam_users} | tr " " "\n" | sort | uniq -D | uniq)
    removed_users=$(echo ${local_users} ${intersection} | tr " " "\n" | sort | uniq -u)

    # Add or update the users found in IAM
    for user in ${iam_users}; do
        if [ "${#user}" -le "32" ]
        then
            create_or_update_local_user "${user}" "$sudo_users"
        else
            log "Can not import IAM user ${user}. User name is longer than 32 characters."
        fi
    done

    # Remove users no longer in the IAM group(s)
    for user in ${removed_users}; do
        delete_local_user "${user}"
    done
}

sync_accounts
