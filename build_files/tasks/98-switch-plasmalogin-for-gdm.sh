#!/bin/bash

set -ouex pipefail

# Switch out plasma-login for gdm
dnf install -y gdm
systemctl disable plasmalogin.service
systemctl enable gdm.service