#!/bin/bash -e

export AUTHORIZED_KEYS_COMMAND_FILE="/opt/authorized_keys_command.sh"
export IMPORT_USERS_SCRIPT_FILE="/opt/import_users.sh"
export SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
export MAIN_CONFIG_FILE="/etc/aws-ec2-ssh.conf"

cd "/tmp/aws-ec2-ssh"

./install_configure_selinux.sh
./install_configure_sshd.sh
$IMPORT_USERS_SCRIPT_FILE
./install_restart_sshd.sh
