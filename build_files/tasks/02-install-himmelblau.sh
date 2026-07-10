#!/bin/bash

set -ouex pipefail

# install himmelblau packages
dnf install -y himmelblau pam-himmelblau nss-himmelblau himmelblau-sso himmelblau-selinux

# Could be removed, once solved https://github.com/himmelblau-idm/himmelblau/issues/1503 (milestone 4.0 - 2026-08-31)
SELINUX_SRC_DIR="/usr/share/selinux/packages/himmelblaud"
SELINUX_MAKEFILE="/usr/share/selinux/devel/Makefile"

echo "Compiling SELinux policy modules..."
cd "$SELINUX_SRC_DIR"
make -f "$SELINUX_MAKEFILE" himmelblaud.pp
echo "Installing SELinux policy modules..."
semodule -i himmelblaud.pp

# Clean up compiled files (keep source for potential recompilation)
rm -f himmelblaud.pp tmp/*.* 2>/dev/null || :
rmdir tmp 2>/dev/null || :

# Relabel installed binaries
restorecon -Fv /usr/sbin/himmelblaud /usr/sbin/himmelblaud_tasks 2>/dev/null || :

# Relabel existing dirs (may not exist on fresh install)
[ -d /etc/himmelblau ]                && restorecon -RFv /etc/himmelblau || :
[ -d /run/himmelblaud ]               && restorecon -RFv /run/himmelblaud || :
[ -d /var/run/himmelblaud ]           && restorecon -RFv /var/run/himmelblaud || :
[ -d /var/cache/private/himmelblaud ] && restorecon -RFv /var/cache/private/himmelblaud || :
[ -d /var/cache/himmelblaud ]         && restorecon -RFv /var/cache/himmelblaud || :
[ -d /var/cache/nss-himmelblau ]      && restorecon -RFv /var/cache/nss-himmelblau || :
[ -d /var/lib/private/himmelblaud ]   && restorecon -RFv /var/lib/private/himmelblaud || :
[ -d /var/lib/himmelblaud ]           && restorecon -RFv /var/lib/himmelblaud || :


# Configuring PAM for Himmelblau
aad-tool configure-pam

# Enable Himmelblau services
systemctl enable himmelblaud himmelblaud-tasks himmelblau-hsm-pin-init

# Do any configuration that expects a live system
systemctl enable himmelblau-on-boot.service

# Switch out plasma-login for gdm
dnf --setopt=tsflags=noscripts install -y gdm
systemctl disable plasma-login.service
systemctl enable gdm.service
