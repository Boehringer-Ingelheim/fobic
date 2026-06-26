#!/usr/bin/env bash
set -euo pipefail

usage(){
  echo "Usage: $0 install|update|remove|status"
  exit 2
}

cmd=${1:-}
[ -n "${cmd}" ] || usage

TMPDIR=$(mktemp -d)
cleanup(){ rm -rf "$TMPDIR"; }
trap cleanup EXIT

LOCAL_BIN="$HOME/.local/bin"
LOCAL_STATE_DIR="$HOME/.local/share/openshift-client-install"
KUBECTL_MANAGED_MARKER="$LOCAL_STATE_DIR/kubectl.installed-by-openshift-client-install"

ensure_dirs(){
  mkdir -p "$LOCAL_BIN"
  mkdir -p "$LOCAL_STATE_DIR"
}

check_path(){
  if echo ":$PATH:" | grep -q ":${LOCAL_BIN}:"; then
    return 0
  else
    return 1
  fi
}

latest_okd_tag(){
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' not found. Please install jq and retry." >&2
    return 1
  fi

  curl -fsSL "https://api.github.com/repos/okd-project/okd/releases/latest" | jq -r '.tag_name'
}

latest_client_url(){
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' not found. Please install jq and retry." >&2
    return 1
  fi

  curl -fsSL "https://api.github.com/repos/okd-project/okd/releases/latest" \
    | jq -r '.assets[] | select(.name | test("^openshift-client-linux.*\\.tar\\.gz$")) | .browser_download_url' \
    | head -n1
}

install_client(){
  ensure_dirs

  if ! command -v tar >/dev/null 2>&1; then
    echo "Error: 'tar' not found. Please install tar and retry." >&2
    return 1
  fi

  okd_tag=$(latest_okd_tag)
  if [ -z "$okd_tag" ] || [ "$okd_tag" = "null" ]; then
    echo "Error: could not determine latest OKD release tag." >&2
    return 1
  fi

  client_url=$(latest_client_url)
  if [ -z "$client_url" ]; then
    echo "Error: could not find Linux OpenShift client asset in latest OKD release." >&2
    return 1
  fi

  echo "▶ Latest OKD release: ${okd_tag}"
  echo "▶ Downloading OpenShift client from: ${client_url}"
  curl -fsSL "$client_url" -o "$TMPDIR/openshift-client.tar.gz"

  tar -xzf "$TMPDIR/openshift-client.tar.gz" -C "$TMPDIR"

  if [ ! -f "$TMPDIR/oc" ]; then
    echo "Error: expected oc binary not found in archive." >&2
    return 1
  fi

  install -m0755 "$TMPDIR/oc" "$LOCAL_BIN/oc"
  echo "✅ Installed oc to ${LOCAL_BIN}/oc"

  if [ -f "$TMPDIR/kubectl" ]; then
    if command -v kubectl >/dev/null 2>&1; then
      echo "ℹ kubectl already exists on PATH; skipping install from OpenShift tarball."
      rm -f "$KUBECTL_MANAGED_MARKER" || true
    else
      install -m0755 "$TMPDIR/kubectl" "$LOCAL_BIN/kubectl"
      : > "$KUBECTL_MANAGED_MARKER"
      echo "✅ Installed kubectl to ${LOCAL_BIN}/kubectl"
    fi
  else
    rm -f "$KUBECTL_MANAGED_MARKER" || true
    echo "ℹ kubectl binary not found in archive; continuing with oc only."
  fi

  if command -v oc >/dev/null 2>&1; then
    echo "✅ oc version: $(oc version --client 2>/dev/null | head -n1 || true)"
  else
    echo "⚠ oc not on PATH. Add 'export PATH=\"$HOME/.local/bin:\$PATH\"' to your shell profile." >&2
  fi
}

remove_client(){
  echo "▶ Removing OpenShift client binaries from ${LOCAL_BIN}"

  target_oc="$LOCAL_BIN/oc"
  if [ -e "$target_oc" ]; then
    rm -f "$target_oc" || true
  fi

  target_kubectl="$LOCAL_BIN/kubectl"
  if [ -f "$KUBECTL_MANAGED_MARKER" ]; then
    if [ -e "$target_kubectl" ]; then
      rm -f "$target_kubectl" || true
    fi
    rm -f "$KUBECTL_MANAGED_MARKER" || true
    echo "✅ Removed kubectl installed by this script (if present)."
  else
    echo "ℹ Skipping kubectl removal (not installed by this script)."
  fi

  echo "✅ OpenShift client binaries removed (if present)."
}

status(){
  echo "-- PATH includes $LOCAL_BIN? --"
  if check_path; then
    echo "Yes: $LOCAL_BIN is in PATH"
  else
    echo "No: $LOCAL_BIN is NOT in PATH"
    echo "Add: export PATH=\"$HOME/.local/bin:\$PATH\" to your shell rc (e.g., ~/.profile, ~/.bashrc)"
  fi

  echo "-- oc --"
  if command -v oc >/dev/null 2>&1; then
    oc version --client 2>/dev/null | head -n1 || true
  else
    echo "oc: not found"
  fi

  echo "-- kubectl --"
  if command -v kubectl >/dev/null 2>&1; then
    kubectl version --client=true --short 2>/dev/null | head -n1 || kubectl version --client=true 2>/dev/null | head -n1 || true
  else
    echo "kubectl: not found"
  fi
}

case "$cmd" in
  install)
    install_client
    ;;
  update)
    install_client
    ;;
  remove)
    remove_client
    ;;
  status)
    status
    ;;
  *)
    usage
    ;;
esac
