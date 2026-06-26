#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 enable|disable"
  exit 2
}

cmd=${1:-}
[ -n "$cmd" ] || usage

UNIT_PATH="$HOME/.config/systemd/user/ssh-add.service"
SSH_DIR="$HOME/.ssh"

# Filter private keys
list_private_keys() {
  find "$SSH_DIR" -maxdepth 1 -type f \
    ! -name "*.pub" \
    ! -name "known_hosts*" \
    ! -name "config" \
    ! -name "*.old" \
    ! -name "*.bak" \
    -perm -u+r
}

select_keys() {
  local keys=("$@")
  local selected=()

  # Use fzf if available (multi-select)
  if command -v fzf >/dev/null 2>&1; then
    mapfile -t selected < <(printf '%s\n' "${keys[@]}" | fzf -m --prompt="Select SSH keys > ")
  else
    echo "Select SSH keys (enter numbers, empty line to finish):"
    select key in "${keys[@]}"; do
      [[ -n "${key:-}" ]] && selected+=("$key")
    done
  fi

  printf '%s\n' "${selected[@]}"
}

case "$cmd" in
  enable)
    mkdir -p "$(dirname "$UNIT_PATH")"

    mapfile -t ALL_KEYS < <(list_private_keys)

    if [ "${#ALL_KEYS[@]}" -eq 0 ]; then
      echo "❌ No private SSH keys found in $SSH_DIR"
      exit 1
    fi

    mapfile -t SELECTED_KEYS < <(select_keys "${ALL_KEYS[@]}")

    if [ "${#SELECTED_KEYS[@]}" -eq 0 ]; then
      echo "❌ No keys selected."
      exit 1
    fi

    echo "▶ Adding selected keys to agent:"
    for k in "${SELECTED_KEYS[@]}"; do
      echo "  + $k"
      ssh-add "$k"
    done

    # Build ExecStart with all keys
    EXEC_START="/usr/bin/ssh-add"
    for k in "${SELECTED_KEYS[@]}"; do
      EXEC_START+=" %h/.ssh/$(basename "$k")"
    done

    cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Add SSH keys to agent
After=ssh-agent.socket
Requires=ssh-agent.socket

[Service]
Type=oneshot
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=$EXEC_START
RemainAfterExit=yes

[Install]
WantedBy=default.target
UNIT

    echo "▶ Reloading systemd user daemon and enabling service..."
    systemctl --user daemon-reload
    systemctl --user enable --now ssh-add.service

    echo "✅ ssh-add.service enabled with ${#SELECTED_KEYS[@]} key(s)."
    ;;

  disable)
    echo "▶ Disabling ssh-add.service"
    systemctl --user disable --now ssh-add.service || true

    if command -v ssh-add >/dev/null 2>&1; then
      echo "▶ Removing all identities from ssh-agent"
      ssh-add -D || true
    fi

    echo "▶ Removing unit file"
    rm -f "$UNIT_PATH"
    systemctl --user daemon-reload || true

    echo "✅ ssh-add.service disabled and unit removed."
    ;;

  *)
    usage
    ;;
esac
