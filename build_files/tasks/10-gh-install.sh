#!/bin/bash

set -ouex pipefail

# get latest release
asset_url=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r '.assets[] | select(.name | endswith("_linux_amd64.tar.gz")) | .browser_download_url')
curl -fL "$asset_url" -o gh_linux_amd64.tar.gz
tar -xzf gh_linux_amd64.tar.gz
mkdir -p /usr/local/bin/
mv gh_*/bin/gh /usr/local/bin/
rm -rf gh_*
