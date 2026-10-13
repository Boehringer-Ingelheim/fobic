#!/usr/bin/bash

set -ouex pipefail

# Install Prisma Access Browser from Palo Alto Networks' signed Fedora RPM repo.
rpm --import https://updates.talon-sec.com/linux/prisma-access-browser/linux_signing_key.pub
dnf5 install -y prisma-access-browser-stable

# Microsoft Edge remains the system default; Prisma Browser is available as an alternative.
