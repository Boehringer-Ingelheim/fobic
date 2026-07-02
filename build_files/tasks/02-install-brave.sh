#!/usr/bin/bash

dnf5 install -ydnf-plugins-core

dnf5 config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo

dnf5 install -y brave-browser

dnf5 remove -y firefox