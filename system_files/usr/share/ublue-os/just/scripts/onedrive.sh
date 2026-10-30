#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "🔐 OneDrive setup & authentication"
echo ""

if ! systemctl --user is-enabled onedrive.service >/dev/null 2>&1; then
  echo "▶ Enabling OneDrive user service..."
  systemctl --user enable onedrive.service
fi

if systemctl --user is-active onedrive.service >/dev/null 2>&1; then
  echo "▶ Stopping OneDrive service before authentication..."
  systemctl --user stop onedrive.service
fi

echo "A browser window will open. Log in with your Microsoft account to authorize OneDrive."
echo "You need to copy the URL from the browser and paste it back here to complete the authentication."
echo "Be fast because the URL is shown only for a short time!"

MAX_ATTEMPTS=3
attempt=1
while true; do
  echo "▶ Auth attempt $attempt of $MAX_ATTEMPTS..."
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
    sleep 2
  fi
done

echo "▶ Starting OneDrive service..."
systemctl --user start onedrive.service

echo ""
echo "✅ OneDrive is authenticated and running."
echo ""
echo "📊 Status:"
systemctl --user status onedrive.service --no-pager || true
