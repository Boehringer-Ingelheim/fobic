#!/usr/bin/env bash

set -euo pipefail

SSH_CONFIG="${HOME}/.ssh/config"

if [[ ! -f "$SSH_CONFIG" ]]; then
  echo "❌ No SSH config found at $SSH_CONFIG"
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse ~/.ssh/config for Host entries starting with "i-"
# Extracts: Host, Hostname, User, AWS profile (from ProxyCommand --profile)
# ---------------------------------------------------------------------------
declare -a ALL_HOSTS=()
declare -a ALL_HOSTNAMES=()
declare -a ALL_PROFILES=()
declare -a ALL_USERS=()

current_host=""
current_hostname=""
current_profile=""
current_user="ec2-user"

_flush_host() {
  if [[ -n "$current_host" && "$current_host" =~ ^i- ]]; then
    ALL_HOSTS+=("$current_host")
    ALL_HOSTNAMES+=("${current_hostname:-$current_host}")
    ALL_PROFILES+=("$current_profile")
    ALL_USERS+=("$current_user")
  fi
}

while IFS= read -r line || [[ -n "$line" ]]; do
  trimmed="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace

  if [[ "$trimmed" =~ ^[Hh]ost[[:space:]]+(.+)$ ]]; then
    host_val="${BASH_REMATCH[1]}"
    _flush_host
    # Skip wildcard / multi-host patterns
    if [[ "$host_val" == *" "* || "$host_val" == *"*"* || "$host_val" == *"?"* ]]; then
      current_host=""
    else
      current_host="$host_val"
    fi
    current_hostname=""
    current_profile=""
    current_user="ec2-user"
  elif [[ -n "$current_host" ]]; then
    if [[ "$trimmed" =~ ^[Hh]ostname[[:space:]]+(.+)$ ]]; then
      current_hostname="${BASH_REMATCH[1]}"
    elif [[ "$trimmed" =~ ^[Pp]roxy[Cc]ommand[[:space:]]+(.+)$ ]]; then
      proxy_cmd="${BASH_REMATCH[1]}"
      if [[ "$proxy_cmd" =~ --profile[[:space:]]+([^[:space:]]+) ]]; then
        profile_val="${BASH_REMATCH[1]}"
        # Ignore shell variable references (e.g. $AWS_PROFILE)
        if [[ "$profile_val" != \$* ]]; then
          current_profile="$profile_val"
        fi
      fi
    elif [[ "$trimmed" =~ ^[Uu]ser[[:space:]]+(.+)$ ]]; then
      current_user="${BASH_REMATCH[1]}"
    fi
  fi
done < "$SSH_CONFIG"
_flush_host

if [[ ${#ALL_HOSTS[@]} -eq 0 ]]; then
  echo "❌ No SSH config entries found for hosts starting with 'i-' in $SSH_CONFIG"
  exit 1
fi

# ---------------------------------------------------------------------------
# Select AWS profile
# ---------------------------------------------------------------------------
declare -a UNIQUE_PROFILES=()
for profile in "${ALL_PROFILES[@]}"; do
  already=false
  for p in "${UNIQUE_PROFILES[@]+"${UNIQUE_PROFILES[@]}"}"; do
    [[ "$p" == "$profile" ]] && already=true && break
  done
  $already || UNIQUE_PROFILES+=("$profile")
done

if [[ ${#UNIQUE_PROFILES[@]} -eq 1 ]]; then
  SELECTED_PROFILE="${UNIQUE_PROFILES[0]}"
  echo "✅ Using profile: $SELECTED_PROFILE"
else
  echo ""
  echo "❯ Select AWS profile:"
  for i in "${!UNIQUE_PROFILES[@]}"; do
    echo "  $((i+1))) ${UNIQUE_PROFILES[$i]}"
  done
  while true; do
    read -rp "Profile [1-${#UNIQUE_PROFILES[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#UNIQUE_PROFILES[@]} )); then
      SELECTED_PROFILE="${UNIQUE_PROFILES[$((choice-1))]}"
      break
    fi
    echo "  Invalid choice, try again."
  done
fi

# ---------------------------------------------------------------------------
# Filter hosts for selected profile, then select host
# ---------------------------------------------------------------------------
declare -a FILTERED_HOSTS=()
declare -a FILTERED_HOSTNAMES=()
declare -a FILTERED_USERS=()

for i in "${!ALL_HOSTS[@]}"; do
  if [[ "${ALL_PROFILES[$i]}" == "$SELECTED_PROFILE" ]]; then
    FILTERED_HOSTS+=("${ALL_HOSTS[$i]}")
    FILTERED_HOSTNAMES+=("${ALL_HOSTNAMES[$i]}")
    FILTERED_USERS+=("${ALL_USERS[$i]}")
  fi
done

if [[ ${#FILTERED_HOSTS[@]} -eq 0 ]]; then
  echo "❌ No hosts found for profile '$SELECTED_PROFILE'."
  exit 1
elif [[ ${#FILTERED_HOSTS[@]} -eq 1 ]]; then
  SELECTED_HOST="${FILTERED_HOSTS[0]}"
  SELECTED_HOSTNAME="${FILTERED_HOSTNAMES[0]}"
  SELECTED_USER="${FILTERED_USERS[0]}"
  echo "✅ Using host: $SELECTED_HOST"
else
  echo ""
  echo "❯ Select host:"
  for i in "${!FILTERED_HOSTS[@]}"; do
    label="${FILTERED_HOSTS[$i]}"
    if [[ "${FILTERED_HOSTNAMES[$i]}" != "${FILTERED_HOSTS[$i]}" ]]; then
      label+=" (${FILTERED_HOSTNAMES[$i]})"
    fi
    echo "  $((i+1))) $label"
  done
  while true; do
    read -rp "Host [1-${#FILTERED_HOSTS[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#FILTERED_HOSTS[@]} )); then
      SELECTED_HOST="${FILTERED_HOSTS[$((choice-1))]}"
      SELECTED_HOSTNAME="${FILTERED_HOSTNAMES[$((choice-1))]}"
      SELECTED_USER="${FILTERED_USERS[$((choice-1))]}"
      break
    fi
    echo "⚠️ Invalid choice, try again."
  done
fi

# Resolve instance ID: prefer Hostname if it looks like an instance ID, else use Host
if [[ "$SELECTED_HOSTNAME" =~ ^i-[a-z0-9]+$ ]]; then
  INSTANCE_REF="$SELECTED_HOSTNAME"
else
  INSTANCE_REF="$SELECTED_HOST"
fi

# ---------------------------------------------------------------------------
# AWS setup (reused from teamspace_tunnel.sh)
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-}"
AWS_PROFILE_NAME="$SELECTED_PROFILE"
[[ -z "$AWS_PROFILE_NAME" ]] && AWS_PROFILE_NAME="default"

AWS_CMD=(aws --profile "$AWS_PROFILE_NAME")

ensure_sso_session() {
  set +e
  STS_OUTPUT="$(${AWS_CMD[@]} sts get-caller-identity --output json 2>&1)"
  STS_EXIT=$?
  set -e

  if [[ $STS_EXIT -eq 0 ]]; then
    return 0
  fi

  SSO_START_URL="$(${AWS_CMD[@]} configure get sso_start_url 2>/dev/null || true)"
  SSO_SESSION_NAME="$(${AWS_CMD[@]} configure get sso_session 2>/dev/null || true)"

  if [[ -n "$SSO_START_URL" || -n "$SSO_SESSION_NAME" ]]; then
    echo "🔐 No active AWS SSO session for profile '$AWS_PROFILE_NAME'."
    echo "➡ Running: aws sso login --profile $AWS_PROFILE_NAME"
    aws sso login --profile "$AWS_PROFILE_NAME"

    set +e
    STS_OUTPUT="$(${AWS_CMD[@]} sts get-caller-identity --output json 2>&1)"
    STS_EXIT=$?
    set -e

    if [[ $STS_EXIT -ne 0 ]]; then
      echo "$STS_OUTPUT"
      echo "❌ AWS SSO login did not produce a usable session for profile '$AWS_PROFILE_NAME'."
      exit $STS_EXIT
    fi
  fi
}

ensure_sso_session

if [[ -z "$AWS_REGION" ]]; then
  AWS_REGION="$(${AWS_CMD[@]} configure get region)"
fi

if [[ -z "$AWS_REGION" ]]; then
  echo "❌ No AWS region configured for profile '$AWS_PROFILE_NAME'."
  echo "   Configure one with: aws configure set region <region> --profile $AWS_PROFILE_NAME"
  exit 1
fi

echo "🔍 Resolving instance: $INSTANCE_REF (region: $AWS_REGION)"

if [[ "$INSTANCE_REF" =~ ^i-[a-z0-9]+$ ]]; then
  DESCRIBE_ARGS=(--instance-ids "$INSTANCE_REF")
else
  DESCRIBE_ARGS=(--filters "Name=tag:Name,Values=$INSTANCE_REF" "Name=instance-state-name,Values=pending,running,stopping,stopped")
fi

set +e
DESCRIBE_OUTPUT=$(${AWS_CMD[@]} ec2 describe-instances \
  --region "$AWS_REGION" \
  "${DESCRIBE_ARGS[@]}" \
  --query "Reservations[].Instances[] | [0].[InstanceId,State.Name]" \
  --output text 2>&1)
DESCRIBE_EXIT=$?
set -e

if [[ $DESCRIBE_EXIT -ne 0 ]]; then
  echo "$DESCRIBE_OUTPUT"
  if [[ "$DESCRIBE_OUTPUT" == *"NoCredentials"* || "$DESCRIBE_OUTPUT" == *"Unable to locate credentials"* || "$DESCRIBE_OUTPUT" == *"ExpiredToken"* ]]; then
    echo "❌ AWS credentials are missing/expired for profile '$AWS_PROFILE_NAME'."
    echo "   Run: aws sso login --profile $AWS_PROFILE_NAME"
  fi
  exit $DESCRIBE_EXIT
fi

read -r INSTANCE_ID INSTANCE_STATE <<<"$DESCRIBE_OUTPUT"

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "❌ No EC2 instance found for '$INSTANCE_REF' in pending/running/stopping/stopped state."
  exit 1
fi

echo "✅ Found instance ID: $INSTANCE_ID (state: $INSTANCE_STATE)"

if [[ "$INSTANCE_STATE" == "stopped" ]]; then
  echo "⏳ Instance is stopped. Starting instance: $INSTANCE_ID"
  ${AWS_CMD[@]} ec2 start-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  echo "⏳ Waiting for instance to become running..."
  ${AWS_CMD[@]} ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
elif [[ "$INSTANCE_STATE" == "stopping" ]]; then
  echo "⏳ Instance is stopping. Waiting for it to stop first..."
  ${AWS_CMD[@]} ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
  echo "⏳ Starting instance: $INSTANCE_ID"
  ${AWS_CMD[@]} ec2 start-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  echo "⏳ Waiting for instance to become running..."
  ${AWS_CMD[@]} ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
elif [[ "$INSTANCE_STATE" == "pending" ]]; then
  echo "⏳ Instance is pending. Waiting for it to become running..."
  ${AWS_CMD[@]} ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
fi

# ---------------------------------------------------------------------------
# Connect via SSH
# ---------------------------------------------------------------------------
echo ""
echo "🔗 Connecting: ssh $SELECTED_HOST"
echo ""

exec ssh "$SELECTED_HOST"
