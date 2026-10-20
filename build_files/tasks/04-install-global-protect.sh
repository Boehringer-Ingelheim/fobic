#!/usr/bin/bash

set -ouex pipefail

# Install GlobalProtect network manager client
TEMP_FOLDER=$(mktemp -d)

curl -L -o "$TEMP_FOLDER/rpms-fedora44-amd64.zip" https://github.com/WMP/GlobalProtect-SAML-NetworkManager/actions/runs/39407656492/artifacts/12257724753
unzip "$TEMP_FOLDER/rpms-fedora44-amd64.zip"
sudo dnf install -y "$TEMP_FOLDER/network-manager-gpclient-1.5.0-1.fc44.pr42.96.x86_64.rpm" "$TEMP_FOLDER/network-manager-gpclient-plasma-1.5.0-1.fc44.pr42.96.x86_64.rpm"
rm -rf "$TEMP_FOLDER"
