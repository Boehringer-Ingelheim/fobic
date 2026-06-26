#!/usr/bin/env bash

set -euo pipefail

AWS_CONFIG="$HOME/.aws/config"
SSH_CONFIG="$HOME/.ssh/config"
MARKER_BEGIN="# BEGIN TEAMSPACE MANAGED"
MARKER_END="# END TEAMSPACE MANAGED"

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "❌ $*" >&2; exit 1; }

# ── precheck: required tools ──────────────────────────────────────────────────

check_dependencies() {
  if ! command -v aws &>/dev/null; then
    die "⚠️ AWS CLI is not installed or not in PATH.\nRequired: AWS CLI v2 + Session Manager plugin.\nUse ujust to install"
  fi
  if ! command -v session-manager-plugin &>/dev/null; then
    die "⚠️ AWS Session Manager plugin is not installed or not in PATH.\nRequired: AWS CLI v2 + Session Manager plugin.\nUse ujust to install"
  fi
}

check_dependencies

backup() {
  local file="$1"
  cp "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
}

# Extract content between managed markers to stdout
managed_extract() {
  local file="$1"
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    { sub(/\r$/, "") }
    $0==b{f=1;next} $0==e{f=0} f
  ' "$file"
}

# Replace content inside managed markers with content from a temp file
managed_replace() {
  local file="$1" content_file="$2" _tmp
  _tmp="$(mktemp)"
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" -v cf="$content_file" '
    { sub(/\r$/, "") }
    $0 == b { print; while((getline l < cf)>0) print l; close(cf); skip=1; next }
    $0 == e { skip=0; print; next }
    !skip   { print }
  ' "$file" > "$_tmp" && mv "$_tmp" "$file"
}

# Return profile names from the managed AWS block
list_profiles() {
  managed_extract "$AWS_CONFIG" | grep -oP '(?<=^\[profile )\S+(?=\])' || true
}

# ── init: ensure managed blocks exist ────────────────────────────────────────

ensure_managed_aws() {
  grep -qF "$MARKER_BEGIN" "$AWS_CONFIG" 2>/dev/null && return 0

  echo "⚡ Initializing managed block in ${AWS_CONFIG}..."
  backup "$AWS_CONFIG"

  # Detect profile names: any [profile X] (except default/BI-WCDEUseCases)
  # that has a matching [sso-session X] block AND all required SSO fields
  mapfile -t _FOUND < <(
    grep -oP '(?<=^\[profile )\S+(?=\])' "$AWS_CONFIG" \
    | grep -v -e '^default$' \
    | while read -r _p; do
        # Must have a paired sso-session block
        grep -qF "[sso-session ${_p}]" "$AWS_CONFIG" || continue
        # Must have sso_account_id and sso_role_name in the [profile X] section
        if awk -v name="$_p" '
          { sub(/\r$/, "") }
          /^\[/ { in_sec=0 }
          /^\[profile / { p=$0; sub(/^\[profile /,"",p); sub(/\].*/,"",p); in_sec=(p==name); next }
          in_sec && /^sso_account_id[ \t]*=/ { has_id=1 }
          in_sec && /^sso_role_name[ \t]*=/ { has_role=1 }
          END { exit !(has_id && has_role) }
        ' "$AWS_CONFIG"; then
          echo "$_p"
        fi
      done
  )

  local _managed
  _managed="$(mktemp)"

  if [[ ${#_FOUND[@]} -gt 0 ]]; then
    echo "⚡ Profiles detected for migration:"
    printf '    \u2022 %s\n' "${_FOUND[@]}"

    # Build a lookup string for awk ("name1 name2 name3")
    local _names
    _names="${_FOUND[*]}"

    # Line-by-line INI section tracking: safer than paragraph mode because
    # it works regardless of whether blank lines exist between sections.
    # Extract [profile X] and its paired [sso-session X] for every wanted profile.
    awk -v names="$_names" '
      BEGIN { n=split(names,a); for(i=1;i<=n;i++) w[a[i]]=1; keep=0 }
      /^\[profile /    { p=$0; sub(/^\[profile /,"",p);    sub(/\].*/,"",p); keep=(p in w) }
      /^\[sso-session / { p=$0; sub(/^\[sso-session /,"",p); sub(/\].*/,"",p); keep=(p in w) }
      /^\[/ && !/^\[profile / && !/^\[sso-session / { keep=0 }
      keep { print }
    ' "$AWS_CONFIG" | tr -d '\r' > "$_managed"

    # Remove those sections from the main config (keep everything else).
    awk -v names="$_names" '
      BEGIN { n=split(names,a); for(i=1;i<=n;i++) w[a[i]]=1; skip=0 }
      /^\[profile /    { p=$0; sub(/^\[profile /,"",p);    sub(/\].*/,"",p); skip=(p in w) }
      /^\[sso-session / { p=$0; sub(/^\[sso-session /,"",p); sub(/\].*/,"",p); skip=(p in w) }
      /^\[/ && !/^\[profile / && !/^\[sso-session / { skip=0 }
      !skip { print }
    ' "$AWS_CONFIG" \
    | awk 'BEGIN{blank=0} /^[[:space:]]*$/{if(blank<1){blank++;print}; next} {blank=0; print}' \
    > "${AWS_CONFIG}.tmp" && mv "${AWS_CONFIG}.tmp" "$AWS_CONFIG"
  fi

  printf '\n%s\n' "$MARKER_BEGIN" >> "$AWS_CONFIG"
  cat "$_managed" >> "$AWS_CONFIG"
  printf '%s\n' "$MARKER_END" >> "$AWS_CONFIG"
  rm -f "$_managed"
}

ensure_managed_ssh() {
  grep -qF "$MARKER_BEGIN" "$SSH_CONFIG" 2>/dev/null && return 0

  echo "⚡ Initializing managed block in ${SSH_CONFIG}..."
  backup "$SSH_CONFIG"

  local _managed
  _managed="$(mktemp)"
  awk 'BEGIN{RS=""; ORS="\n\n"} /ProxyCommand.*ssm start-session/' "$SSH_CONFIG" > "$_managed" || true

  if [[ -s "$_managed" ]]; then
    echo "  SSH host entries detected for migration:"
    awk '/^Host /{print "    \u2022", $2}' "$_managed"
    awk 'BEGIN{RS=""; ORS="\n\n"} !/ProxyCommand.*ssm start-session/' "$SSH_CONFIG" \
    > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"
  fi

  if grep -q '^Host \* !i-\*' "$SSH_CONFIG"; then
    awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" -v mf="$_managed" '
      /^Host \* !i-\*/ {
        print b
        while ((getline l < mf) > 0) print l
        close(mf)
        print e
        print ""
      }
      { print }
    ' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"
  else
    printf '\n%s\n' "$MARKER_BEGIN" >> "$SSH_CONFIG"
    cat "$_managed" >> "$SSH_CONFIG"
    printf '%s\n' "$MARKER_END" >> "$SSH_CONFIG"
  fi
  rm -f "$_managed"
}

# ── add ───────────────────────────────────────────────────────────────────────

cmd_add() {
  ensure_managed_aws
  ensure_managed_ssh
  echo "=== Add new Teamspace profile ==="

  read -rp "❯ Profile name (sso_session): " PROFILE_NAME
  [[ -n "$PROFILE_NAME" ]] || die "⚠️ Profile name cannot be empty."

  # Check for duplicates in managed block
  if managed_extract "$AWS_CONFIG" | grep -qF "[profile ${PROFILE_NAME}]" 2>/dev/null; then
    die "⚠️ Profile '${PROFILE_NAME}' already exists."
  fi

  read -rp "❯ SSO Account ID (sso_account_id): " ACCOUNT_ID
  [[ -n "$ACCOUNT_ID" ]] || die "⚠️ Account ID cannot be empty."

  # ── backup both config files upfront ─────────────────────────────────────
  backup "$AWS_CONFIG"
  backup "$SSH_CONFIG"

  # ── .aws/config (managed block) ──────────────────────────────────────────
  local _aws_tmp
  _aws_tmp="$(mktemp)"
  managed_extract "$AWS_CONFIG" > "$_aws_tmp"
  cat >> "$_aws_tmp" <<EOF

[profile ${PROFILE_NAME}]
sso_session = ${PROFILE_NAME}
sso_account_id = ${ACCOUNT_ID}
sso_role_name = BI-WCDEUseCases
region = eu-west-1
[sso-session ${PROFILE_NAME}]
sso_start_url = https://d-936706e69b.awsapps.com/start
sso_region = eu-west-1
sso_registration_scopes = sso:account:access
EOF
  managed_replace "$AWS_CONFIG" "$_aws_tmp"
  rm -f "$_aws_tmp"

  echo "✅ AWS profile '${PROFILE_NAME}' added to ${AWS_CONFIG}."

  # ── select EC2 instances ─────────────────────────────────────────────────
  local -a SELECTED_INSTANCES=()   # elements: "instance_id\tinstance_name"
  echo "🔐 Logging in to AWS SSO for profile '${PROFILE_NAME}'..."
  if aws sso login --profile "$PROFILE_NAME"; then
    echo "🔍 Querying EC2 instances..."
    RAW_INSTANCES=$(aws ec2 describe-instances \
      --profile "$PROFILE_NAME" \
      --filters "Name=instance-state-name,Values=running,stopped" \
      --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value|[0]]' \
      --output text 2>/dev/null || true)

    if [[ -n "$RAW_INSTANCES" ]]; then
      mapfile -t INSTANCE_LINES <<< "$RAW_INSTANCES"
      echo "Select instances to add (space-separated numbers, 'all', or 0 to enter manually):"
      for i in "${!INSTANCE_LINES[@]}"; do
        local _iid _iname
        _iid=$(awk '{print $1}' <<< "${INSTANCE_LINES[$i]}")
        _iname=$(awk '{print $2}' <<< "${INSTANCE_LINES[$i]}")
        if [[ -n "$_iname" && "$_iname" != "None" ]]; then
          printf "  %d) %s  (%s)\n" "$((i+1))" "$_iid" "$_iname"
        else
          printf "  %d) %s\n" "$((i+1))" "$_iid"
        fi
      done
      echo "  0) Enter manually"
      read -rp "❯ Enter selection: " SEL

      if [[ "$SEL" == "all" ]]; then
        for line in "${INSTANCE_LINES[@]}"; do
          local _iid _iname
          _iid=$(awk '{print $1}' <<< "$line")
          _iname=$(awk '{print $2}' <<< "$line")
          [[ "$_iname" == "None" ]] && _iname=""
          SELECTED_INSTANCES+=("${_iid}"$'\t'"${_iname:-$PROFILE_NAME}")
        done
      elif [[ "$SEL" != "0" ]]; then
        for num in $SEL; do
          [[ "$num" =~ ^[0-9]+$ ]] || { echo "⚠️ Skipping invalid: $num"; continue; }
          local _idx=$((num - 1))
          [[ "$_idx" -ge 0 && "$_idx" -lt ${#INSTANCE_LINES[@]} ]] || { echo "⚠️ $num out of range, skipping."; continue; }
          local _iid _iname
          _iid=$(awk '{print $1}' <<< "${INSTANCE_LINES[$_idx]}")
          _iname=$(awk '{print $2}' <<< "${INSTANCE_LINES[$_idx]}")
          [[ "$_iname" == "None" ]] && _iname=""
          SELECTED_INSTANCES+=("${_iid}"$'\t'"${_iname:-$PROFILE_NAME}")
        done
      fi
    else
      echo "⚠️ No EC2 instances found for profile '${PROFILE_NAME}'."
    fi
  else
    echo "⚠️ SSO login failed."
  fi

  # Manual entry fallback (SEL=0 or no instances found or SSO failed)
  if [[ ${#SELECTED_INSTANCES[@]} -eq 0 ]]; then
    local _manual_id
    read -rp "❯ EC2 Instance ID (e.g. i-0abc123def456): " _manual_id
    [[ -n "$_manual_id" ]] || die "⚠️ Instance ID cannot be empty."
    SELECTED_INSTANCES+=("${_manual_id}"$'\t'"${PROFILE_NAME}")
  fi

  # ── .ssh/config (managed block) ──────────────────────────────────────────
  local _ssh_tmp
  _ssh_tmp="$(mktemp)"
  managed_extract "$SSH_CONFIG" > "$_ssh_tmp"
  for _entry in "${SELECTED_INSTANCES[@]}"; do
    local _iid _iname
    _iid=$(cut -f1 <<< "$_entry")
    _iname=$(cut -f2 <<< "$_entry")
    printf '# %s\nHost %s\n    HostName %s\n    User ec2-user\n    ProxyCommand aws --profile %s ssm start-session --target %%h --document-name AWS-StartSSHSession --parameters portNumber=%%p\n\n' \
      "$_iname" "$_iid" "$_iid" "$PROFILE_NAME" >> "$_ssh_tmp"
  done
  managed_replace "$SSH_CONFIG" "$_ssh_tmp"
  rm -f "$_ssh_tmp"

  echo "✅ SSH hosts added to ${SSH_CONFIG}:"
  for _entry in "${SELECTED_INSTANCES[@]}"; do
    local _iid _iname
    _iid=$(cut -f1 <<< "$_entry")
    _iname=$(cut -f2 <<< "$_entry")
    if [[ "$_iname" != "$PROFILE_NAME" ]]; then
      printf "   • %s  (%s)\n" "$_iid" "$_iname"
    else
      printf "   • %s\n" "$_iid"
    fi
  done
}

# ── show ─────────────────────────────────────────────────────────────────────

cmd_show() {
  ensure_managed_aws
  ensure_managed_ssh
  echo "=== Existing Teamspace profiles ==="

  mapfile -t PROFILES < <(list_profiles)

  if [[ ${#PROFILES[@]} -eq 0 ]]; then
    echo "⚠️ No Teamspace profiles found."
    return
  fi

  for PROFILE in "${PROFILES[@]}"; do
    ACCOUNT_ID=$(managed_extract "$AWS_CONFIG" | grep -A5 "^\[profile ${PROFILE}\]" | grep 'sso_account_id' | awk -F'= ' '{print $2}' || true)
    INSTANCE_ID=$(managed_extract "$SSH_CONFIG" | grep -B3 "ProxyCommand aws --profile ${PROFILE} " | grep '^Host ' | awk '{print $2}' || true)
    echo "  Profile:     ${PROFILE}"
    echo "  Account ID:  ${ACCOUNT_ID:-n/a}"
    echo "  Instance ID: ${INSTANCE_ID:-n/a}"
    echo
  done
}

# ── sync ─────────────────────────────────────────────────────────────────────

cmd_sync() {
  ensure_managed_aws
  ensure_managed_ssh
  echo "=== Sync Teamspace instances ==="

  mapfile -t PROFILES < <(list_profiles)

  if [[ ${#PROFILES[@]} -eq 0 ]]; then
    echo "⚠️ No Teamspace profiles found."
    exit 0
  fi

  echo "❯ Select a profile to sync:"
  for i in "${!PROFILES[@]}"; do
    CURRENT=$(managed_extract "$SSH_CONFIG" | grep -B3 "ProxyCommand aws --profile ${PROFILES[$i]} " | grep '^Host ' | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//' || true)
    printf "  %d) %-30s [current: %s]\n" "$((i+1))" "${PROFILES[$i]}" "${CURRENT:-none}"
  done

  read -rp "❯ Enter number: " SELECTION
  [[ "$SELECTION" =~ ^[0-9]+$ ]] || die "⚠️ Invalid selection."
  INDEX=$((SELECTION - 1))
  [[ "$INDEX" -ge 0 && "$INDEX" -lt ${#PROFILES[@]} ]] || die "⚠️ Selection out of range."

  PROFILE_NAME="${PROFILES[$INDEX]}"

  # ── SSO login + query ─────────────────────────────────────────────────────
  echo "🔐 Logging in to AWS SSO for profile '${PROFILE_NAME}'..."
  aws sso login --profile "$PROFILE_NAME" || die "⚠️ SSO login failed."

  echo "🔍 Querying EC2 instances..."
  RAW_INSTANCES=$(aws ec2 describe-instances \
    --profile "$PROFILE_NAME" \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || true)

  if [[ -z "$RAW_INSTANCES" ]]; then
    echo "⚠️ No EC2 instances found for profile '${PROFILE_NAME}'. SSH config unchanged."
    exit 0
  fi

  echo "✅ Instances found:"
  while IFS=$'\t' read -r iid iname; do
    if [[ -n "$iname" && "$iname" != "None" ]]; then
      printf "  • %s  (%s)\n" "$iid" "$iname"
    else
      printf "  • %s\n" "$iid"
    fi
  done <<< "$RAW_INSTANCES"

  # ── .ssh/config (managed block) ──────────────────────────────────────────
  backup "$SSH_CONFIG"

  local _ssh_tmp
  _ssh_tmp="$(mktemp)"
  # Remove old blocks for this profile from managed content
  managed_extract "$SSH_CONFIG" | awk -v profile="$PROFILE_NAME" '
    BEGIN { RS=""; ORS="\n\n" }
    index($0, "--profile " profile " ") == 0
  ' > "$_ssh_tmp"

  # Append new blocks
  while IFS=$'\t' read -r _iid _iname; do
    _iname="${_iname:-$PROFILE_NAME}"
    printf '# %s\nHost %s\n    HostName %s\n    User ec2-user\n    ProxyCommand aws --profile %s ssm start-session --target %%h --document-name AWS-StartSSHSession --parameters portNumber=%%p\n\n' \
      "$_iname" "$_iid" "$_iid" "$PROFILE_NAME" >> "$_ssh_tmp"
  done <<< "$RAW_INSTANCES"

  managed_replace "$SSH_CONFIG" "$_ssh_tmp"
  rm -f "$_ssh_tmp"

  echo "✅ SSH config synced for profile '${PROFILE_NAME}'."
}

# ── delete ────────────────────────────────────────────────────────────────────

cmd_delete() {
  ensure_managed_aws
  ensure_managed_ssh
  echo "=== Delete Teamspace profile ==="

  mapfile -t PROFILES < <(list_profiles)

  if [[ ${#PROFILES[@]} -eq 0 ]]; then
    echo "⚠️ No removable profiles found in ${AWS_CONFIG}."
    exit 0
  fi

  echo "❯ Select a profile to delete:"
  for i in "${!PROFILES[@]}"; do
    echo "  $((i+1))) ${PROFILES[$i]}"
  done

  read -rp "❯ Enter number: " SELECTION
  [[ "$SELECTION" =~ ^[0-9]+$ ]] || die "Invalid selection."
  INDEX=$((SELECTION - 1))
  [[ "$INDEX" -ge 0 && "$INDEX" -lt ${#PROFILES[@]} ]] || die "Selection out of range."

  PROFILE_NAME="${PROFILES[$INDEX]}"

  read -rp "❯ Delete profile '${PROFILE_NAME}'? [y/N] " CONFIRM
  [[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }

  # ── backup both config files upfront ─────────────────────────────────────
  backup "$AWS_CONFIG"
  backup "$SSH_CONFIG"

  # ── .aws/config (managed block) ──────────────────────────────────────────
  local _aws_tmp
  _aws_tmp="$(mktemp)"
  managed_extract "$AWS_CONFIG" | awk -v name="$PROFILE_NAME" '
    /^\[/ { skip = ($0 == "[profile " name "]" || $0 == "[sso-session " name "]") }
    !skip
  ' | awk 'BEGIN{blank=0} /^[[:space:]]*$/{if(blank<1){blank++;print}; next} {blank=0; print}' \
  > "$_aws_tmp"
  managed_replace "$AWS_CONFIG" "$_aws_tmp"
  rm -f "$_aws_tmp"

  echo "✅ AWS profile '${PROFILE_NAME}' removed from ${AWS_CONFIG}."

  # ── .ssh/config (managed block) ──────────────────────────────────────────
  if managed_extract "$SSH_CONFIG" | grep -q "ProxyCommand aws --profile ${PROFILE_NAME} "; then
    local _ssh_tmp
    _ssh_tmp="$(mktemp)"
    managed_extract "$SSH_CONFIG" | awk -v profile="$PROFILE_NAME" '
      BEGIN { RS=""; ORS="\n\n" }
      index($0, "--profile " profile " ") == 0
    ' > "$_ssh_tmp"
    managed_replace "$SSH_CONFIG" "$_ssh_tmp"
    rm -f "$_ssh_tmp"
    echo "✅ SSH host entry for profile '${PROFILE_NAME}' removed from ${SSH_CONFIG}."
  else
    echo "⚠️ No SSH host entry found for profile '${PROFILE_NAME}' — skipping SSH config."
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 [add|delete|show|sync]"
  echo "  add     Add a new Teamspace profile to ~/.aws/config and ~/.ssh/config"
  echo "  delete  Remove an existing Teamspace profile from both config files"
  echo "  show    List all existing Teamspace profiles"
  echo "  sync    Re-query instances and update the SSH host for a profile"
}

case "${1:-}" in
  add)    cmd_add ;;
  delete) cmd_delete ;;
  show)   cmd_show ;;
  sync)   cmd_sync ;;
  *)
    echo "What would you like to do?"
    echo "  1) Add a new Teamspace profile"
    echo "  2) Delete an existing Teamspace profile"
    echo "  3) Show existing Teamspace profiles"
    echo "  4) Sync instance for a Teamspace profile"
    read -rp "❯ Enter choice [1/2/3/4]: " CHOICE
    case "$CHOICE" in
      1) cmd_add ;;
      2) cmd_delete ;;
      3) cmd_show ;;
      4) cmd_sync ;;
      *) usage; exit 1 ;;
    esac
    ;;
esac
