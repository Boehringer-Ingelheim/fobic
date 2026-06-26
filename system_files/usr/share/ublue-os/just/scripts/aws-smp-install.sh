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
AWS_INSTALL_DIR="$HOME/.local/aws-cli"

ensure_dirs(){
  mkdir -p "$LOCAL_BIN"
}

check_path(){
  if echo ":$PATH:" | grep -q ":${LOCAL_BIN}:"; then
    return 0
  else
    return 1
  fi
}

install_aws(){
  ensure_dirs
  echo "▶ Downloading AWS CLI..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$TMPDIR/awscliv2.zip"
  if ! command -v unzip >/dev/null 2>&1; then
    echo "Error: 'unzip' not found. Please install unzip and retry." >&2
    return 1
  fi
  unzip -q "$TMPDIR/awscliv2.zip" -d "$TMPDIR"
  echo "▶ Installing AWS CLI to ${AWS_INSTALL_DIR} and symlinks to ${LOCAL_BIN}"
  "$TMPDIR/aws/install" -i "$AWS_INSTALL_DIR" -b "$LOCAL_BIN" || {
    echo "Installer reported an error; attempting to remove any partial install and retrying..."
    rm -rf "$AWS_INSTALL_DIR" || true
    "$TMPDIR/aws/install" -i "$AWS_INSTALL_DIR" -b "$LOCAL_BIN" || {
      echo "AWS CLI install failed." >&2
      return 1
    }
  }
  if command -v aws >/dev/null 2>&1; then
    echo "✅ AWS CLI installed: $(aws --version 2>&1 | head -n1)"
  else
    echo "⚠ aws not on PATH. Add 'export PATH=\"$HOME/.local/bin:\$PATH\"' to your shell profile." >&2
  fi
}

install_smp(){
  ensure_dirs
  echo "▶ Downloading Session Manager Plugin RPM..."
  curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "$TMPDIR/session-manager-plugin.rpm"
  if ! command -v rpm2cpio >/dev/null 2>&1 || ! command -v cpio >/dev/null 2>&1; then
    echo "Error: 'rpm2cpio' or 'cpio' not found. Please install them and retry." >&2
    return 1
  fi
  (cd "$TMPDIR" && rpm2cpio session-manager-plugin.rpm | cpio -idmv)
  if [ -f "$TMPDIR/usr/local/sessionmanagerplugin/bin/session-manager-plugin" ]; then
    cp "$TMPDIR/usr/local/sessionmanagerplugin/bin/session-manager-plugin" "$LOCAL_BIN/"
    chmod +x "$LOCAL_BIN/session-manager-plugin"
    if command -v session-manager-plugin >/dev/null 2>&1; then
      echo "✅ session-manager-plugin installed: $(session-manager-plugin --version 2>&1 | head -n1)"
    else
      echo "⚠ session-manager-plugin not on PATH. Add 'export PATH=\"$HOME/.local/bin:\$PATH\"' to your shell profile." >&2
    fi
  else
    echo "Error: extracted session-manager-plugin binary not found." >&2
    return 1
  fi
}

remove_aws(){
  echo "▶ Removing AWS CLI install directory: ${AWS_INSTALL_DIR}"
  # Remove install dir
  rm -rf "$AWS_INSTALL_DIR"

  # Remove symlinks/wrappers only if they point into the removed install dir or are broken
  for f in aws aws_completer; do
    target="$LOCAL_BIN/$f"
    if [ -L "$target" ]; then
      resolved=$(readlink -f "$target" 2>/dev/null || true)
      if [ -z "$resolved" ] || [[ "$resolved" == "$AWS_INSTALL_DIR"* ]]; then
        rm -f "$target" || true
      fi
    elif [ -e "$target" ]; then
      # If file exists but points to removed dir (broken), remove it
      if ! [ -e "$(readlink -f "$target" 2>/dev/null || true)" ]; then
        rm -f "$target" || true
      fi
    fi
  done

  echo "✅ AWS CLI removed (if present)."
}

remove_smp(){
  echo "▶ Removing session-manager-plugin from ${LOCAL_BIN}"
  target="$LOCAL_BIN/session-manager-plugin"
  if [ -e "$target" ]; then
    rm -f "$target" || true
  fi
  echo "✅ session-manager-plugin removed (if present)."
}

status(){
  echo "-- PATH includes $LOCAL_BIN? --"
  if check_path; then
    echo "Yes: $LOCAL_BIN is in PATH"
  else
    echo "No: $LOCAL_BIN is NOT in PATH"
    echo "Add: export PATH=\"$HOME/.local/bin:\$PATH\" to your shell rc (e.g., ~/.profile, ~/.bashrc)"
  fi

  echo "-- aws --"
  if command -v aws >/dev/null 2>&1; then
    aws --version 2>&1 | head -n1
  else
    echo "aws: not found"
  fi

  echo "-- session-manager-plugin --"
  if command -v session-manager-plugin >/dev/null 2>&1; then
    session-manager-plugin --version 2>&1 | head -n1 || true
  else
    echo "session-manager-plugin: not found"
  fi
}

case "$cmd" in
  install)
    install_aws
    install_smp
    ;;
  update)
    install_aws
    install_smp
    ;;
  remove)
    remove_smp
    remove_aws
    ;;
  status)
    status
    ;;
  *)
    usage
    ;;
esac
