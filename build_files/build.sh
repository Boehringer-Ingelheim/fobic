#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# 1. Configuration
TASK_DIR="/ctx/tasks"

echo "--- Starting Task Runner ---"

# 2. Validation
if [ ! -d "$TASK_DIR" ]; then
    echo "Error: Directory '$TASK_DIR' not found."
    exit 1
fi

# 3. The Execution Loop
# We use a 'for' loop which naturally sorts 01, 02, 03...
for script in "$TASK_DIR"/[0-9]*.sh; do

    # Handle case where no files match the pattern
    [ -e "$script" ] || { echo "No task scripts found."; exit 0; }

    echo "[RUNNING] $(basename "$script")"

    # Run the script.
    # Because 'set -e' is active in THIS script, if the command below
    # returns a non-zero exit code, the runner will stop immediately.
    bash "$script"

    echo "[SUCCESS] $(basename "$script") completed."
    echo "----------------------------"
done

echo "All tasks finished successfully."

# 4. Post-Task Cleanup & Chunkah Rechunking Preparation
echo "--- Running Chunkah Preparation & Cleanup ---"

# Clear libdnf5 state so it does not invalidate the libdnf5 package layer in Chunkah
rm -rf /usr/lib/sysimage/libdnf5/*

# Relink rpm-ostree-base-db to rpmdb so the base DB reflects packages installed in this build
# See: https://github.com/coreos/rpm-ostree/issues/4554
for file in rpmdb.sqlite rpmdb.sqlite-shm rpmdb.sqlite-wal; do
    target="/usr/share/rpm/${file}"
    link_path="/usr/lib/sysimage/rpm-ostree-base-db/${file}"
    if [[ -f "${target}" && -f "${link_path}" ]]; then
        ln -f "${target}" "${link_path}"
    fi
done

# Tag unpackaged binaries and config trees with user.component xattrs for Chunkah layer packing
# See: https://github.com/coreos/chunkah#customizing-the-layers
if [[ -f /usr/bin/session-manager-plugin ]]; then
    setfattr -n user.component -v "aws-session-manager-plugin" /usr/bin/session-manager-plugin
fi

for bin in /usr/bin/oc /usr/bin/kubectl; do
    if [[ -f "${bin}" ]]; then
        setfattr -n user.component -v "openshift-client" "${bin}"
    fi
done

FOBIC_CONFIG_PATHS=(
    /usr/bin/himmelblau-logon
    /usr/bin/himmelblau-on-boot
    /usr/libexec/himmelblau
    /usr/lib/pki/containers
    /usr/lib/systemd/system/himmelblau-on-boot.service
    /etc/pki/ca-trust/source/anchors
    /etc/pki/ca-trust/extracted
)
for path in "${FOBIC_CONFIG_PATHS[@]}"; do
    if [[ -e "${path}" ]]; then
        setfattr -n user.component -v "fobic-config" "${path}"
    fi
done

# Clean transient /var and /run state created by package scriptlets during build
find /var/* -maxdepth 0 -type d ! -name cache ! -name log -exec rm -rf {} +
mkdir -p /var/tmp
rm -rf /run/dnf

# Normalize mtimes so rebuilds produce reproducible Chunkah layer plans
find /usr /etc /opt -newermt '1970-01-01T00:00:00Z' -exec touch -h -a -m -d '1970-01-01T00:00:01Z' {} +
