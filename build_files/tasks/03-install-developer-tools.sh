#!/usr/bin/bash

set -ouex pipefail

TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

### 1. Install AWS CLI v2 from standard Fedora repository
dnf5 install -y awscli2

### 2. Install AWS Session Manager Plugin from pinned AWS S3 release
SMP_VERSION="1.2.896.0"
SMP_SHA256="89a4a07fcb92169bdd2f07c2531acd11b84857338172e7638964aaa08fd5f0e3"
SMP_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/${SMP_VERSION}/linux_64bit/session-manager-plugin.rpm"

curl -fsSL "$SMP_URL" -o "$TMPDIR/session-manager-plugin.rpm"
echo "${SMP_SHA256}  $TMPDIR/session-manager-plugin.rpm" | sha256sum -c -
rpm -K --nosignature "$TMPDIR/session-manager-plugin.rpm"

(cd "$TMPDIR" && rpm2cpio session-manager-plugin.rpm | cpio -idmv)
install -m 0755 "$TMPDIR/usr/local/sessionmanagerplugin/bin/session-manager-plugin" /usr/bin/session-manager-plugin

### 3. Install OpenShift Client (oc & kubectl) from pinned OKD GitHub release
OKD_VERSION="5.0.0-okd-scos.3"
OKD_SHA256="70f2798b3902bcb60f4ac104102de4d1e1f80658b120f1dd6fdff9e73c0e5aec"
OKD_CLIENT_URL="https://github.com/okd-project/okd/releases/download/${OKD_VERSION}/openshift-client-linux-${OKD_VERSION}.tar.gz"

curl -fsSL "$OKD_CLIENT_URL" -o "$TMPDIR/openshift-client.tar.gz"
echo "${OKD_SHA256}  $TMPDIR/openshift-client.tar.gz" | sha256sum -c -
tar -xzf "$TMPDIR/openshift-client.tar.gz" -C "$TMPDIR"

install -m 0755 "$TMPDIR/oc" /usr/bin/oc
if [ -f "$TMPDIR/kubectl" ] && ! command -v kubectl >/dev/null 2>&1; then
  install -m 0755 "$TMPDIR/kubectl" /usr/bin/kubectl
fi
