#!/bin/bash

set -ouex pipefail

# install himmelblau packages
dnf install -y himmelblau pam-himmelblau nss-himmelblau himmelblau-sso himmelblau-selinux

# Supplementary SELinux rules for systemd socket activation of himmelblaud.
# See /ctx/selinux/fobic_himmelblau.te for details.
SELINUX_BUILD_DIR="$(mktemp -d)"
cp /ctx/selinux/fobic_himmelblau.te "$SELINUX_BUILD_DIR"/
make -C "$SELINUX_BUILD_DIR" -f /usr/share/selinux/devel/Makefile fobic_himmelblau.pp
semodule -i "$SELINUX_BUILD_DIR/fobic_himmelblau.pp"
rm -rf "$SELINUX_BUILD_DIR"

# The dispatcher and its logon actions are invoked by himmelblaud-tasks as root,
# after USERNAME has been resolved by Himmelblau.
chmod 0755 /usr/bin/himmelblau-logon /usr/libexec/himmelblau/logon.d/*

# Configuring PAM for Himmelblau
aad-tool configure-pam

# Enable Himmelblau services
systemctl enable himmelblaud himmelblaud-tasks himmelblau-hsm-pin-init

# Authselect profile setup to keep systemd-sysusers functional in the image build process
authselect list
authselect select himmelblau with-altfiles --force
authselect apply-changes

# Do any configuration that expects a live system
systemctl enable himmelblau-on-boot.service
