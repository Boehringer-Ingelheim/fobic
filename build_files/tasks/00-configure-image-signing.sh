#!/usr/bin/bash

set -ouex pipefail

### Trust DINO's own cosign signature for bootc switch/upgrade verification
##
## The registries.d lookaside config and the public keys are shipped as plain
## files via system_files/ (see etc/containers/registries.d/dino.yaml and
## usr/lib/pki/containers/dino.pub / dino-backup.pub).
##
## Two keys are trusted (keyPaths, not keyPath): dino.pub is the active
## signing key used by build.yml today. dino-backup.pub's private half is
## kept offline and unused. If dino's primary key is ever compromised, CI
## can start signing with the backup key immediately and existing machines
## keep trusting updates without a lockout, since they already trust both.
##
## policy.json can't be shipped the same way: the base image already ships
## its own /etc/containers/policy.json (with the ublue-os/redhat/toolbx-images
## scopes), and a static copy in system_files/ would silently replace it and
## go stale on every upstream update. Instead, merge our scope into whatever
## policy.json the base image currently has, at build time.

command -v jq >/dev/null || dnf5 install -y jq

IMAGE_REF="ghcr.io/boehringer-ingelheim/dino"
KEY_PATHS=(
  /usr/lib/pki/containers/dino.pub
  /usr/lib/pki/containers/dino-backup.pub
)

# A keyPath that doesn't exist makes every signature check for this image fail,
# which breaks bootc switch/upgrade on every machine. Refuse to build that.
for key in "${KEY_PATHS[@]}"; do
  if [[ ! -s "${key}" ]]; then
    echo "Error: signing key ${key} is missing or empty." >&2
    exit 1
  fi
done

if ! grep -qF "${IMAGE_REF}:" /etc/containers/registries.d/*.yaml; then
  echo "Error: no registries.d lookaside config for ${IMAGE_REF}." >&2
  exit 1
fi

POLICY=/etc/containers/policy.json
jq --arg ref "${IMAGE_REF}" \
  --argjson keys "$(printf '%s\n' "${KEY_PATHS[@]}" | jq -R . | jq -s .)" \
  '.transports.docker[$ref] = [
    {
      "type": "sigstoreSigned",
      "keyPaths": $keys,
      "signedIdentity": { "type": "matchRepository" }
    }
  ]' "${POLICY}" > "${POLICY}.tmp"
mv "${POLICY}.tmp" "${POLICY}"

# Fail if the policy we just wrote doesn't list exactly the keys above.
jq -e --arg ref "${IMAGE_REF}" --argjson n "${#KEY_PATHS[@]}" \
  '.transports.docker[$ref][0].keyPaths | length == $n' "${POLICY}" >/dev/null
