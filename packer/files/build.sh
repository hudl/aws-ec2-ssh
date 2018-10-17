#!/bin/bash -e

export AUTHORIZED_KEYS_COMMAND_FILE="/opt/authorized_keys_command.sh"
export IMPORT_USERS_SCRIPT_FILE="/opt/import_users.sh"
export SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
export MAIN_CONFIG_FILE="/etc/aws-ec2-ssh.conf"

ln -s /bin/bash /bin/rbash
echo "/bin/rbash" >> /etc/shells

cd "/tmp/aws-ec2-ssh"

cp authorized_keys_command.sh $AUTHORIZED_KEYS_COMMAND_FILE
cp import_users.sh $IMPORT_USERS_SCRIPT_FILE
mkdir -p /var/lib/cloud/scripts/
cp packer/files/initialize.sh /var/lib/cloud/scripts/per-instance
chmod +x /var/lib/cloud/scripts/per-instance/initialize.sh

cat > /etc/cron.d/import_users << EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/opt/aws/bin
MAILTO=root
HOME=/
*/10 * * * * root $IMPORT_USERS_SCRIPT_FILE
EOF
chmod 0644 /etc/cron.d/import_users
