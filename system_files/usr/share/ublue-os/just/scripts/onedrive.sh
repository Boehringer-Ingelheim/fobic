#!/usr/bin/env bash
set -euo pipefail

usage(){
  echo "Usage: $0 auth|service"
  exit 2
}

cmd=${1:-}
[ -n "$cmd" ] || usage

case "$cmd" in
  auth)
    echo ""
    echo "🔐 OneDrive (re)authentication"
    echo ""
    echo "A browser window will open. Log in with your Microsoft account to authorize OneDrive."
    echo ""
    if systemctl --user is-enabled onedrive.service >/dev/null 2>&1; then
      echo "ℹ OneDrive service is already enabled. Stop it before reauthenticating to avoid conflicts."
      systemctl --user stop onedrive.service
    fi

    MAX_ATTEMPTS=3
    attempt=1
    while true; do
      echo "▶ Reauth attempt $attempt of $MAX_ATTEMPTS..."
      if onedrive --reauth; then
        echo "✅ Authentication succeeded."
        break
      else
        echo "⚠ Authentication attempt $attempt failed."
        if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
          echo "❌ All authentication attempts failed."
          exit 1
        fi
        attempt=$((attempt + 1))
        echo "⏳ Waiting before retrying..."
        sleep 2
      fi
    done
    if systemctl --user is-enabled onedrive.service >/dev/null 2>&1; then
      echo "ℹ Restart it after reauthentication to apply changes."
      systemctl --user restart onedrive.service
    fi
    ;;
  service)
    echo ""
    echo "⚙ OneDrive service setup"
    echo ""

    if systemctl --user is-enabled onedrive.service >/dev/null 2>&1; then
      echo "ℹ OneDrive service is already enabled."
    else
      echo "▶ Enabling OneDrive user service..."
      systemctl --user enable onedrive.service
    fi

    echo "▶ Starting OneDrive user service..."
    systemctl --user start onedrive.service || true

    echo ""
    echo "✅ OneDrive sync service is running."
    echo ""
    echo "📊 Status:"
    systemctl --user status onedrive.service --no-pager || true
    ;;
  *)
    usage
    ;;
esac
