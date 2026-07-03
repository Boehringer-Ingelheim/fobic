#!/usr/bin/bash

set -ouex pipefail

### Trust FOBIC's own cosign signature for bootc switch/upgrade verification
##
## The registries.d lookaside config and the public keys are shipped as plain
## files via system_files/ (see etc/containers/registries.d/fobic.yaml and
## usr/lib/pki/containers/fobic.pub / fobic-backup.pub).
##
## Two keys are trusted (keyPaths, not keyPath): fobic.pub is the active
## signing key used by build.yml today. fobic-backup.pub's private half is
## kept offline and unused. If fobic's primary key is ever compromised, CI
## can start signing with the backup key immediately and existing machines
## keep trusting updates without a lockout, since they already trust both.
##
## policy.json can't be shipped the same way: the base image already ships
## its own /etc/containers/policy.json (with the ublue-os/redhat/toolbx-images
## scopes), and a static copy in system_files/ would silently replace it and
## go stale on every upstream update. Instead, merge our scope into whatever
## policy.json the base image currently has, at build time.

command -v jq >/dev/null || dnf5 install -y jq

POLICY=/etc/containers/policy.json
jq '.transports.docker["ghcr.io/boehringer-ingelheim/fobic"] = [
  {
    "type": "sigstoreSigned",
    "keyPaths": [
      "/usr/lib/pki/containers/fobic.pub",
      "/usr/lib/pki/containers/fobic-backup.pub"
    ],
    "signedIdentity": { "type": "matchRepository" }
  }
]' "${POLICY}" > "${POLICY}.tmp"
mv "${POLICY}.tmp" "${POLICY}"
